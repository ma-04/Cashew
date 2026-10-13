// The pull of the Firefly client. Firefly is the source of truth: a pulled
// record overwrites the local row and its snapshot. A local row that has a
// queued change is not touched; the push merges that change with the server
// record when it sends it (fireflyPush.dart).

import 'package:budget/database/tables.dart';
import 'package:budget/pages/addWalletPage.dart'
    show initializeBalanceCorrectionCategory;
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/firefly/client/fireflyProjection.dart';
import 'package:budget/struct/firefly/client/fireflyReport.dart';
import 'package:budget/struct/firefly/client/fireflyStore.dart';
import 'package:budget/struct/firefly/fireflyApiClient.dart';
import 'package:budget/struct/firefly/fireflyMapper.dart'
    show kBalanceCorrectionCategoryPk, kFireflyUncategorizedCategoryPk;
import 'package:drift/drift.dart';

const FireflySyncEntityType _wallet = FireflySyncEntityType.wallet;
const FireflySyncEntityType _category = FireflySyncEntityType.category;
const FireflySyncEntityType _transaction = FireflySyncEntityType.transaction;

// Keys of a transaction snapshot. The split is the record as the server sent
// it; the other keys come from its group.
const String kSnapGroupId = "group_id";
const String kSnapGroupTitle = "group_title";
const String kSnapUpdatedAt = "updated_at";
const String kSnapSplitCount = "split_count";
const String kSnapSplit = "split";
// "source" or "destination" for the two local rows of a transfer.
const String kSnapLeg = "leg";

class FireflyPullContext {
  final FireflyApiClient client;
  final FireflySyncReport report;
  // Rebuild: the local database takes the full server state, also over local
  // rows that have a queued change. The queue is empty at that time.
  final bool rebuild;
  // Write each record, also one whose snapshot is current. The push uses it
  // to put a local row back to the server state.
  final bool force;
  final Set<String> openOps;
  final Map<int, String> walletPkByAccount = {};
  final Map<String, int> accountByWalletPk = {};
  final Map<int, String> categoryPkById = {};
  final Map<int, Map<String, dynamic>> assetAccounts = {};

  FireflyPullContext({
    required this.client,
    required this.report,
    required this.openOps,
    this.rebuild = false,
    this.force = false,
  });

  bool hasOpenOp(FireflySyncEntityType type, String localPk) =>
      !rebuild && openOps.contains(fireflyOpKey(type, localPk));

  Future<void> loadLinks() async {
    walletPkByAccount.clear();
    accountByWalletPk.clear();
    categoryPkById.clear();
    for (FireflySyncMapEntry map in await fireflyMapsOfType(_wallet)) {
      walletPkByAccount[map.fireflyId] = map.localPk;
      accountByWalletPk[map.localPk] = map.fireflyId;
    }
    for (FireflySyncMapEntry map in await fireflyMapsOfType(_category)) {
      categoryPkById[map.fireflyId] = map.localPk;
    }
  }
}

Map<String, dynamic> _attributes(Map<String, dynamic> record) =>
    Map<String, dynamic>.from(record["attributes"] ?? {});

int? _id(Map<String, dynamic> record) => fireflyParseInt(record["id"]);

String _sameName(String name) => name.trim().toLowerCase();

DateTime? _updatedAt(Map<String, dynamic> record) =>
    fireflyParseDate(_attributes(record)["updated_at"]);

bool _snapshotIsCurrent(
    FireflySyncMapEntry? map, Map<String, dynamic> remoteRecord) {
  Map<String, dynamic>? snapshot = fireflySnapshotOf(map);
  if (snapshot == null) return false;
  return _attributes(snapshot)["updated_at"] ==
      _attributes(remoteRecord)["updated_at"];
}

// --- Categories -------------------------------------------------------------

// The two local categories that the client needs: the balance-correction
// category of the app, and the category of a Firefly record with no category.
Future<void> fireflyEnsureSystemCategories(String uncategorizedName) async {
  await initializeBalanceCorrectionCategory();
  if (await database
          .getCategoryInstanceOrNull(kFireflyUncategorizedCategoryPk) !=
      null) {
    return;
  }
  int count = (await database.getTotalCountOfCategories())[0] ?? 0;
  await database.createOrUpdateCategory(
    insert: false,
    updateSharedEntry: false,
    TransactionCategory(
      categoryPk: kFireflyUncategorizedCategoryPk,
      name: uncategorizedName,
      colour: null,
      iconName: "price-tag.png",
      dateCreated: DateTime.now(),
      dateTimeModified: null,
      order: count,
      income: false,
      methodAdded: MethodAdded.firefly,
    ),
  );
}

Future<void> fireflyPullCategories(FireflyPullContext ctx) async {
  List<Map<String, dynamic>> remote = await ctx.client.getAllRaw("/categories");
  List<TransactionCategory> locals = await database.getAllCategories();
  int nextOrder = locals.isEmpty
      ? 0
      : locals.map((c) => c.order).reduce((a, b) => a > b ? a : b) + 1;
  Set<int> remoteIds = {};

  for (Map<String, dynamic> record in remote) {
    int? id = _id(record);
    if (id == null) continue;
    remoteIds.add(id);
    String name = (_attributes(record)["name"] ?? "").toString();
    List<FireflySyncMapEntry> maps = await fireflyMapsOfRemote(_category, id);
    FireflySyncMapEntry? map = maps.isEmpty ? null : maps.first;
    TransactionCategory? local = map == null
        ? null
        : await database.getCategoryInstanceOrNull(map.localPk);

    if (map == null) {
      // A category is a name only. A local main category of the same name
      // that has no link is the same category: a link does not change a
      // field on either side, and a second category of that name would get
      // a 422 on its create.
      for (TransactionCategory candidate in locals) {
        if (candidate.mainCategoryPk != null) continue;
        if (_sameName(candidate.name) != _sameName(name)) continue;
        if (await fireflyMapOf(_category, candidate.categoryPk) != null) {
          continue;
        }
        local = candidate;
        break;
      }
    } else if (local != null && ctx.hasOpenOp(_category, local.categoryPk)) {
      continue;
    } else if (local != null && _snapshotIsCurrent(map, record)) {
      continue;
    }

    await fireflyApplyCategoryRecord(ctx, record,
        onto: local, localPk: map?.localPk, order: nextOrder++);
  }

  // A category that the server no longer has. Firefly removes a deleted
  // category from each of its transactions, thus the local rows become
  // uncategorized and keep everything else.
  for (FireflySyncMapEntry map in await fireflyMapsOfType(_category)) {
    if (remoteIds.contains(map.fireflyId)) continue;
    if (!await _remoteIsGone(ctx.client, "/categories/${map.fireflyId}")) {
      continue;
    }
    await fireflyRemoveLocalCategory(map.localPk);
    ctx.categoryPkById.remove(map.fireflyId);
  }
}

// Writes a category record of the server onto the local category `onto`, or
// onto a new local category.
Future<void> fireflyApplyCategoryRecord(
  FireflyPullContext ctx,
  Map<String, dynamic> record, {
  TransactionCategory? onto,
  String? localPk,
  int order = 0,
}) async {
  int id = _id(record)!;
  String name = (_attributes(record)["name"] ?? "").toString();
  DateTime stamp = fireflyEngineStamp(_updatedAt(record));
  TransactionCategory row = onto != null
      ? onto.copyWith(name: name, dateTimeModified: Value(stamp))
      : TransactionCategory(
          categoryPk: localPk ?? uuid.v4(),
          name: name,
          dateCreated: DateTime.now(),
          dateTimeModified: stamp,
          order: order,
          income: false,
          methodAdded: MethodAdded.firefly,
        );
  await database.createOrUpdateCategory(row,
      insert: false, updateSharedEntry: false, customDateTimeModified: stamp);
  await fireflyWriteMap(
    type: _category,
    localPk: row.categoryPk,
    fireflyId: id,
    snapshot: record,
    localModified: stamp,
    remoteUpdatedAt: _updatedAt(record),
  );
  ctx.categoryPkById[id] = row.categoryPk;
  ctx.report.pulledCategories++;
}

// Removes a local category that the server deleted, or that the user deleted
// and the server confirmed. Its rows go to the uncategorized category, and
// their snapshots too: the server did the same to its records, thus the next
// push sees no change.
Future<void> fireflyRemoveLocalCategory(String categoryPk) async {
  TransactionCategory? category =
      await database.getCategoryInstanceOrNull(categoryPk);
  await fireflyDeleteMap(_category, categoryPk);
  List<Transaction> rows = await (database.select(database.transactions)
        ..where((t) =>
            t.categoryFk.equals(categoryPk) |
            t.subCategoryFk.equals(categoryPk)))
      .get();
  for (Transaction row in rows) {
    bool main = row.categoryFk == categoryPk;
    Transaction moved = row.copyWith(
      categoryFk: main ? kFireflyUncategorizedCategoryPk : row.categoryFk,
      subCategoryFk: Value(null),
    );
    await _writeRow(moved);
    FireflySyncMapEntry? map = await fireflyMapOf(_transaction, row.transactionPk);
    Map<String, dynamic>? snapshot = fireflySnapshotOf(map);
    if (map != null && snapshot != null && main) {
      Map<String, dynamic> split = Map<String, dynamic>.from(snapshot[kSnapSplit]);
      split["category_id"] = null;
      split["category_name"] = null;
      snapshot[kSnapSplit] = split;
      await fireflyWriteMap(
        type: _transaction,
        localPk: map.localPk,
        fireflyId: map.fireflyId,
        journalId: map.fireflyJournalId,
        snapshot: snapshot,
        localModified: map.lastSyncedLocalModified ?? row.dateTimeModified!,
        remoteUpdatedAt: map.fireflyUpdatedAt,
      );
    }
  }
  if (category != null) {
    // Its rows have moved, thus this deletes the category and the links of
    // the budgets to it, and no transaction.
    await database.deleteCategory(categoryPk, category.order);
  }
}

// --- Accounts ---------------------------------------------------------------

Future<void> fireflyPullAccounts(FireflyPullContext ctx) async {
  List<Map<String, dynamic>> remote =
      await ctx.client.getAllRaw("/accounts", {"type": "asset"});
  List<TransactionWallet> locals = await database.getAllWallets();
  int nextOrder = locals.isEmpty
      ? 0
      : locals.map((w) => w.order).reduce((a, b) => a > b ? a : b) + 1;
  Set<int> remoteIds = {};
  ctx.assetAccounts.clear();

  for (Map<String, dynamic> record in remote) {
    int? id = _id(record);
    if (id == null) continue;
    remoteIds.add(id);
    ctx.assetAccounts[id] = record;
    Map<String, dynamic> attributes = _attributes(record);
    String name = (attributes["name"] ?? "").toString();
    List<FireflySyncMapEntry> maps = await fireflyMapsOfRemote(_wallet, id);
    FireflySyncMapEntry? map = maps.isEmpty ? null : maps.first;
    TransactionWallet? local =
        map == null ? null : await database.getWalletInstanceOrNull(map.localPk);

    if (map == null) {
      local = await _unlinkedWalletFor(name, locals, ctx);
    } else if (local != null && ctx.hasOpenOp(_wallet, local.walletPk)) {
      continue;
    } else if (local != null && _snapshotIsCurrent(map, record)) {
      continue;
    }

    await fireflyApplyAccountRecord(ctx, record,
        onto: local, localPk: map?.localPk, order: nextOrder++);
  }

  // An account that the server no longer has. Firefly deleted its
  // transactions with it, and the pull of the transactions removes the local
  // rows. A wallet that still holds a row stays, with no link.
  for (FireflySyncMapEntry map in await fireflyMapsOfType(_wallet)) {
    if (remoteIds.contains(map.fireflyId)) continue;
    if (!await _remoteIsGone(ctx.client, "/accounts/${map.fireflyId}")) {
      continue;
    }
    await fireflyDeleteMap(_wallet, map.localPk);
    ctx.walletPkByAccount.remove(map.fireflyId);
    ctx.accountByWalletPk.remove(map.localPk);
    ctx.report.warn("The Firefly account of a wallet was deleted. The wallet "
        "is no longer linked.");
  }
}

// Writes an asset account record of the server onto the local wallet `onto`,
// or onto a new wallet. The colour, the icon, the order, the currency format
// and the home screen settings stay: Firefly does not have them.
Future<void> fireflyApplyAccountRecord(
  FireflyPullContext ctx,
  Map<String, dynamic> record, {
  TransactionWallet? onto,
  String? localPk,
  int order = 0,
}) async {
  int id = _id(record)!;
  Map<String, dynamic> attributes = _attributes(record);
  String name = (attributes["name"] ?? "").toString();
  DateTime stamp = fireflyEngineStamp(_updatedAt(record));
  String? currency = attributes["currency_code"]?.toString().toLowerCase();
  int decimals = fireflyParseInt(attributes["currency_decimal_places"]) ?? 2;
  TransactionWallet row = onto != null
      ? onto.copyWith(
          name: name,
          currency: Value(currency),
          decimals: decimals,
          dateTimeModified: Value(stamp),
        )
      : TransactionWallet(
          walletPk: localPk ?? uuid.v4(),
          name: name,
          dateCreated: DateTime.now(),
          dateTimeModified: stamp,
          order: order,
          currency: currency,
          decimals: decimals,
        );
  await database.createOrUpdateWallet(row, customDateTimeModified: stamp);
  await fireflyWriteMap(
    type: _wallet,
    localPk: row.walletPk,
    fireflyId: id,
    snapshot: record,
    localModified: stamp,
    remoteUpdatedAt: _updatedAt(record),
  );
  ctx.walletPkByAccount[id] = row.walletPk;
  ctx.accountByWalletPk[row.walletPk] = id;
  ctx.assetAccounts[id] = record;
  ctx.report.pulledWallets++;
}

// The local wallet that a remote account with no link goes onto, or null for
// a new wallet. In a rebuild, a wallet with no link and the same name is that
// account: the rebuild then replaces its rows with the server rows. The
// primary wallet "0" of the app cannot be deleted; if it has no link and no
// row, it takes the first account that has no wallet. In a routine pull, only
// a wallet whose create is queued: the answer to that create was lost.
Future<TransactionWallet?> _unlinkedWalletFor(String name,
    List<TransactionWallet> locals, FireflyPullContext ctx) async {
  for (TransactionWallet candidate in locals) {
    if (_sameName(candidate.name) != _sameName(name)) continue;
    if (await fireflyMapOf(_wallet, candidate.walletPk) != null) continue;
    if (ctx.rebuild || ctx.openOps.contains(fireflyOpKey(_wallet, candidate.walletPk))) {
      return candidate;
    }
  }
  if (!ctx.rebuild) return null;
  TransactionWallet? primary = await database.getWalletInstanceOrNull("0");
  if (primary == null || await fireflyMapOf(_wallet, "0") != null) return null;
  int rows = (await (database.select(database.transactions)
            ..where((t) => t.walletFk.equals("0")))
          .get())
      .length;
  return rows == 0 ? primary : null;
}

// --- Transactions -----------------------------------------------------------

Future<void> _writeRow(Transaction row) {
  return database
      .into(database.transactions)
      .insert(row.toCompanion(true), mode: InsertMode.insertOrReplace);
}

Future<void> _deleteRow(String transactionPk) {
  return (database.delete(database.transactions)
        ..where((t) => t.transactionPk.equals(transactionPk)))
      .go();
}

// Removes a local row that the server no longer has, with its map row and
// any queued change. The server wins: a change of a record that is gone
// cannot go anywhere.
Future<void> fireflyRemoveLocalTransaction(
    String transactionPk, FireflySyncReport report) async {
  Transaction? row = await (database.select(database.transactions)
        ..where((t) => t.transactionPk.equals(transactionPk)))
      .getSingleOrNull();
  for (String pk in {transactionPk, if (row?.pairedTransactionFk != null) row!.pairedTransactionFk!}) {
    await _deleteRow(pk);
    await fireflyDeleteMap(_transaction, pk);
    await fireflyFinishOp(_transaction, pk);
  }
  report.removedTransactions++;
}

Map<String, dynamic> _transactionSnapshot(
    Map<String, dynamic> group, Map<String, dynamic> split,
    {String? leg}) {
  Map<String, dynamic> attributes = _attributes(group);
  return {
    kSnapGroupId: _id(group),
    kSnapGroupTitle: attributes["group_title"],
    kSnapUpdatedAt: attributes["updated_at"],
    kSnapSplitCount: List.from(attributes["transactions"] ?? []).length,
    kSnapSplit: split,
    if (leg != null) kSnapLeg: leg,
  };
}

// Applies each group and gives the ids of the groups that it read.
Future<Set<int>> fireflyApplyGroups(
    FireflyPullContext ctx, List<Map<String, dynamic>> groups) async {
  Set<int> seen = {};
  for (Map<String, dynamic> group in groups) {
    int? id = _id(group);
    if (id == null) {
      ctx.report.warn("Firefly sent a transaction with no id. It was skipped.");
      continue;
    }
    seen.add(id);
    try {
      await fireflyApplyGroup(ctx, group);
    } on FormatException catch (e) {
      ctx.report.warn("Firefly transaction $id could not be read: $e");
    }
  }
  return seen;
}

Future<void> fireflyApplyGroup(
    FireflyPullContext ctx, Map<String, dynamic> group) async {
  int groupId = _id(group)!;
  List<Map<String, dynamic>> splits =
      List.from(_attributes(group)["transactions"] ?? [])
          .map((s) => Map<String, dynamic>.from(s))
          .toList();
  List<FireflySyncMapEntry> maps =
      await fireflyMapsOfRemote(_transaction, groupId);
  Set<int> journalIds = {};
  for (Map<String, dynamic> split in splits) {
    int? journalId = fireflyParseInt(split["transaction_journal_id"]);
    if (journalId == null) {
      ctx.report.warn(
          "Firefly transaction $groupId has a split with no journal id. It "
          "was skipped.");
      continue;
    }
    journalIds.add(journalId);
    await _applySplit(ctx, group, split, journalId,
        maps.where((m) => m.fireflyJournalId == journalId).toList());
  }
  // A split that the group no longer holds, or a row of a build before the
  // journal id (it cannot be matched, and the rebuild replaces it).
  for (FireflySyncMapEntry map in maps) {
    if (map.fireflyJournalId != null &&
        journalIds.contains(map.fireflyJournalId)) continue;
    await fireflyRemoveLocalTransaction(map.localPk, ctx.report);
  }
}

Future<void> _applySplit(
  FireflyPullContext ctx,
  Map<String, dynamic> group,
  Map<String, dynamic> split,
  int journalId,
  List<FireflySyncMapEntry> maps,
) async {
  String type = fireflySplitType(split);
  String? sourceWallet =
      ctx.walletPkByAccount[fireflyParseInt(split["source_id"])];
  String? destinationWallet =
      ctx.walletPkByAccount[fireflyParseInt(split["destination_id"])];

  if (type == "transfer" && sourceWallet != null && destinationWallet != null) {
    await _applyTransfer(ctx, group, split, journalId, maps, sourceWallet,
        destinationWallet);
    return;
  }

  // One local row. A withdrawal leaves the source, a deposit arrives at the
  // destination. Each other type (opening balance, reconciliation, liability
  // credit, a transfer with one asset side) goes on the side that is a
  // wallet; such a row is read-only (see fireflySplitIsEditable).
  String? walletPk;
  bool income;
  if (type == "withdrawal") {
    walletPk = sourceWallet;
    income = false;
  } else if (type == "deposit") {
    walletPk = destinationWallet;
    income = true;
  } else if (sourceWallet != null) {
    walletPk = sourceWallet;
    income = false;
  } else {
    walletPk = destinationWallet;
    income = true;
  }
  if (walletPk == null) {
    // Not a record of a mirrored account.
    for (FireflySyncMapEntry map in maps) {
      await fireflyRemoveLocalTransaction(map.localPk, ctx.report);
    }
    return;
  }

  FireflySyncMapEntry? map = maps.isEmpty ? null : maps.first;
  for (FireflySyncMapEntry extra in maps.skip(1)) {
    // A transfer that became a single row: its second row goes.
    await _deleteRow(extra.localPk);
    await fireflyDeleteMap(_transaction, extra.localPk);
  }
  Transaction? local = map == null ? null : await _rowOrNull(map.localPk);
  if (map == null) local = await _lostCreate(split);
  if (local != null && ctx.hasOpenOp(_transaction, local.transactionPk)) {
    return;
  }
  if (!ctx.force &&
      local != null &&
      map != null &&
      maps.length == 1 &&
      fireflySnapshotOf(map)?[kSnapUpdatedAt] ==
          _attributes(group)["updated_at"]) {
    return;
  }

  double? amount = fireflyParseAmount(split["amount"]);
  DateTime? date = fireflyParseDate(split["date"]);
  if (amount == null || date == null) {
    ctx.report.warn("Firefly transaction ${_id(group)} has a split with no "
        "readable amount or date. It was skipped.");
    return;
  }
  String categoryPk = (type == "withdrawal" || type == "deposit")
      ? (ctx.categoryPkById[fireflyParseInt(split["category_id"])] ??
          kFireflyUncategorizedCategoryPk)
      : kBalanceCorrectionCategoryPk;
  DateTime stamp = fireflyEngineStamp(_updatedAt(group));
  String pk = map?.localPk ?? local?.transactionPk ?? uuid.v4();

  Transaction row = _applyFields(
    local ?? _newRow(pk),
    name: (split["description"] ?? "").toString(),
    amount: income ? amount : -amount,
    note: (split["notes"] ?? "").toString(),
    categoryPk: categoryPk,
    walletPk: walletPk,
    date: date,
    income: income,
    stamp: stamp,
    pairedPk: null,
  );
  if (local?.pairedTransactionFk != null) {
    await _deleteRow(local!.pairedTransactionFk!);
    await fireflyDeleteMap(_transaction, local.pairedTransactionFk!);
  }
  await _writeRow(row);
  await fireflyWriteMap(
    type: _transaction,
    localPk: pk,
    fireflyId: _id(group)!,
    journalId: journalId,
    snapshot: _transactionSnapshot(group, split),
    localModified: stamp,
    remoteUpdatedAt: _updatedAt(group),
  );
  ctx.report.pulledTransactions++;
}

Future<void> _applyTransfer(
  FireflyPullContext ctx,
  Map<String, dynamic> group,
  Map<String, dynamic> split,
  int journalId,
  List<FireflySyncMapEntry> maps,
  String sourceWallet,
  String destinationWallet,
) async {
  FireflySyncMapEntry? sourceMap;
  FireflySyncMapEntry? destinationMap;
  for (FireflySyncMapEntry map in maps) {
    String? leg = fireflySnapshotOf(map)?[kSnapLeg]?.toString();
    Transaction? row = await _rowOrNull(map.localPk);
    bool isSource = leg != null ? leg == "source" : (row?.amount ?? 0) < 0;
    if (isSource) {
      sourceMap ??= map;
    } else {
      destinationMap ??= map;
    }
  }
  Transaction? source =
      sourceMap == null ? null : await _rowOrNull(sourceMap.localPk);
  Transaction? destination =
      destinationMap == null ? null : await _rowOrNull(destinationMap.localPk);
  if (source == null && sourceMap == null) {
    source = await _lostCreate(split);
    if (source?.pairedTransactionFk != null) {
      destination = await _rowOrNull(source!.pairedTransactionFk!);
    }
  }
  for (Transaction? row in [source, destination]) {
    if (row != null && ctx.hasOpenOp(_transaction, row.transactionPk)) return;
  }
  if (!ctx.force &&
      source != null &&
      destination != null &&
      fireflySnapshotOf(sourceMap)?[kSnapUpdatedAt] ==
          _attributes(group)["updated_at"]) {
    return;
  }

  double? amount = fireflyParseAmount(split["amount"]);
  DateTime? date = fireflyParseDate(split["date"]);
  if (amount == null || date == null) {
    ctx.report.warn("Firefly transfer ${_id(group)} has no readable amount "
        "or date. It was skipped.");
    return;
  }
  // Firefly counts `amount` in the currency of the source account and
  // `foreign_amount` in the currency of the destination account, and gives a
  // foreign amount only when the two currencies differ.
  double? foreign = fireflyParseAmount(split["foreign_amount"]);
  double destinationAmount =
      (foreign != null && foreign != 0) ? foreign : amount;

  String sourcePk = sourceMap?.localPk ?? source?.transactionPk ?? uuid.v4();
  String destinationPk =
      destinationMap?.localPk ?? destination?.transactionPk ?? uuid.v4();
  DateTime stamp = fireflyEngineStamp(_updatedAt(group));
  String name = (split["description"] ?? "").toString();
  String note = (split["notes"] ?? "").toString();

  Transaction sourceRow = _applyFields(
    source ?? _newRow(sourcePk),
    name: name,
    amount: -amount,
    note: note,
    categoryPk: kBalanceCorrectionCategoryPk,
    walletPk: sourceWallet,
    date: date,
    income: false,
    stamp: stamp,
    pairedPk: destinationPk,
  );
  Transaction destinationRow = _applyFields(
    destination ?? _newRow(destinationPk),
    name: name,
    amount: destinationAmount,
    note: note,
    categoryPk: kBalanceCorrectionCategoryPk,
    walletPk: destinationWallet,
    date: date,
    income: true,
    stamp: stamp,
    pairedPk: sourcePk,
  );
  await _writeRow(sourceRow);
  await _writeRow(destinationRow);
  for (String pk in [sourcePk, destinationPk]) {
    await fireflyWriteMap(
      type: _transaction,
      localPk: pk,
      fireflyId: _id(group)!,
      journalId: journalId,
      snapshot: _transactionSnapshot(group, split,
          leg: pk == sourcePk ? "source" : "destination"),
      localModified: stamp,
      remoteUpdatedAt: _updatedAt(group),
    );
  }
  ctx.report.pulledTransactions++;
}

Future<Transaction?> _rowOrNull(String transactionPk) {
  return (database.select(database.transactions)
        ..where((t) => t.transactionPk.equals(transactionPk)))
      .getSingleOrNull();
}

// A create whose answer did not arrive: the server has the record, with the
// key of the local row as its external id, and the local row has no link.
Future<Transaction?> _lostCreate(Map<String, dynamic> split) async {
  String? externalId = split["external_id"]?.toString();
  if (externalId == null || externalId.isEmpty) return null;
  Transaction? row = await _rowOrNull(externalId);
  if (row == null) return null;
  if (await fireflyMapOf(_transaction, row.transactionPk) != null) return null;
  return row;
}

Transaction _newRow(String transactionPk) {
  return Transaction(
    transactionPk: transactionPk,
    name: "",
    amount: 0,
    note: "",
    categoryFk: kFireflyUncategorizedCategoryPk,
    walletFk: "0",
    dateCreated: DateTime.now(),
    income: false,
    paid: true,
    skipPaid: true,
    methodAdded: MethodAdded.firefly,
  );
}

// Writes the fields that Firefly owns onto a local row and keeps the others:
// the subcategory (while the category stays), the objective, the budget
// exclusions and the other fields that only this app has.
Transaction _applyFields(
  Transaction row, {
  required String name,
  required double amount,
  required String note,
  required String categoryPk,
  required String walletPk,
  required DateTime date,
  required bool income,
  required DateTime stamp,
  required String? pairedPk,
}) {
  return row.copyWith(
    name: name,
    amount: amount,
    note: note,
    categoryFk: categoryPk,
    subCategoryFk:
        row.categoryFk == categoryPk ? Value(row.subCategoryFk) : Value(null),
    walletFk: walletPk,
    dateCreated: date.toLocal(),
    income: income,
    paid: true,
    dateTimeModified: Value(stamp),
    pairedTransactionFk: Value(pairedPk),
  );
}

// True if the server has no such record. Any other failure counts as "the
// record may be there": a delete that rests on a failed read destroys data.
Future<bool> _remoteIsGone(FireflyApiClient client, String path) async {
  try {
    await client.getRaw(path);
    return false;
  } on FireflyNotFoundException {
    return true;
  }
}

// Removes each local row whose group the server no longer has. `seen` holds
// the groups that the pull read. `since` limits the test to the groups dated
// on or after that day, because the pull read only those; null tests all.
Future<void> fireflyRemoveMissingGroups(
  FireflyPullContext ctx,
  Set<int> seen, {
  DateTime? since,
}) async {
  Map<int, List<FireflySyncMapEntry>> byGroup = {};
  for (FireflySyncMapEntry map in await fireflyMapsOfType(_transaction)) {
    byGroup.putIfAbsent(map.fireflyId, () => []).add(map);
  }
  for (MapEntry<int, List<FireflySyncMapEntry>> entry in byGroup.entries) {
    if (seen.contains(entry.key)) continue;
    if (since != null) {
      DateTime? date = fireflyParseDate(
          fireflySnapshotOf(entry.value.first)?[kSnapSplit]?["date"]);
      if (date == null || date.isBefore(since)) continue;
    }
    try {
      Map<String, dynamic> group =
          await ctx.client.getRaw("/transactions/${entry.key}");
      // It is there: its date moved out of the range that the pull read.
      await fireflyApplyGroup(ctx, group);
    } on FireflyNotFoundException {
      for (FireflySyncMapEntry map in entry.value) {
        await fireflyRemoveLocalTransaction(map.localPk, ctx.report);
      }
    }
  }
}

// True if this app may change the record: a withdrawal, a deposit or a
// transfer between two mirrored accounts, not reconciled. An opening balance,
// a reconciliation or a reconciled journal is part of a balance that the user
// checked on Firefly.
bool fireflySplitIsEditable(Map<String, dynamic>? snapshot) {
  if (snapshot == null) return false;
  Map<String, dynamic> split = Map<String, dynamic>.from(snapshot[kSnapSplit]);
  if (split["reconciled"] == true) return false;
  String type = fireflySplitType(split);
  if (type == "transfer") return snapshot[kSnapLeg] != null;
  return type == "withdrawal" || type == "deposit";
}
