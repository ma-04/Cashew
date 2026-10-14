// The Firefly III client. Firefly is the source of truth; the local database
// is a copy of it that the app reads, and a queue of local changes that the
// server does not have yet. Firefly sync and Google Drive sync are mutually
// exclusive on one installation; the settings page keeps that rule.
//
// A cycle:
//  1. Queue each local record that changed since the last cycle
//     (FireflyOutbox). A record that the engine wrote is not a change: the
//     engine writes the server updated_at as its dateTimeModified and keeps
//     that value in the map row.
//  2. Pull. A pulled record overwrites the local row and its snapshot, but
//     not a row with a queued change (fireflyPull.dart).
//  3. Push the queue. An update sends only the fields that the user changed,
//     and a field that the server changed too keeps the server value
//     (fireflyPush.dart).
//
// The first cycle on a phone, and the first cycle after an upgrade from the
// two-way sync of earlier builds, is a rebuild: a backup of the local
// database, then the full server state over the local copy. Each local
// record that Firefly holds keeps the fields that only this app has.
//
// Design and decisions: FIREFLY_CLIENT_PLAN.md.

import 'dart:io' show Directory, File;

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/firefly/client/fireflyPlanning.dart';
import 'package:budget/struct/firefly/client/fireflyProjection.dart';
import 'package:budget/struct/firefly/client/fireflyPull.dart';
import 'package:budget/struct/firefly/client/fireflyPush.dart';
import 'package:budget/struct/firefly/client/fireflyReport.dart';
import 'package:budget/struct/firefly/client/fireflyStore.dart';
import 'package:budget/struct/firefly/fireflyApiClient.dart';
import 'package:budget/struct/firefly/fireflyMapper.dart'
    show
        isFireflyBalanceAnchorPk,
        kBalanceCorrectionCategoryPk,
        kFireflyBalanceAnchorPkPrefix,
        kFireflyUncategorizedCategoryPk;
import 'package:budget/struct/firefly/fireflyModels.dart';
import 'package:budget/struct/firefly/fireflySettings.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/util/debouncer.dart';
import 'package:drift/drift.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

export 'package:budget/struct/firefly/client/fireflyReport.dart';

enum FireflySyncStatus { neverSynced, idle, syncing, error }

final ValueNotifier<FireflySyncStatus> fireflySyncStatusNotifier =
    ValueNotifier(FireflySyncStatus.neverSynced);
final ValueNotifier<String?> fireflySyncErrorNotifier = ValueNotifier(null);
final ValueNotifier<FireflySyncReport?> fireflySyncReportNotifier =
    ValueNotifier(null);

// The client version that the local copy was built for. A database from the
// two-way sync of earlier builds has no snapshots, thus it needs a rebuild.
// Version 1 has snapshots but not the columns of schema 52: the next cycle
// fills them from the snapshots (see fireflyBackfillFromSnapshots) and reads
// the full history once. Version 2 has no Firefly budgets: the next cycle
// reads the full history once, and links each row to its budget.
const int kFireflyClientVersion = 3;

// How far back a routine pull looks for a deleted transaction. Firefly keeps
// no record of a delete, thus a delete shows only as a record that a list no
// longer holds. A delete of an older transaction is found by the full pull,
// which runs once a day and from "Sync all history".
const Duration kFireflyDeleteSweepRange = Duration(days: 62);
const Duration kFireflyFullPullInterval = Duration(days: 1);

// The transaction list of Firefly leaves out opening balances and the other
// special types unless it is asked for all of them. Without them the local
// sum of a wallet is not its balance.
const Map<String, dynamic> kFireflyAllTypes = {"type": "all"};

bool _cycleRunning = false;
bool _editDuringCycle = false;
bool get fireflySyncIsRunning => _cycleRunning;
final Debouncer fireflyPushDebouncer = Debouncer(milliseconds: 3000);

// A local write starts a push. The writes of a cycle come here too; they
// only set the flag, and the cycle that follows finds nothing to send.
void scheduleFireflyPush() {
  if (!fireflyEnabled) return;
  if (_cycleRunning) {
    _editDuringCycle = true;
    return;
  }
  fireflyPushDebouncer.run(() {
    fireflySyncNow(pushOnly: true);
  });
}

Future<FireflyAbout> testFireflyConnection(
    String hostUrl, String personalAccessToken) async {
  FireflyApiClient client = FireflyApiClient(
    baseUrl: hostUrl,
    personalAccessToken: personalAccessToken,
  );
  try {
    return await client.getAbout();
  } finally {
    client.close();
  }
}

// Makes a copy of the local database before a rebuild replaces its data. A
// test replaces it.
Future<String?> Function() fireflyBackupBeforeRebuild = _backupDatabaseFile;

Future<String?> _backupDatabaseFile() async {
  if (kIsWeb) return null;
  Directory folder = await getApplicationDocumentsDirectory();
  return fireflyBackupDatabaseTo(folder.path);
}

Future<String> fireflyBackupDatabaseTo(String folder) async {
  String stamp = DateTime.now()
      .toIso8601String()
      .replaceAll(":", "-")
      .replaceAll(".", "-");
  String path = p.join(folder, "firefly-rebuild-backup-$stamp.sqlite");
  if (await File(path).exists()) await File(path).delete();
  // VACUUM INTO writes a consistent copy of the open database.
  await database.customStatement("VACUUM INTO ?", [path]);
  return path;
}

Future<bool> fireflyNeedsRebuild() async {
  Object? version = appStateSettings["fireflyClientVersion"];
  return version != 1 && version != 2 && version != kFireflyClientVersion;
}

Future<FireflyApiClient> _clientOrThrow() async {
  String hostUrl = fireflyHostUrl;
  String? pat = await getFireflyPat();
  if (hostUrl.isEmpty || pat == null || pat.isEmpty) {
    // The enabled flag and the host are in the settings, which a backup
    // carries. The token is in the key store of the device, which it does
    // not. Switch the sync off and say what to do.
    await setFireflyEnabled(false);
    throw FireflyAuthException(hostUrl.isEmpty
        ? "Firefly host or access token not set"
        : "The Firefly access token is not on this device. A backup does "
            "not carry it. Firefly sync is off; enter the token again in "
            "the Firefly settings to switch it back on.");
  }
  return FireflyApiClient(baseUrl: hostUrl, personalAccessToken: pat);
}

// One cycle. `pushOnly` skips the pull; a local edit starts such a cycle.
// `fullResync` reads the full history of the server, also to find deletes of
// old transactions. Returns false if the cycle did not run or failed.
// `allowRebuild`: the user confirmed a rebuild. A cycle that needs one and
// has no confirm does not run: a rebuild replaces local data, and an automatic
// cycle (an app resume, an edit) must not do that unasked. This holds for a
// phone that comes from the two-way sync of an earlier build.
Future<bool> fireflySyncNow({
  bool fullResync = false,
  bool pushOnly = false,
  bool allowRebuild = false,
}) async {
  if (!fireflyEnabled) return false;
  if (_cycleRunning) {
    _editDuringCycle = true;
    return false;
  }
  _cycleRunning = true;
  fireflySyncStatusNotifier.value = FireflySyncStatus.syncing;
  fireflySyncErrorNotifier.value = null;
  FireflySyncReport report = FireflySyncReport();
  FireflyApiClient? client;
  try {
    client = await _clientOrThrow();
    await fireflyEnsureSystemCategories("firefly-uncategorized".tr());
    DateTime started = DateTime.now();

    if (await fireflyNeedsRebuild()) {
      if (!allowRebuild) {
        throw FireflyRebuildNeededException();
      }
      await _rebuild(client, report);
      await _checkBalances(client, report);
    } else {
      // An upgrade from client version 1. It runs before the push, thus no
      // push sees the empty columns.
      Object? version = appStateSettings["fireflyClientVersion"];
      bool upgrade = version != kFireflyClientVersion;
      if (version == 1) await fireflyBackfillFromSnapshots();
      if (upgrade) pushOnly = false;
      // An installation that was linked before the moment of the link was
      // kept: its local records from before the link go now, once.
      if (fireflyLinkedAt == null) {
        await _removeUnlinkedLeftovers(report, archiveWallets: true);
      }
      await _queueLocalChanges(_scanFrom());
      bool full = fullResync || upgrade || _fullPullIsDue(started);
      if (!pushOnly) {
        // The upgrade writes each record again: a split between an asset
        // account and a liability becomes two rows, and a liability a wallet.
        await _pull(client, report,
            full: full, started: started, force: upgrade);
      }
      // A row with a queued change was not written by the pull above. Its
      // budget link comes from its snapshot, before the push compares it.
      if (upgrade) await fireflyBackfillBudgetLinks();
      if (upgrade) {
        await updateSettings("fireflyClientVersion", kFireflyClientVersion,
            updateGlobalState: false);
      }
      await fireflyPushQueuedChanges(FireflyPushContext(
        client: client,
        report: report,
        counterpartyNaming: fireflyCounterpartyNaming,
      ));
      if (!pushOnly) await _checkBalances(client, report);
    }
    await _setScanFrom(started);
    await setFireflyLastSyncedAt(DateTime.now());
    for (String malformed in client.takeMalformedRecordWarnings()) {
      report.warn("A Firefly record was not read: $malformed");
    }
    fireflySyncReportNotifier.value = report;
    fireflySyncStatusNotifier.value = FireflySyncStatus.idle;
    return true;
  } catch (e) {
    print("Firefly sync error: " + e.toString());
    fireflySyncErrorNotifier.value = e.toString();
    fireflySyncReportNotifier.value = report;
    fireflySyncStatusNotifier.value = FireflySyncStatus.error;
    return false;
  } finally {
    client?.close();
    _cycleRunning = false;
    if (_editDuringCycle) {
      _editDuringCycle = false;
      fireflyPushDebouncer.run(() {
        fireflySyncNow(pushOnly: true);
      });
    }
  }
}

// --- Rebuild ----------------------------------------------------------------

Future<void> _rebuild(FireflyApiClient client, FireflySyncReport report) async {
  String? backup = await fireflyBackupBeforeRebuild();
  if (backup != null) {
    report.warn("The local data was copied to $backup before the rebuild "
        "from Firefly.");
  }
  await fireflyClearOutbox();
  await (database.delete(database.fireflySyncMap)
        ..where((m) => m.isTombstone.equals(true)))
      .go();
  // The balance anchors of the two-way sync. With the full history the
  // local sum of a wallet is its balance.
  await (database.delete(database.transactions)
        ..where((t) => t.transactionPk.like("$kFireflyBalanceAnchorPkPrefix%")))
      .go();

  FireflyPullContext ctx = FireflyPullContext(
    client: client,
    report: report,
    openOps: {},
    rebuild: true,
    force: true,
  );
  await ctx.loadLinks();
  await fireflyPullCategories(ctx);
  await fireflyPullAccounts(ctx);
  await fireflyPullBudgets(ctx, DateTime.now());
  DateTime pulled = DateTime.now();
  Set<int> seen =
      await fireflyApplyGroups(ctx, await client.getAllRaw("/transactions", kFireflyAllTypes));
  await fireflyRemoveMissingGroups(ctx, seen);
  await fireflyPullPiggyBanksAndBills(ctx, pulled);

  // A paid local row of a mirrored wallet that Firefly does not have. The
  // server is the truth, and the backup above holds the row. An unpaid row
  // is a local planning row and stays.
  Set<String> mirroredWallets = ctx.accountByWalletPk.keys.toSet();
  Set<String> linkedRows = (await fireflyMapsOfType(
          FireflySyncEntityType.transaction))
      .map((m) => m.localPk)
      .toSet();
  List<Transaction> rows = await (database.select(database.transactions)
        ..where((t) => t.walletFk.isIn(mirroredWallets))
        ..where((t) => t.paid.equals(true)))
      .get();
  int removed = 0;
  for (Transaction row in rows) {
    if (linkedRows.contains(row.transactionPk)) continue;
    await (database.delete(database.transactions)
          ..where((t) => t.transactionPk.equals(row.transactionPk)))
        .go();
    removed++;
  }
  if (removed > 0) {
    report.warn("$removed local transactions that Firefly does not have were "
        "removed. The backup holds them.");
  }

  await _removeUnlinkedLeftovers(report);
  await updateSettings("fireflyClientVersion", kFireflyClientVersion,
      updateGlobalState: false);
  await _setLastPull(pulled, full: true);
}

// --- Queue ------------------------------------------------------------------

DateTime _scanFrom() {
  String? iso = appStateSettings["fireflyScanFrom"]?.toString();
  DateTime? value = iso == null || iso.isEmpty ? null : DateTime.tryParse(iso);
  return value ?? DateTime(2000);
}

// A margin of a few seconds: the database keeps whole seconds, and an edit in
// the second that the scan started must be read again. A record that is
// read twice is queued once.
Future<void> _setScanFrom(DateTime started) {
  return updateSettings("fireflyScanFrom",
      started.subtract(const Duration(seconds: 5)).toIso8601String(),
      updateGlobalState: false);
}

// The local changes since `since`, as the push would send them. Each one is
// queued, or only counted with `dryRun`.
//
// A wallet or a category with no link that is older than the link to the
// server is a local record from before the sync (a default category of the
// app). A move in a list changes it, but it does not go to Firefly for that:
// it goes only when the user puts a transaction into it (see the push).
Future<FireflyLocalChanges> _queueLocalChanges(DateTime since,
    {bool dryRun = false}) async {
  FireflyLocalChanges changes = FireflyLocalChanges();
  DateTime? linkedAt = fireflyLinkedAt;
  bool preLink(DateTime created, FireflySyncMapEntry? map) =>
      map == null && linkedAt != null && created.isBefore(linkedAt);
  Future<void> queue(FireflySyncEntityType type, String pk) async {
    if (!dryRun) await fireflyQueue(type, pk);
  }

  for (TransactionWallet wallet in await database.getAllNewWallets(since)) {
    FireflySyncMapEntry? map =
        await fireflyMapOf(FireflySyncEntityType.wallet, wallet.walletPk);
    if (preLink(wallet.dateCreated, map)) continue;
    if (fireflyLocalRowIsDirty(wallet.dateTimeModified, map)) {
      changes.wallets++;
      await queue(FireflySyncEntityType.wallet, wallet.walletPk);
    }
  }
  for (TransactionCategory category
      in await database.getAllNewCategories(since)) {
    if (category.mainCategoryPk != null) continue;
    FireflySyncMapEntry? map = await fireflyMapOf(
        FireflySyncEntityType.category, category.categoryPk);
    if (preLink(category.dateCreated, map)) continue;
    if (fireflyLocalRowIsDirty(category.dateTimeModified, map)) {
      changes.categories++;
      await queue(FireflySyncEntityType.category, category.categoryPk);
    }
  }
  for (Transaction row in await database.getAllNewTransactions(since)) {
    if (isFireflyBalanceAnchorPk(row.transactionPk)) continue;
    FireflySyncMapEntry? map = await fireflyMapOf(
        FireflySyncEntityType.transaction, row.transactionPk);
    if (fireflyLocalRowIsDirty(row.dateTimeModified, map)) {
      if (map == null) {
        if (row.paid) changes.transactionsAdded++;
      } else {
        changes.transactionsChanged++;
      }
      await queue(FireflySyncEntityType.transaction, row.transactionPk);
    }
  }
  for (DeleteLog log in await database.getAllNewDeleteLogs(since)) {
    FireflySyncEntityType? type = switch (log.type) {
      DeleteLogType.Transaction => FireflySyncEntityType.transaction,
      _ => null,
    };
    if (type == null) continue;
    if (await fireflyMapOf(type, log.entryPk) == null) continue;
    changes.transactionsDeleted++;
    await queue(type, log.entryPk);
  }
  return changes;
}

class FireflyLocalChanges {
  int transactionsAdded = 0;
  int transactionsChanged = 0;
  int transactionsDeleted = 0;
  int wallets = 0;
  int categories = 0;
  int queued = 0;

  bool get isEmpty =>
      transactionsAdded +
          transactionsChanged +
          transactionsDeleted +
          wallets +
          categories +
          queued ==
      0;
}

// The changes that the next cycle would send: the changes made here since
// the last cycle, also while the sync was off, and the queued ones. The
// settings page shows them before the sync goes on again, because a delete
// made while the sync was off did not use the Firefly rules (a wallet delete
// there deletes its transactions).
Future<FireflyLocalChanges> fireflyLocalChangesToSend() async {
  FireflyLocalChanges changes =
      await _queueLocalChanges(_scanFrom(), dryRun: true);
  changes.queued =
      (await fireflyOutboxEntries(state: FireflyOutboxState.pending)).length;
  return changes;
}

// Removes the wallets and the main categories that have no link and no
// transaction: the defaults of the app and the records from before the
// sync. The local data then holds the records of Firefly only. The primary
// wallet "0" and the two categories of this app stay. Then sets the moment
// of the link. With `archiveWallets`, such a wallet becomes inactive and is
// not deleted: an installation that was linked before this step did not
// confirm a replace of its data now, and a budget or a home screen widget
// can still name the wallet.
Future<void> _removeUnlinkedLeftovers(FireflySyncReport report,
    {bool archiveWallets = false}) async {
  Set<String> usedCategories = {};
  Set<String> usedWallets = {};
  for (Transaction row in await database.select(database.transactions).get()) {
    usedCategories.add(row.categoryFk);
    if (row.subCategoryFk != null) usedCategories.add(row.subCategoryFk!);
    usedWallets.add(row.walletFk);
  }
  int removed = 0;
  for (TransactionCategory category in await database.getAllCategories()) {
    if (category.mainCategoryPk != null) continue;
    if (category.categoryPk == kBalanceCorrectionCategoryPk ||
        category.categoryPk == kFireflyUncategorizedCategoryPk) {
      continue;
    }
    if (await fireflyMapOf(
            FireflySyncEntityType.category, category.categoryPk) !=
        null) {
      continue;
    }
    if (usedCategories.contains(category.categoryPk)) continue;
    List<TransactionCategory> subs = await (database
            .select(database.categories)
          ..where((c) => c.mainCategoryPk.equals(category.categoryPk)))
        .get();
    if (subs.any((sub) => usedCategories.contains(sub.categoryPk))) continue;
    TransactionCategory? current =
        await database.getCategoryInstanceOrNull(category.categoryPk);
    if (current == null) continue;
    await database.deleteCategory(current.categoryPk, current.order);
    removed++;
  }
  for (TransactionWallet wallet in await database.getAllWallets()) {
    if (wallet.walletPk == "0") continue;
    if (await fireflyMapOf(FireflySyncEntityType.wallet, wallet.walletPk) !=
        null) {
      continue;
    }
    if (usedWallets.contains(wallet.walletPk)) continue;
    TransactionWallet? current =
        await database.getWalletInstanceOrNull(wallet.walletPk);
    if (current == null) continue;
    if (archiveWallets) {
      if (current.archived == true) continue;
      await (database.update(database.wallets)
            ..where((w) => w.walletPk.equals(current.walletPk)))
          .write(const WalletsCompanion(archived: Value(true)));
    } else {
      await database.deleteWallet(current.walletPk, current.order);
    }
    removed++;
  }
  if (removed > 0) {
    report.warn("$removed local categories and wallets that Firefly does not "
        "have and that hold no transaction were removed"
        "${archiveWallets ? " (the wallets were made inactive)" : ""}.");
  }
  await setFireflyLinkedAt(DateTime.now());
}

// --- Pull -------------------------------------------------------------------

bool _fullPullIsDue(DateTime now) {
  String? iso = appStateSettings["fireflyLastFullPullAt"]?.toString();
  DateTime? last = iso == null || iso.isEmpty ? null : DateTime.tryParse(iso);
  return last == null || now.difference(last) > kFireflyFullPullInterval;
}

DateTime? get _lastPull {
  String? iso = appStateSettings["fireflyLastPulledAt"]?.toString();
  return iso == null || iso.isEmpty ? null : DateTime.tryParse(iso);
}

Future<void> _setLastPull(DateTime started, {required bool full}) async {
  await updateSettings("fireflyLastPulledAt", started.toIso8601String(),
      updateGlobalState: false);
  if (full) {
    await updateSettings("fireflyLastFullPullAt", started.toIso8601String(),
        updateGlobalState: false);
  }
}

Future<void> _pull(FireflyApiClient client, FireflySyncReport report,
    {required bool full, required DateTime started, bool force = false}) async {
  FireflyPullContext ctx = FireflyPullContext(
    client: client,
    report: report,
    openOps: await fireflyOpenOpKeys(),
    force: force,
  );
  await ctx.loadLinks();
  await fireflyPullCategories(ctx);
  await fireflyPullAccounts(ctx);
  await fireflyPullBudgets(ctx, started);

  if (full || _lastPull == null) {
    Set<int> seen =
        await fireflyApplyGroups(ctx, await client.getAllRaw("/transactions", kFireflyAllTypes));
    await fireflyRemoveMissingGroups(ctx, seen);
  } else {
    // Changes since the last pull, with one day of margin: the search keyword
    // takes a date only.
    DateTime since = _lastPull!.subtract(const Duration(days: 1));
    await fireflyApplyGroups(
        ctx,
        await client.getAllRaw("/search/transactions",
            {"query": "updated_at_after:${client.formatQueryDate(since)}"}));
    // Deletes leave no record to search for. The groups of a recent range
    // show which ones are gone; each one is read once more before the local
    // row goes.
    DateTime start = started.subtract(kFireflyDeleteSweepRange);
    start = DateTime(start.year, start.month, start.day);
    Set<int> seen = await fireflyApplyGroups(
        ctx,
        await client.getAllRaw(
            "/transactions",
            {...kFireflyAllTypes, "start": client.formatQueryDate(start)}));
    await fireflyRemoveMissingGroups(ctx, seen, since: start);
  }
  await fireflyPullPiggyBanksAndBills(ctx, started);
  await _setLastPull(started, full: full || _lastPull == null);
}

// Firefly gives the balance of each account. The local sum of a mirrored
// wallet must agree with it; a difference means that a local row is not on
// the server, or the reverse, and the report names the wallet.
//
// Two details of current_balance, read on Firefly 6.7.9: it is rounded to the
// decimals of the currency, and it holds the virtual balance only after
// Firefly computed the balance again (an account with no transaction yet
// gives 0 with a virtual balance of 100). Both forms are accepted.
Future<void> _checkBalances(
    FireflyApiClient client, FireflySyncReport report) async {
  if ((await fireflyOutboxEntries(state: FireflyOutboxState.pending))
      .isNotEmpty) {
    return;
  }
  for (Map<String, dynamic> account
      in await fireflyGetWalletAccounts(client)) {
    int? id = fireflyParseInt(account["id"]);
    if (id == null) continue;
    List<FireflySyncMapEntry> maps =
        await fireflyMapsOfRemote(FireflySyncEntityType.wallet, id);
    if (maps.isEmpty) continue;
    Map<String, dynamic> attributes =
        Map<String, dynamic>.from(account["attributes"] ?? {});
    double current = double.tryParse("${attributes["current_balance"]}") ?? 0;
    double virtual =
        double.tryParse("${attributes["virtual_balance"] ?? 0}") ?? 0;
    int decimals = fireflyParseInt(attributes["currency_decimal_places"]) ?? 2;
    double unit = 1 / _pow10(decimals);
    double local = await _walletSum(maps.first.localPk);
    bool agrees(double server) => (server - local).abs() <= unit / 2 + 1e-9;
    if (!agrees(current) && !agrees(current - virtual)) {
      report.warn("The balance of \"${attributes["name"]}\" is "
          "${(current - virtual).toStringAsFixed(decimals)} on Firefly and "
          "${local.toStringAsFixed(decimals)} here.");
    }
  }
}

double _pow10(int n) {
  double value = 1;
  for (int i = 0; i < n; i++) {
    value *= 10;
  }
  return value;
}

Future<double> _walletSum(String walletPk) async {
  Expression<double> total = database.transactions.amount.sum();
  TypedResult result = await (database.selectOnly(database.transactions)
        ..addColumns([total])
        ..where(database.transactions.walletFk.equals(walletPk) &
            database.transactions.paid.equals(true)))
      .getSingle();
  return result.read(total) ?? 0;
}

// --- Actions of the settings page -------------------------------------------

Future<bool> fireflySyncAllHistory() => fireflySyncNow(fullResync: true);

// Rebuilds the local copy from the server, after a backup. The settings page
// offers it as "Reset Firefly links".
Future<bool> fireflyRebuildFromFirefly() async {
  await updateSettings("fireflyClientVersion", 0, updateGlobalState: false);
  return fireflySyncNow(allowRebuild: true);
}

class FireflyRebuildNeededException implements Exception {
  @override
  String toString() => "Firefly sync waits for a rebuild of the local data "
      "from Firefly. Open the Firefly settings and tap Sync now to confirm it.";
}

// Forgets the links of this server. The next cycle is a rebuild.
Future<void> fireflyForgetSyncState() async {
  await fireflyClearClientState();
  await clearFireflyLastSyncedAt();
  await clearFireflyLinkedAt();
  await updateSettings("fireflyClientVersion", 0, updateGlobalState: false);
  await updateSettings("fireflyScanFrom", "", updateGlobalState: false);
  await updateSettings("fireflyLastPulledAt", "", updateGlobalState: false);
  await updateSettings("fireflyLastFullPullAt", "", updateGlobalState: false);
}

class FireflyQueuedChanges {
  final int pending;
  final List<FireflyOutboxEntry> failed;
  FireflyQueuedChanges(this.pending, this.failed);
}

Future<FireflyQueuedChanges> fireflyQueuedChanges() async {
  return FireflyQueuedChanges(
    (await fireflyOutboxEntries(state: FireflyOutboxState.pending)).length,
    await fireflyOutboxEntries(state: FireflyOutboxState.failed),
  );
}

// Sends the refused changes again, after the user fixed the cause on the
// server.
Future<bool> fireflyRetryFailedChanges() async {
  await fireflyRetryFailedOps();
  return fireflySyncNow(pushOnly: true);
}

// Drops the refused changes. The local rows already hold the server state.
Future<void> fireflyDismissFailedChanges() async {
  await (database.delete(database.fireflyOutbox)
        ..where((o) => o.state.equals(FireflyOutboxState.failed.index)))
      .go();
}

// --- On-demand reads of the two-way sync ------------------------------------
//
// The local copy holds the full history now, thus these do nothing. They stay
// for the pages that call them.

Future<void> fireflyEnsureRangeCached(DateTime? start, DateTime? end) async {}
Future<void> fireflyEnsureSearchCached(String? query) async {}
Future<void> fireflyEnsureWalletHistoryCached(String walletPk) async {}
void fireflyClearOnDemandCacheMemory() {}
Future<bool> fireflyRefreshBalances() async => true;

// A local wallet and the Firefly account that it mirrors, for the settings
// page. The link comes from the server; the user does not choose it.
class FireflyLinkedWallet {
  final String walletPk;
  final String walletName;
  final String accountName;
  final bool active;
  final String? currencyCode;
  FireflyLinkedWallet({
    required this.walletPk,
    required this.walletName,
    required this.accountName,
    required this.active,
    required this.currencyCode,
  });
}

Future<List<FireflyLinkedWallet>> fireflyLinkedWallets() async {
  List<FireflyLinkedWallet> result = [];
  for (FireflySyncMapEntry map
      in await fireflyMapsOfType(FireflySyncEntityType.wallet)) {
    TransactionWallet? wallet =
        await database.getWalletInstanceOrNull(map.localPk);
    if (wallet == null) continue;
    Map<String, dynamic> attributes = Map<String, dynamic>.from(
        fireflySnapshotOf(map)?["attributes"] ?? {});
    result.add(FireflyLinkedWallet(
      walletPk: wallet.walletPk,
      walletName: wallet.name,
      accountName: (attributes["name"] ?? wallet.name).toString(),
      active: attributes["active"] != false,
      currencyCode: attributes["currency_code"]?.toString(),
    ));
  }
  return result;
}
