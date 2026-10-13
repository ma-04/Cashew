// The push of the Firefly client: it sends the queued local changes.
//
// The rules that keep the server data correct:
// - An update sends only the fields that the user changed (fireflyMerge). A
//   field that the server changed since this app last read it keeps the
//   server value.
// - After each write the answer of the server overwrites the local row and
//   its snapshot.
// - A change that the server refuses is not sent again with a guess. The
//   local row goes back to the server state and the change stays in the list
//   of failed changes.
// - A change of a record that this app must not change (a reconciled
//   journal, an opening balance) is undone locally and is not sent.

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/firefly/client/fireflyProjection.dart';
import 'package:budget/struct/firefly/client/fireflyPull.dart';
import 'package:budget/struct/firefly/client/fireflyReport.dart';
import 'package:budget/struct/firefly/client/fireflyStore.dart';
import 'package:budget/struct/firefly/fireflyApiClient.dart';
import 'package:budget/struct/firefly/fireflyMapper.dart'
    show
        kBalanceCorrectionCategoryPk,
        kFireflyUncategorizedCategoryPk,
        isFireflyBalanceAnchorPk;

const FireflySyncEntityType _wallet = FireflySyncEntityType.wallet;
const FireflySyncEntityType _category = FireflySyncEntityType.category;
const FireflySyncEntityType _transaction = FireflySyncEntityType.transaction;

// A change that cannot go yet. The operation stays pending.
class _Held implements Exception {
  final String reason;
  _Held(this.reason);
}

class FireflyPushContext {
  final FireflyApiClient client;
  final FireflySyncReport report;
  // How a new withdrawal or deposit names its other account: "generic" (the
  // cash account of the server) or "category" (an account named after the
  // category). See fireflyCounterpartyNaming in fireflySettings.dart.
  final String counterpartyNaming;
  late final FireflyPullContext apply;
  final Set<String> _handled = {};

  FireflyPushContext({
    required this.client,
    required this.report,
    required this.counterpartyNaming,
  }) {
    apply = FireflyPullContext(
      client: client,
      report: FireflySyncReport(),
      openOps: {},
      force: true,
    );
  }
}

Future<void> fireflyPushQueuedChanges(FireflyPushContext ctx) async {
  List<FireflyOutboxEntry> ops =
      await fireflyOutboxEntries(state: FireflyOutboxState.pending);
  if (ops.isEmpty) return;
  await ctx.apply.loadLinks();

  bool isIntent(FireflyOutboxEntry o) => o.intent != null;
  // Categories and accounts first: a new transaction needs their ids.
  for (FireflyOutboxEntry op in ops
      .where((o) => o.entityType == _category && !isIntent(o))) {
    await _run(ctx, op, () => _pushCategory(ctx, op));
  }
  for (FireflyOutboxEntry op
      in ops.where((o) => o.entityType == _wallet && !isIntent(o))) {
    await _run(ctx, op, () => _pushWallet(ctx, op));
  }
  await ctx.apply.loadLinks();
  for (FireflyOutboxEntry op
      in ops.where((o) => o.entityType == _transaction)) {
    await _run(ctx, op, () => _pushTransaction(ctx, op));
  }
  // A category delete and a wallet deactivation last. A merge of two
  // categories moves the rows to the other category and then deletes the
  // first one: if the delete went first, Firefly would remove the category
  // from those rows, and the moves would then meet a server change and lose.
  for (FireflyOutboxEntry op in ops.where(isIntent)) {
    await _run(
        ctx,
        op,
        () => op.entityType == _wallet
            ? _pushWallet(ctx, op)
            : _pushCategory(ctx, op));
  }
}

// Runs one operation. A refused change fails that operation only. A failure
// of the connection or of the token ends the push: the next changes would
// fail the same way, and the operations stay pending.
Future<void> _run(FireflyPushContext ctx, FireflyOutboxEntry op,
    Future<void> Function() body) async {
  try {
    await body();
  } on _Held catch (e) {
    ctx.report.held++;
    ctx.report.warn(e.reason);
  } on FireflyValidationException catch (e) {
    ctx.report.failed++;
    await fireflyFailOp(op.entityType, op.localPk, e.message);
    ctx.report.warn("Firefly refused a change: ${_shortError(e.message)}");
    await _restoreServerState(ctx, op);
  } on FireflyNetworkException catch (e) {
    await fireflyCountAttempt(op.entityType, op.localPk, e.message);
    rethrow;
  } on FireflyRateLimitException catch (e) {
    await fireflyCountAttempt(op.entityType, op.localPk, e.message);
    rethrow;
  }
}

String _shortError(String message) {
  RegExpMatch? match = RegExp(r'"message"\s*:\s*"([^"]*)"').firstMatch(message);
  return match?.group(1) ?? message;
}

// Puts the local record back to the server state after a refused change.
Future<void> _restoreServerState(
    FireflyPushContext ctx, FireflyOutboxEntry op) async {
  FireflySyncMapEntry? map = await fireflyMapOf(op.entityType, op.localPk);
  if (map == null) return;
  try {
    switch (op.entityType) {
      case FireflySyncEntityType.wallet:
        await fireflyApplyAccountRecord(
            ctx.apply, await ctx.client.getRaw("/accounts/${map.fireflyId}"),
            onto: await database.getWalletInstanceOrNull(map.localPk),
            localPk: map.localPk);
        break;
      case FireflySyncEntityType.category:
        await fireflyApplyCategoryRecord(ctx.apply,
            await ctx.client.getRaw("/categories/${map.fireflyId}"),
            onto: await database.getCategoryInstanceOrNull(map.localPk),
            localPk: map.localPk);
        break;
      case FireflySyncEntityType.transaction:
        await fireflyApplyGroup(ctx.apply,
            await ctx.client.getRaw("/transactions/${map.fireflyId}"));
        break;
    }
    ctx.report.reverted++;
  } on FireflyNotFoundException {
    // The next pull removes it.
  }
}

bool _sameText(Object? a, Object? b) =>
    (a ?? "").toString() == (b ?? "").toString();

Map<String, dynamic> _attributes(Map<String, dynamic>? record) =>
    Map<String, dynamic>.from(record?["attributes"] ?? {});

// --- Categories -------------------------------------------------------------

Future<void> _pushCategory(
    FireflyPushContext ctx, FireflyOutboxEntry op) async {
  String pk = op.localPk;
  TransactionCategory? local = await database.getCategoryInstanceOrNull(pk);
  FireflySyncMapEntry? map = await fireflyMapOf(_category, pk);

  if (pk == kBalanceCorrectionCategoryPk ||
      pk == kFireflyUncategorizedCategoryPk ||
      local?.mainCategoryPk != null) {
    // Local categories. A subcategory goes to Firefly as a tag, in a later
    // phase.
    await fireflyFinishOp(_category, pk);
    return;
  }

  if (map == null) {
    if (local == null) {
      await fireflyFinishOp(_category, pk);
      return;
    }
    Map<String, dynamic> record;
    try {
      record = await ctx.client.postRaw("/categories", {
        "name": local.name,
        if (fireflyColourDigits(local.colour) != null)
          "notes": fireflyNotesWithColour(null, local.colour!),
      });
    } on FireflyValidationException catch (e) {
      // A category is a name only. The server has one of this name: it is
      // the same category.
      if (!e.isNameInUse) rethrow;
      Map<String, dynamic>? same = (await ctx.client.getAllRaw("/categories"))
          .where((c) =>
              _attributes(c)["name"].toString().trim().toLowerCase() ==
              local.name.trim().toLowerCase())
          .firstOrNull;
      if (same == null) rethrow;
      record = same;
    }
    await fireflyApplyCategoryRecord(ctx.apply, record, onto: local);
    await fireflyFinishOp(_category, pk);
    ctx.report.pushedCreates++;
    return;
  }

  if (op.intent == kFireflyIntentDelete) {
    try {
      await ctx.client.deleteRaw("/categories/${map.fireflyId}");
    } on FireflyNotFoundException {}
    await fireflyRemoveLocalCategory(pk);
    await fireflyFinishOp(_category, pk);
    ctx.report.pushedDeletes++;
    return;
  }

  if (local == null) {
    // The local category is gone with no delete request (a path that the
    // client does not know). The server keeps it; the next pull brings it
    // back.
    await fireflyFinishOp(_category, pk);
    return;
  }

  Map<String, dynamic>? base = fireflySnapshotOf(map);
  if (base == null) throw _Held("A category waits for its first pull.");
  String baseName = _attributes(base)["name"]?.toString() ?? "";
  bool nameChanged = local.name != baseName;
  // A colour change goes into the notes. A removed colour does not change the
  // notes: the text of the notes belongs to the user.
  bool colourChanged = fireflyColourDigits(local.colour) != null &&
      fireflyColourDigits(local.colour) !=
          fireflyColourDigits(base[kSnapshotLocalColour]?.toString());
  if (!nameChanged && !colourChanged) {
    await fireflyFinishOp(_category, pk);
    return;
  }
  Map<String, dynamic> live =
      await ctx.client.getRaw("/categories/${map.fireflyId}");
  Map<String, dynamic> body = {};
  if (nameChanged) {
    if (_sameText(_attributes(live)["name"], baseName)) {
      body["name"] = local.name;
    } else {
      ctx.report.conflicts++;
      ctx.report.warn("A category was renamed on Firefly and here. The name "
          "of Firefly stays.");
    }
  }
  if (colourChanged) {
    if (fireflyCategoryColour(live) == fireflyCategoryColour(base)) {
      body["notes"] =
          fireflyNotesWithColour(_attributes(live)["notes"], local.colour!);
    } else {
      ctx.report.conflicts++;
      ctx.report.warn("A category colour was changed on Firefly and here. "
          "The colour of Firefly stays.");
    }
  }
  if (body.isEmpty) {
    await fireflyApplyCategoryRecord(ctx.apply, live, onto: local);
  } else {
    Map<String, dynamic> record =
        await ctx.client.putRaw("/categories/${map.fireflyId}", body);
    await fireflyApplyCategoryRecord(ctx.apply, record, onto: local);
    ctx.report.pushedUpdates++;
  }
  await fireflyFinishOp(_category, pk);
}

// --- Accounts ---------------------------------------------------------------

Future<void> _pushWallet(FireflyPushContext ctx, FireflyOutboxEntry op) async {
  String pk = op.localPk;
  TransactionWallet? local = await database.getWalletInstanceOrNull(pk);
  FireflySyncMapEntry? map = await fireflyMapOf(_wallet, pk);

  if (map == null) {
    if (local == null) {
      await fireflyFinishOp(_wallet, pk);
      return;
    }
    String currency = (local.currency ?? "").trim().toUpperCase();
    Map<String, dynamic> record = await ctx.client.postRaw("/accounts", {
      "name": local.name,
      "type": "asset",
      "account_role": "defaultAsset",
      // A new account takes the currency of the wallet. An update never
      // sends it: Firefly would change the currency of the account and of
      // its future transactions.
      if (currency.isNotEmpty) "currency_code": currency,
    });
    await fireflyApplyAccountRecord(ctx.apply, record, onto: local);
    await fireflyFinishOp(_wallet, pk);
    ctx.report.pushedCreates++;
    return;
  }

  if (op.intent == kFireflyIntentDeactivate) {
    // A Firefly account delete destroys each of its transactions. The user
    // asked to delete the wallet; the account goes inactive and keeps its
    // history.
    Map<String, dynamic> record = await ctx.client
        .putRaw("/accounts/${map.fireflyId}", {"active": false});
    await fireflyApplyAccountRecord(ctx.apply, record,
        onto: local, localPk: pk);
    await fireflyFinishOp(_wallet, pk);
    ctx.report.pushedUpdates++;
    return;
  }

  if (local == null) {
    await fireflyFinishOp(_wallet, pk);
    return;
  }
  Map<String, dynamic>? base = fireflySnapshotOf(map);
  if (base == null) throw _Held("An account waits for its first pull.");
  String baseName = _attributes(base)["name"]?.toString() ?? "";
  Map<String, dynamic>? record;
  if (local.name != baseName) {
    Map<String, dynamic> live =
        await ctx.client.getRaw("/accounts/${map.fireflyId}");
    if (!_sameText(_attributes(live)["name"], baseName)) {
      ctx.report.conflicts++;
      ctx.report.warn("An account was renamed on Firefly and here. The name "
          "of Firefly stays.");
      record = live;
    } else {
      // The name only. The role stays as it is on the server: sent with
      // `ccAsset` it needs the card fields, and a wrong role changes the
      // account.
      record = await ctx.client
          .putRaw("/accounts/${map.fireflyId}", {"name": local.name});
      ctx.report.pushedUpdates++;
    }
  }
  if (record != null ||
      (local.currency ?? "") !=
          (_attributes(base)["currency_code"] ?? "").toString().toLowerCase()) {
    // A currency that the user changed here does not go to the server (see
    // the create above); the wallet takes the currency of the account again.
    await fireflyApplyAccountRecord(ctx.apply,
        record ?? await ctx.client.getRaw("/accounts/${map.fireflyId}"),
        onto: local);
  }
  await fireflyFinishOp(_wallet, pk);
}

// --- Transactions -----------------------------------------------------------

Future<Transaction?> _row(String pk) {
  return (database.select(database.transactions)
        ..where((t) => t.transactionPk.equals(pk)))
      .getSingleOrNull();
}

// The two rows of a transfer, source first, or null for a single row.
Future<(Transaction, Transaction)?> _transferPair(Transaction row) async {
  if (row.pairedTransactionFk == null) return null;
  Transaction? other = await _row(row.pairedTransactionFk!);
  if (other == null) return null;
  return row.amount < 0 ? (row, other) : (other, row);
}

Future<void> _finishTransaction(Iterable<String> pks) async {
  for (String pk in pks) {
    await fireflyFinishOp(_transaction, pk);
  }
}

Future<void> _pushTransaction(
    FireflyPushContext ctx, FireflyOutboxEntry op) async {
  String pk = op.localPk;
  if (ctx._handled.contains(pk)) {
    await fireflyFinishOp(_transaction, pk);
    return;
  }
  if (isFireflyBalanceAnchorPk(pk)) {
    await fireflyFinishOp(_transaction, pk);
    return;
  }
  Transaction? row = await _row(pk);
  FireflySyncMapEntry? map = await fireflyMapOf(_transaction, pk);
  // The rows of the operation, to finish together.
  Set<String> pks = {pk};
  if (row?.pairedTransactionFk != null) pks.add(row!.pairedTransactionFk!);
  ctx._handled.addAll(pks);
  ctx.apply.openOps.clear();

  if (row == null && map == null) {
    await _finishTransaction(pks);
  } else if (row == null) {
    await _pushTransactionDelete(ctx, map!);
    await _finishTransaction(pks);
  } else if (map == null) {
    await _pushTransactionCreate(ctx, op, row);
    await _finishTransaction(pks);
  } else {
    await _pushTransactionUpdate(ctx, row, map);
    await _finishTransaction(pks);
  }
}

// The Firefly id of the category of a local row: null for no category. A
// row in a category that is not on the server yet waits.
int? _categoryIdOf(FireflyPushContext ctx, Transaction row) {
  if (row.categoryFk == kFireflyUncategorizedCategoryPk) return null;
  for (MapEntry<int, String> entry in ctx.apply.categoryPkById.entries) {
    if (entry.value == row.categoryFk) return entry.key;
  }
  throw _Held("A transaction waits for its category to reach Firefly.");
}

// The tag of the subcategory of a row ("Parent/Child"), or null.
Future<String?> _subcategoryTagOf(Transaction row) async {
  if (row.subCategoryFk == null) return null;
  TransactionCategory? sub =
      await database.getCategoryInstanceOrNull(row.subCategoryFk!);
  TransactionCategory? main =
      await database.getCategoryInstanceOrNull(row.categoryFk);
  if (sub == null || main == null) return null;
  return fireflySubcategoryTag(main.name, sub.name);
}

int _accountOf(FireflyPushContext ctx, String walletPk) {
  int? id = ctx.apply.accountByWalletPk[walletPk];
  if (id == null) {
    throw _Held("A transaction waits for its wallet to reach Firefly.");
  }
  return id;
}

Future<void> _pushTransactionCreate(
    FireflyPushContext ctx, FireflyOutboxEntry op, Transaction row) async {
  if (!row.paid) {
    // Firefly has no state for a payment that is expected and not made. An
    // unpaid row is a local planning row.
    ctx.report.keptLocal++;
    return;
  }
  (Transaction, Transaction)? pair = await _transferPair(row);
  if (pair == null && row.categoryFk == kBalanceCorrectionCategoryPk) {
    // A balance correction of this app. On Firefly it would be spending or
    // income on the cash account, which is not true.
    ctx.report.keptLocal++;
    return;
  }
  if (pair != null && !(pair.$1.paid && pair.$2.paid)) {
    ctx.report.keptLocal++;
    return;
  }
  Transaction source = pair?.$1 ?? row;

  // A request that went out before may have reached the server with no
  // answer. Its record has the key of the row as the external id.
  if (op.attempts > 0) {
    List<Map<String, dynamic>> found = await ctx.client.getAllRaw(
        "/search/transactions",
        {"query": "external_id_is:${source.transactionPk}"});
    if (found.isNotEmpty) {
      await fireflyApplyGroup(ctx.apply, found.first);
      return;
    }
  }

  Map<String, dynamic> split;
  if (pair != null) {
    TransactionWallet? from = await database.getWalletInstanceOrNull(pair.$1.walletFk);
    TransactionWallet? to = await database.getWalletInstanceOrNull(pair.$2.walletFk);
    bool cross = (from?.currency ?? "").toLowerCase() !=
        (to?.currency ?? "").toLowerCase();
    split = fireflyCreateRequestFields(fireflyProjectLocalTransfer(
      source: pair.$1,
      destination: pair.$2,
      sourceAccountId: _accountOf(ctx, pair.$1.walletFk),
      destinationAccountId: _accountOf(ctx, pair.$2.walletFk),
      crossCurrency: cross,
      description: pair.$1.name,
      notes: pair.$1.note,
    ));
    split["type"] = fireflyPairType(from?.accountKind, to?.accountKind);
    if (cross && (to?.currency ?? "").isNotEmpty) {
      split["foreign_currency_code"] = to!.currency!.toUpperCase();
    }
  } else {
    split = fireflyCreateRequestFields(fireflyProjectLocalRow(
      row,
      assetAccountId: _accountOf(ctx, row.walletFk),
      categoryId: _categoryIdOf(ctx, row),
      subcategoryTag: await _subcategoryTagOf(row),
    ));
    String otherSide = row.amount > 0 ? "source" : "destination";
    if (fireflyLocalPayee(row) == null &&
        ctx.counterpartyNaming == "category" &&
        row.categoryFk != kFireflyUncategorizedCategoryPk) {
      TransactionCategory? category =
          await database.getCategoryInstanceOrNull(row.categoryFk);
      if (category != null) split["${otherSide}_name"] = category.name;
    }
    // A row with no payee names no other account: Firefly books the split
    // on its own cash account, and makes that account when the server has
    // none yet.
  }
  split["external_id"] = source.transactionPk;
  await fireflyCountAttempt(_transaction, op.localPk, "sent");
  Map<String, dynamic> group =
      await ctx.client.postRaw("/transactions", {"transactions": [split]});
  // The answer holds the external id, thus the pull links it to the row.
  await fireflyApplyGroup(ctx.apply, group);
  ctx.report.pushedCreates++;
}

Future<void> _pushTransactionUpdate(
    FireflyPushContext ctx, Transaction row, FireflySyncMapEntry map) async {
  Map<String, dynamic>? snapshot = fireflySnapshotOf(map);
  if (snapshot == null) throw _Held("A transaction waits for its first pull.");
  Map<String, dynamic> baseSplit =
      Map<String, dynamic>.from(snapshot[kSnapSplit]);
  int groupId = map.fireflyId;
  int? journalId = map.fireflyJournalId;

  Future<void> putBack(String warning) async {
    ctx.report.reverted++;
    ctx.report.warn(warning);
    try {
      await fireflyApplyGroup(
          ctx.apply, await ctx.client.getRaw("/transactions/$groupId"));
    } on FireflyNotFoundException {
      await fireflyRemoveLocalTransaction(row.transactionPk, ctx.report);
    }
  }

  if (!fireflySplitIsEditable(snapshot)) {
    return putBack("A reconciled transaction, an opening balance or a "
        "reconciliation was changed here. Change it on Firefly; the change "
        "here was undone.");
  }
  if (!row.paid) {
    return putBack("A transaction on Firefly cannot be marked as not paid. "
        "It stays paid.");
  }

  (Transaction, Transaction)? pair = await _transferPair(row);
  // Two local rows stand for a split between two wallets: a transfer, or a
  // withdrawal or deposit between an asset account and a liability.
  // The pull gives such a row a leg in its snapshot.
  bool isPair = snapshot[kSnapLeg] != null;
  if (isPair != (pair != null)) {
    return putBack("A transaction cannot change between a transfer and an "
        "expense or income here. Change it on Firefly.");
  }
  if (pair == null && row.categoryFk == kBalanceCorrectionCategoryPk) {
    return putBack("A Firefly transaction cannot go into the balance "
        "correction category.");
  }

  FireflyProjection base;
  FireflyProjection local;
  if (pair != null) {
    base = fireflyProjectRemoteTransfer(baseSplit);
    String remoteText = (baseSplit["description"] ?? "").toString();
    String remoteNotes = (baseSplit["notes"] ?? "").toString();
    local = fireflyProjectLocalTransfer(
      source: pair.$1,
      destination: pair.$2,
      sourceAccountId: _accountOf(ctx, pair.$1.walletFk),
      destinationAccountId: _accountOf(ctx, pair.$2.walletFk),
      crossCurrency: baseSplit["foreign_amount"] != null,
      description:
          fireflyTransferText(pair.$1.name, pair.$2.name, remoteText),
      notes: fireflyTransferText(pair.$1.note, pair.$2.note, remoteNotes),
    );
  } else {
    base = fireflyProjectRemoteSplit(baseSplit);
    local = fireflyProjectLocalRow(
      row,
      assetAccountId: _accountOf(ctx, row.walletFk),
      categoryId: _categoryIdOf(ctx, row),
      subcategoryTag: await _subcategoryTagOf(row),
    );
  }
  if (fireflyDiff(local, base).isEmpty) return;

  Map<String, dynamic> group;
  try {
    group = await ctx.client.getRaw("/transactions/$groupId");
  } on FireflyNotFoundException {
    ctx.report.warn("A transaction that was changed here was deleted on "
        "Firefly. It was removed here too.");
    await fireflyRemoveLocalTransaction(row.transactionPk, ctx.report);
    return;
  }
  List<Map<String, dynamic>> liveSplits =
      List.from(_attributes(group)["transactions"] ?? [])
          .map((s) => Map<String, dynamic>.from(s))
          .toList();
  Map<String, dynamic>? liveSplit = liveSplits
      .where((s) => fireflyParseInt(s["transaction_journal_id"]) == journalId)
      .firstOrNull;
  if (liveSplit == null) {
    ctx.report.warn("A transaction that was changed here was deleted on "
        "Firefly. It was removed here too.");
    await fireflyRemoveLocalTransaction(row.transactionPk, ctx.report);
    return;
  }
  if (liveSplit["reconciled"] == true) {
    return putBack("A transaction was reconciled on Firefly. The change "
        "here was undone.");
  }
  FireflyProjection live = pair != null
      ? fireflyProjectRemoteTransfer(liveSplit)
      : fireflyProjectRemoteSplit(liveSplit);
  FireflyMergeResult merge =
      fireflyMerge(base: base, local: local, live: live);
  if (merge.conflicts.isNotEmpty) {
    ctx.report.conflicts += merge.conflicts.length;
    ctx.report.warn("A transaction was changed on Firefly and here. For "
        "${merge.conflicts.join(", ")} the value of Firefly stays.");
  }
  if (merge.send.containsKey(kFieldPayee) &&
      !fireflyPayeeIsEditable(liveSplit)) {
    // A name always finds or makes an expense or a revenue account, thus a
    // payment to a loan would lose the loan.
    merge.send.remove(kFieldPayee);
    ctx.report.reverted++;
    ctx.report.warn("The other account of this transaction is a liability "
        "or an asset account. Change it on Firefly; the payee here was "
        "undone.");
  }
  if (merge.send.isEmpty) {
    await fireflyApplyGroup(ctx.apply, group);
    return;
  }

  Map<String, dynamic> fields =
      fireflySplitRequestFields(merge.send, live: liveSplit);
  Map<String, dynamic> body = {
    // Firefly deletes each split that a PUT does not name, thus each other
    // split goes with its id alone.
    "transactions": [
      for (Map<String, dynamic> split in liveSplits)
        fireflyParseInt(split["transaction_journal_id"]) == journalId
            ? {"transaction_journal_id": journalId, ...fields}
            : {"transaction_journal_id": split["transaction_journal_id"]},
    ],
  };
  if (liveSplits.length > 1) {
    // Firefly refuses a PUT of a group with more than one split and no
    // group title.
    body["group_title"] = _attributes(group)["group_title"] ??
        (liveSplits.first["description"] ?? kFireflyNoDescription);
  }
  Map<String, dynamic> saved =
      await ctx.client.putRaw("/transactions/$groupId", body);
  await fireflyApplyGroup(ctx.apply, saved);
  ctx.report.pushedUpdates++;
}

Future<void> _pushTransactionDelete(
    FireflyPushContext ctx, FireflySyncMapEntry map) async {
  Map<String, dynamic>? snapshot = fireflySnapshotOf(map);
  List<FireflySyncMapEntry> journalMaps =
      (await fireflyMapsOfRemote(_transaction, map.fireflyId))
          .where((m) => m.fireflyJournalId == map.fireflyJournalId)
          .toList();
  ctx._handled.addAll(journalMaps.map((m) => m.localPk));

  Map<String, dynamic> group;
  try {
    group = await ctx.client.getRaw("/transactions/${map.fireflyId}");
  } on FireflyNotFoundException {
    for (FireflySyncMapEntry m in journalMaps) {
      await fireflyDeleteMap(_transaction, m.localPk);
    }
    return;
  }
  if (snapshot != null && !fireflySplitIsEditable(snapshot)) {
    // The local row comes back.
    ctx.report.reverted++;
    ctx.report.warn("A reconciled transaction, an opening balance or a "
        "reconciliation cannot be deleted here. Delete it on Firefly.");
    for (FireflySyncMapEntry m in journalMaps) {
      await fireflyDeleteMap(_transaction, m.localPk);
    }
    await fireflyApplyGroup(ctx.apply, group);
    return;
  }
  List<dynamic> splits = List.from(_attributes(group)["transactions"] ?? []);
  bool holdsSplit = splits.any((s) =>
      fireflyParseInt(s["transaction_journal_id"]) == map.fireflyJournalId);
  if (holdsSplit) {
    if (splits.length == 1) {
      await ctx.client.deleteRaw("/transactions/${map.fireflyId}");
    } else {
      // One split of a group: the others stay. A journal delete of an id
      // that the group does not hold gives 401, thus the test above.
      await ctx.client
          .deleteRaw("/transaction-journals/${map.fireflyJournalId}");
    }
    ctx.report.pushedDeletes++;
  }
  for (FireflySyncMapEntry m in journalMaps) {
    await fireflyDeleteMap(_transaction, m.localPk);
  }
}
