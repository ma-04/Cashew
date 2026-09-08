// Orchestrates 2-way sync between the local database and a self-hosted
// Firefly III instance. Structurally mirrors lib/struct/syncClient.dart's
// syncData() (in-flight guard, debounce, loading indicators) but is a fully
// separate, self-contained module - Google Drive sync and Firefly sync are
// mutually exclusive per install (enforced in the settings UI).
//
// Sync order per cycle: pull (categories -> accounts -> counterparties ->
// transactions), apply remote deletes, refresh balance anchors, then push
// (categories -> accounts -> transactions -> local deletes). Pulling first
// means a remote-side conflict is visible before any local push could
// overwrite it.
//
// WINDOWING
//
// Firefly is the system of record and may hold years of history. A routine
// sync therefore only covers a recent booking-date window (see
// fireflySyncWindowDays, default 30 days). Older records are not held locally
// until something asks for them - searching, filtering, or opening an account
// calls into the on-demand section at the bottom of this file, which fetches
// the requested range and caches it, after which it behaves like any other
// local row.
//
// Two consequences the rest of this file has to respect:
//
//  1. The local database is deliberately an INCOMPLETE copy of the remote
//     one. Nothing may infer "absent locally" => "deleted remotely", or
//     "absent remotely" => "deleted locally", outside the window that was
//     actually fetched. See _applyRemoteDeletes.
//  2. Summing local rows for a wallet no longer yields its real balance. Each
//     synced wallet carries a balance anchor row (see fireflyMapper.dart)
//     holding everything that happened before the window, derived from
//     Firefly's authoritative current_balance, so wallet totals and net worth
//     stay correct. See _refreshBalanceAnchors.
//
// Firefly's start/end filters are booking date, not updated_at, so an edit
// made today to a transaction booked before the window will not be seen until
// that record is pulled on demand. That is the accepted cost of not holding
// the whole ledger; a "Sync all history" action widens the window instead.

import 'package:drift/drift.dart' show Value, InsertMode;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/pages/addWalletPage.dart'
    show initializeBalanceCorrectionCategory;
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/firefly/fireflyApiClient.dart';
import 'package:budget/struct/firefly/fireflyMapper.dart';
import 'package:budget/struct/firefly/fireflyModels.dart';
import 'package:budget/struct/firefly/fireflySettings.dart';
import 'package:budget/widgets/util/debouncer.dart';

enum FireflySyncStatus { neverSynced, idle, syncing, error }

class FireflySyncReport {
  int pulledCategories = 0;
  int pulledWallets = 0;
  int pulledTransactions = 0;
  int pushedCategories = 0;
  int pushedWallets = 0;
  int pushedTransactions = 0;
  int deletedLocal = 0;
  int deletedRemote = 0;
  int skippedUnsupported = 0;
  int skippedSubcategories = 0;
  int skippedUnmappedWallet = 0;
  final List<String> warnings = [];

  String summary() {
    List<String> parts = [];
    if (pulledTransactions > 0 || pulledWallets > 0 || pulledCategories > 0) {
      parts.add(
          "pulled $pulledWallets accounts, $pulledCategories categories, $pulledTransactions transactions");
    }
    if (pushedTransactions > 0 || pushedWallets > 0 || pushedCategories > 0) {
      parts.add(
          "pushed $pushedWallets accounts, $pushedCategories categories, $pushedTransactions transactions");
    }
    if (deletedLocal > 0 || deletedRemote > 0) {
      parts.add("deleted $deletedLocal local, $deletedRemote remote");
    }
    if (skippedUnsupported > 0) {
      parts.add("$skippedUnsupported unsupported transactions skipped");
    }
    if (skippedSubcategories > 0) {
      parts.add("$skippedSubcategories subcategories not synced");
    }
    if (skippedUnmappedWallet > 0) {
      parts.add("$skippedUnmappedWallet transactions skipped (wallet not linked)");
    }
    if (warnings.isNotEmpty) {
      parts.add("${warnings.length} warning(s)");
    }
    return parts.isEmpty ? "Nothing to sync" : parts.join(". ");
  }
}

final ValueNotifier<FireflySyncStatus> fireflySyncStatusNotifier =
    ValueNotifier(FireflySyncStatus.neverSynced);
final ValueNotifier<String?> fireflySyncErrorNotifier = ValueNotifier(null);
final ValueNotifier<FireflySyncReport?> fireflySyncReportNotifier =
    ValueNotifier(null);

bool _canSyncFirefly = true;
// A depth counter rather than a flag. An on-demand fetch can start and finish
// while a full sync is still running, and clearing a shared bool on its way out
// would make the rest of that sync's own writes look like user edits, waking
// the auto-sync watcher and scheduling a pointless push every cycle.
int _applyingFireflyWriteDepth = 0;
bool get _applyingFireflyWrites => _applyingFireflyWriteDepth > 0;
bool _userEditDuringSync = false;
final Debouncer fireflyPushDebouncer = Debouncer(milliseconds: 5000);

// Serializes every piece of engine work that talks to Firefly and writes to
// the local database: the routine sync and all of the on-demand fetches at the
// bottom of this file.
//
// _canSyncFirefly only stops a second *sync* from starting; it says nothing
// about the on-demand path. Without this queue an on-demand fetch and a sync
// can both be inside _pullTransactions for the same Firefly group at once,
// both look up the sync map before either has written one, and both insert
// their own local copy of the same remote transaction.
Future<void> _fireflyEngineQueue = Future<void>.value();

Future<T> _withFireflyEngineLock<T>(Future<T> Function() body) {
  Future<T> result = _fireflyEngineQueue.then((_) => body());
  // The queue must survive a failed piece of work, or one thrown exception
  // would block the engine for the rest of the app's life. The error is still
  // delivered to whoever awaits result.
  _fireflyEngineQueue = result.then<void>((_) {}, onError: (Object _) {});
  return result;
}

void scheduleFireflyPush() {
  if (!fireflyEnabled) return;
  if (_applyingFireflyWrites) {
    // This fires for the engine's own writes, but a genuine user edit landing
    // in the same window is indistinguishable from them here. Returning
    // without recording anything would drop that edit for good, since the
    // watermark advances regardless. Flag it so a reconciling cycle runs once
    // this one finishes; the cost of being wrong is one extra no-op sync.
    _userEditDuringSync = true;
    return;
  }
  if (!_canSyncFirefly) {
    _userEditDuringSync = true;
    return;
  }
  fireflyPushDebouncer.run(() {
    fireflySyncNow();
  });
}

Future<T> _withFireflyWrites<T>(Future<T> Function() action) async {
  _applyingFireflyWriteDepth++;
  try {
    return await action();
  } finally {
    _applyingFireflyWriteDepth--;
  }
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

Future<bool> fireflySyncNow({
  // Ignore the rolling window and pull the instance's entire history. The
  // escape hatch for "my older transactions are missing"; expensive on a
  // populated instance, so it is only ever user-initiated.
  bool fullResync = false,
  // Push local transactions that predate the link to Firefly.
  //
  // Off by default and deliberately so. On a first link both sides are
  // typically already populated, and transactions cannot be safely matched by
  // content, so blind-pushing local history would upload a duplicate of every
  // record the pull just brought down. Firefly is the system of record: local
  // history stays local unless the user explicitly asks to upload it.
  bool pushExistingLocalHistory = false,
}) async {
  if (!fireflyEnabled) return false;
  if (!_canSyncFirefly) return false;
  _canSyncFirefly = false;
  _userEditDuringSync = false;
  fireflySyncStatusNotifier.value = FireflySyncStatus.syncing;
  fireflySyncErrorNotifier.value = null;
  FireflySyncReport report = FireflySyncReport();

  FireflyApiClient? client;
  try {
    String hostUrl = fireflyHostUrl;
    String? pat = await getFireflyPat();
    if (hostUrl.isEmpty || pat == null || pat.isEmpty) {
      throw FireflyAuthException("Firefly host or access token not set");
    }
    client = FireflyApiClient(baseUrl: hostUrl, personalAccessToken: pat);

    DateTime syncStartedAt = DateTime.now();

    // The push watermark. On a first link this is the link moment rather than
    // the epoch, so pre-existing local rows are not treated as "changed since
    // last sync" and mass-uploaded - see pushExistingLocalHistory above.
    DateTime lastSynced = pushExistingLocalHistory
        ? DateTime(2000)
        : (fireflyLastSyncedAt ?? syncStartedAt);

    // Booking-date window for the pull. null means "no lower bound".
    DateTime? windowStart =
        fullResync ? null : fireflySyncWindowStart(now: syncStartedAt);

    // Pulled rows land in the reserved balance-correction category "0"
    // (uncategorized remote rows, both legs of a transfer, and the balance
    // anchors). Cashew only creates that category lazily, the first time the
    // user makes a balance correction, and createOrUpdateTransaction throws
    // "category-no-longer-exists" when it is missing - which on a fresh
    // install would abort the very first sync. Make sure it exists first.
    await _ensureFireflySystemCategories();

    await _withFireflyEngineLock(() => _withFireflyWrites(() async {
          Set<int> remoteCategoryIds = await _pullCategories(client!, report);
          Set<int> remoteWalletIds = await _pullAccounts(client, report);
          _FireflyCounterpartyIndex counterparties =
              await _loadCounterparties(client);
          Set<int> remoteTransactionIds = await _pullTransactions(
              client, report,
              windowStart: windowStart);
          await _applyRemoteDeletes(
            client: client,
            remoteCategoryIds: remoteCategoryIds,
            remoteWalletIds: remoteWalletIds,
            remoteTransactionIds: remoteTransactionIds,
            windowStart: windowStart,
            report: report,
          );
          await _pushCategories(client, lastSynced, report,
              includeUnmodifiedRows: pushExistingLocalHistory);
          await _pushAccounts(client, lastSynced, report,
              includeUnmodifiedRows: pushExistingLocalHistory);
          await _pushTransactions(client, lastSynced, counterparties, report,
              includeUnmodifiedRows: pushExistingLocalHistory);
          await _pushDeletes(client, lastSynced, counterparties, report);
          // Last, because the push we just did changes the remote balances
          // this reads. Anchoring on a pre-push balance would leave every
          // wallet we pushed to wrong by the amount pushed.
          await _refreshBalanceAnchors(client, report);
        }));

    await setFireflyLastSyncedAt(syncStartedAt);
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
    _canSyncFirefly = true;
    if (_userEditDuringSync) {
      _userEditDuringSync = false;
      scheduleFireflyPush();
    }
  }
}

class _FireflyCounterpartyIndex {
  final Map<int, FireflyAccount> byId;
  final Map<String, FireflyAccount> expenseByName;
  final Map<String, FireflyAccount> revenueByName;

  _FireflyCounterpartyIndex({
    required this.byId,
    required this.expenseByName,
    required this.revenueByName,
  });
}

Future<_FireflyCounterpartyIndex> _loadCounterparties(
    FireflyApiClient client) async {
  List<FireflyAccount> expense =
      await client.getAccounts(type: kFireflyExpenseAccountType);
  List<FireflyAccount> revenue =
      await client.getAccounts(type: kFireflyRevenueAccountType);
  List<FireflyAccount> cash =
      await client.getAccounts(type: kFireflyCashAccountType);
  Map<int, FireflyAccount> byId = {};
  Map<String, FireflyAccount> expenseByName = {};
  Map<String, FireflyAccount> revenueByName = {};
  for (FireflyAccount account in [...expense, ...cash]) {
    byId[account.id] = account;
    expenseByName[account.name.trim().toLowerCase()] = account;
  }
  for (FireflyAccount account in revenue) {
    byId[account.id] = account;
    revenueByName[account.name.trim().toLowerCase()] = account;
  }
  return _FireflyCounterpartyIndex(
    byId: byId,
    expenseByName: expenseByName,
    revenueByName: revenueByName,
  );
}

// ---------------------------------------------------------------------------
// FireflySyncMap helpers
// ---------------------------------------------------------------------------

Future<List<FireflySyncMapEntry>> _syncMapEntriesForType(
    FireflySyncEntityType type, {bool includeTombstones = false}) {
  return (database.select(database.fireflySyncMap)
        ..where((tbl) => includeTombstones
            ? tbl.entityType.equalsValue(type)
            : tbl.entityType.equalsValue(type) & tbl.isTombstone.equals(false)))
      .get();
}

Future<FireflySyncMapEntry?> _syncMapByLocalPk(
    FireflySyncEntityType type, String localPk,
    {bool includeTombstones = false}) {
  return (database.select(database.fireflySyncMap)
        ..where((tbl) => includeTombstones
            ? tbl.entityType.equalsValue(type) & tbl.localPk.equals(localPk)
            : tbl.entityType.equalsValue(type) &
                tbl.localPk.equals(localPk) &
                tbl.isTombstone.equals(false)))
      .getSingleOrNull();
}

Future<List<FireflySyncMapEntry>> _syncMapsByFireflyId(
    FireflySyncEntityType type, int fireflyId,
    {bool includeTombstones = false}) {
  return (database.select(database.fireflySyncMap)
        ..where((tbl) => includeTombstones
            ? tbl.entityType.equalsValue(type) & tbl.fireflyId.equals(fireflyId)
            : tbl.entityType.equalsValue(type) &
                tbl.fireflyId.equals(fireflyId) &
                tbl.isTombstone.equals(false)))
      .get();
}

Future<void> _upsertSyncMap({
  String? syncMapPk,
  required FireflySyncEntityType type,
  required String localPk,
  required int fireflyId,
  DateTime? fireflyUpdatedAt,
  DateTime? lastSyncedLocalModified,
  bool isTombstone = false,
  int? counterpartyFireflyId,
  int fireflySplitIndex = 0,
}) async {
  await database.into(database.fireflySyncMap).insert(
        FireflySyncMapCompanion(
          syncMapPk:
              syncMapPk == null ? const Value.absent() : Value(syncMapPk),
          entityType: Value(type),
          localPk: Value(localPk),
          fireflyId: Value(fireflyId),
          fireflyUpdatedAt: Value(fireflyUpdatedAt),
          lastSyncedLocalModified: Value(lastSyncedLocalModified),
          isTombstone: Value(isTombstone),
          counterpartyFireflyId: Value(counterpartyFireflyId),
          fireflySplitIndex: Value(fireflySplitIndex),
        ),
        mode: InsertMode.insertOrReplace,
      );
}

Future<void> _tombstoneMapRow(FireflySyncMapEntry map) async {
  await _upsertSyncMap(
    syncMapPk: map.syncMapPk,
    type: map.entityType,
    localPk: map.localPk,
    fireflyId: map.fireflyId,
    fireflyUpdatedAt: map.fireflyUpdatedAt,
    lastSyncedLocalModified: map.lastSyncedLocalModified,
    isTombstone: true,
    counterpartyFireflyId: map.counterpartyFireflyId,
    fireflySplitIndex: map.fireflySplitIndex,
  );
}

// ---------------------------------------------------------------------------
// Pull
// ---------------------------------------------------------------------------

Future<Set<int>> _pullCategories(
    FireflyApiClient client, FireflySyncReport report) async {
  List<FireflyCategory> remoteCategories = await client.getCategories();
  Set<int> remoteIds = {for (var remote in remoteCategories) remote.id};
  List<TransactionCategory> localMainCategories =
      (await database.getAllCategories()).toList();
  int nextOrder = localMainCategories.isEmpty
      ? 0
      : localMainCategories.map((c) => c.order).reduce((a, b) => a > b ? a : b) +
          1;

  for (FireflyCategory remote in remoteCategories) {
    List<FireflySyncMapEntry> existingForRemote = await _syncMapsByFireflyId(
        FireflySyncEntityType.category, remote.id,
        includeTombstones: true);
    if (existingForRemote.any((m) => m.isTombstone)) continue;

    FireflySyncMapEntry? map =
        existingForRemote.isEmpty ? null : existingForRemote.first;

    if (map == null) {
      TransactionCategory? nameMatch;
      for (TransactionCategory candidate in localMainCategories) {
        if (candidate.mainCategoryPk != null) continue;
        if (candidate.name.trim().toLowerCase() !=
            remote.name.trim().toLowerCase()) continue;
        FireflySyncMapEntry? existingMapForCandidate = await _syncMapByLocalPk(
            FireflySyncEntityType.category, candidate.categoryPk,
            includeTombstones: true);
        if (existingMapForCandidate == null) {
          nameMatch = candidate;
          break;
        }
      }

      if (nameMatch != null) {
        await _upsertSyncMap(
          type: FireflySyncEntityType.category,
          localPk: nameMatch.categoryPk,
          fireflyId: remote.id,
          fireflyUpdatedAt: remote.updatedAt,
          lastSyncedLocalModified: nameMatch.dateTimeModified,
        );
        report.pulledCategories++;
      } else {
        TransactionCategory newCategory = fireflyCategoryToCategory(remote,
            order: nextOrder);
        nextOrder++;
        await database.createOrUpdateCategory(newCategory,
            insert: false, updateSharedEntry: false);
        TransactionCategory? inserted =
            await database.getCategoryInstanceOrNull(newCategory.categoryPk);
        if (inserted == null) continue;
        await _upsertSyncMap(
          type: FireflySyncEntityType.category,
          localPk: inserted.categoryPk,
          fireflyId: remote.id,
          fireflyUpdatedAt: remote.updatedAt,
          lastSyncedLocalModified: inserted.dateTimeModified,
        );
        report.pulledCategories++;
      }
      continue;
    }

    TransactionCategory? local =
        await database.getCategoryInstanceOrNull(map.localPk);
    if (local == null) {
      continue;
    }

    FireflySyncDirection direction = decideSyncDirection(
      localModified: local.dateTimeModified,
      remoteUpdatedAt: remote.updatedAt,
      lastSyncedLocalModified: map.lastSyncedLocalModified,
      lastSyncedRemoteUpdatedAt: map.fireflyUpdatedAt,
    );
    if (direction == FireflySyncDirection.pull) {
      // Merge onto the row already on disk rather than replacing it.
      // createOrUpdateCategory persists with insertOrReplace, so a freshly
      // built object would blank every column Firefly knows nothing about -
      // colour, icon, emoji, the income flag and the subcategory link - each
      // time the category is renamed on the server.
      TransactionCategory updated = _mergeFireflyCategory(
        local,
        fireflyCategoryToCategory(
          remote,
          order: local.order,
          existingCategoryPk: local.categoryPk,
        ),
      );
      await database.createOrUpdateCategory(updated,
          insert: false, updateSharedEntry: false);
      TransactionCategory? saved =
          await database.getCategoryInstanceOrNull(local.categoryPk);
      await _upsertSyncMap(
        syncMapPk: map.syncMapPk,
        type: FireflySyncEntityType.category,
        localPk: local.categoryPk,
        fireflyId: remote.id,
        fireflyUpdatedAt: remote.updatedAt,
        lastSyncedLocalModified: saved?.dateTimeModified ?? updated.dateTimeModified,
      );
      report.pulledCategories++;
    }
  }
  return remoteIds;
}

Future<Set<int>> _pullAccounts(
    FireflyApiClient client, FireflySyncReport report) async {
  List<FireflyAccount> remoteAccounts =
      await client.getAccounts(type: kFireflyAssetAccountType);
  Set<int> remoteIds = {for (var remote in remoteAccounts) remote.id};
  List<TransactionWallet> localWallets = await database.getAllWallets();
  int nextOrder = localWallets.isEmpty
      ? 0
      : localWallets.map((w) => w.order).reduce((a, b) => a > b ? a : b) + 1;

  for (FireflyAccount remote in remoteAccounts) {
    List<FireflySyncMapEntry> existingForRemote = await _syncMapsByFireflyId(
        FireflySyncEntityType.wallet, remote.id,
        includeTombstones: true);
    if (existingForRemote.any((m) => m.isTombstone)) continue;

    FireflySyncMapEntry? map =
        existingForRemote.isEmpty ? null : existingForRemote.first;

    if (map == null) {
      TransactionWallet? nameMatch;
      for (TransactionWallet candidate in localWallets) {
        if (candidate.name.trim().toLowerCase() !=
            remote.name.trim().toLowerCase()) continue;
        FireflySyncMapEntry? existingMapForCandidate = await _syncMapByLocalPk(
            FireflySyncEntityType.wallet, candidate.walletPk,
            includeTombstones: true);
        if (existingMapForCandidate == null) {
          nameMatch = candidate;
          break;
        }
      }

      if (nameMatch != null) {
        await _upsertSyncMap(
          type: FireflySyncEntityType.wallet,
          localPk: nameMatch.walletPk,
          fireflyId: remote.id,
          fireflyUpdatedAt: remote.updatedAt,
          lastSyncedLocalModified: nameMatch.dateTimeModified,
        );
        report.pulledWallets++;
      } else {
        TransactionWallet newWallet =
            fireflyAccountToWallet(remote, order: nextOrder);
        nextOrder++;
        await database.createOrUpdateWallet(newWallet, insert: false);
        TransactionWallet? inserted =
            await database.getWalletInstanceOrNull(newWallet.walletPk);
        if (inserted == null) continue;
        await _upsertSyncMap(
          type: FireflySyncEntityType.wallet,
          localPk: inserted.walletPk,
          fireflyId: remote.id,
          fireflyUpdatedAt: remote.updatedAt,
          lastSyncedLocalModified: inserted.dateTimeModified,
        );
        report.pulledWallets++;
      }
      continue;
    }

    TransactionWallet? local =
        await database.getWalletInstanceOrNull(map.localPk);
    if (local == null) {
      continue;
    }

    FireflySyncDirection direction = decideSyncDirection(
      localModified: local.dateTimeModified,
      remoteUpdatedAt: remote.updatedAt,
      lastSyncedLocalModified: map.lastSyncedLocalModified,
      lastSyncedRemoteUpdatedAt: map.fireflyUpdatedAt,
    );
    if (direction == FireflySyncDirection.pull) {
      // Same reasoning as _mergeFireflyCategory: createOrUpdateWallet writes
      // with insertOrReplace, so rebuilding the wallet from the Firefly
      // account alone would reset its colour, icon, currency format, decimals
      // and home-screen placement every time it is renamed remotely.
      TransactionWallet updated = _mergeFireflyWallet(
        local,
        fireflyAccountToWallet(
          remote,
          order: local.order,
          existingWalletPk: local.walletPk,
        ),
      );
      await database.createOrUpdateWallet(updated, insert: false);
      TransactionWallet? saved =
          await database.getWalletInstanceOrNull(local.walletPk);
      await _upsertSyncMap(
        syncMapPk: map.syncMapPk,
        type: FireflySyncEntityType.wallet,
        localPk: local.walletPk,
        fireflyId: remote.id,
        fireflyUpdatedAt: remote.updatedAt,
        lastSyncedLocalModified: saved?.dateTimeModified ?? updated.dateTimeModified,
      );
      report.pulledWallets++;
    }
  }
  return remoteIds;
}

// Creates the two local categories the Firefly integration depends on, if
// they are not there yet. Both are cheap no-ops once they exist.
Future<void> _ensureFireflySystemCategories() async {
  await initializeBalanceCorrectionCategory();
  if (await database.getCategoryInstanceOrNull(
          kFireflyUncategorizedCategoryPk) !=
      null) {
    return;
  }
  int numberOfCategories = (await database.getTotalCountOfCategories())[0] ?? 0;
  await database.createOrUpdateCategory(
    insert: false,
    updateSharedEntry: false,
    TransactionCategory(
      categoryPk: kFireflyUncategorizedCategoryPk,
      name: "firefly-uncategorized".tr(),
      colour: null,
      iconName: "price-tag.png",
      dateCreated: DateTime.now(),
      dateTimeModified: null,
      order: numberOfCategories,
      income: false,
      methodAdded: MethodAdded.firefly,
    ),
  );
}

Future<Set<int>> _pullTransactions(
  FireflyApiClient client,
  FireflySyncReport report, {
  // Lower bound on booking date. null pulls the whole history.
  DateTime? windowStart,
  // Already-fetched groups to apply instead of listing them. Used by the
  // on-demand fetches so they share this exact apply logic rather than
  // growing a second, subtly different copy of it.
  List<FireflyTransactionGroup>? preFetchedGroups,
}) async {
  List<FireflyTransactionGroup> groups = preFetchedGroups ??
      await client.getTransactions(start: windowStart);
  Set<int> remoteIds = {for (var group in groups) group.id};

  List<FireflySyncMapEntry> walletMaps =
      await _syncMapEntriesForType(FireflySyncEntityType.wallet);
  Map<int, String> walletFireflyIdToLocalPk = {
    for (var m in walletMaps) m.fireflyId: m.localPk
  };
  Set<int> assetFireflyIds = walletFireflyIdToLocalPk.keys.toSet();
  List<FireflySyncMapEntry> categoryMaps =
      await _syncMapEntriesForType(FireflySyncEntityType.category);
  Map<int, String> categoryFireflyIdToLocalPk = {
    for (var m in categoryMaps) m.fireflyId: m.localPk
  };

  for (FireflyTransactionGroup group in groups) {
    if (group.splits.isEmpty) continue;

    // Tombstones belong to a single split, not to the whole journal. Skipping
    // the entire group when any one split was deleted locally froze all of its
    // siblings: they kept their mappings but stopped receiving remote updates,
    // permanently.
    Set<int> tombstonedSplitIndexes = {
      for (FireflySyncMapEntry m in await _syncMapsByFireflyId(
          FireflySyncEntityType.transaction, group.id,
          includeTombstones: true))
        if (m.isTombstone) m.fireflySplitIndex
    };

    for (int splitIndex = 0; splitIndex < group.splits.length; splitIndex++) {
      if (tombstonedSplitIndexes.contains(splitIndex)) continue;
      FireflyTransactionSplit split = group.splits[splitIndex];
      FireflyPulledSplitKind kind = classifySplitType(split.type);
      if (kind == FireflyPulledSplitKind.skip) {
        report.skippedUnsupported++;
        continue;
      }

      // Opening-balance and reconciliation journals are Firefly's own
      // bookkeeping entries, tied to how an account was set up rather than to
      // anything the user did. Importing them as ordinary transactions was
      // actively harmful: nothing recorded that they were special, so the
      // first local edit pushed them back as a plain withdrawal/deposit and
      // corrupted the remote account's opening balance. Their monetary effect
      // is already included in Firefly's current_balance, which is what the
      // balance anchor is computed from, so skipping them here loses nothing.
      if (splitKindIsBalanceCorrection(kind)) {
        report.skippedUnsupported++;
        continue;
      }

      if (kind == FireflyPulledSplitKind.transfer) {
        await _pullTransferSplit(
          group: group,
          split: split,
          splitIndex: splitIndex,
          walletFireflyIdToLocalPk: walletFireflyIdToLocalPk,
          report: report,
        );
        continue;
      }

      int? assetId = assetFireflyIdForSplit(split, assetFireflyIds);
      if (assetId == null) {
        report.skippedUnmappedWallet++;
        continue;
      }
      String? walletPk = walletFireflyIdToLocalPk[assetId];
      if (walletPk == null) {
        report.skippedUnmappedWallet++;
        continue;
      }

      bool isIncome = splitIsIncomeForAsset(split, assetId);
      String categoryPk = split.categoryId == null
          ? kFireflyUncategorizedCategoryPk
          : (categoryFireflyIdToLocalPk[split.categoryId] ??
              kFireflyUncategorizedCategoryPk);
      int? counterpartyId = counterpartyFireflyIdForSplit(split, assetId);

      // KNOWN LIMITATION: splits are matched by their position in the group.
      // Position is not a stable identity - deleting a middle split on Firefly
      // shifts every later split down one, after which a stored index points
      // at its neighbour, so one local row is updated from the wrong split and
      // the last one is re-imported as a duplicate. Firefly does give each
      // split a stable transaction_journal_id; using it needs a new column on
      // FireflySyncMap, which needs a Drift schema regeneration (and so the
      // Flutter SDK), so it is deliberately left for that change rather than
      // half-solved here. Deletions made through Cashew already reindex the
      // survivors (see _removeSplitFromRemoteGroup); this only bites when the
      // split was removed on the Firefly side.
      List<FireflySyncMapEntry> groupMaps = await _syncMapsByFireflyId(
          FireflySyncEntityType.transaction, group.id);
      FireflySyncMapEntry? existingMap;
      for (FireflySyncMapEntry candidate in groupMaps) {
        if (candidate.fireflySplitIndex == splitIndex) {
          existingMap = candidate;
          break;
        }
      }

      if (existingMap == null) {
        Transaction newTransaction = fireflySplitToTransaction(
          split,
          walletPk: walletPk,
          categoryPk: categoryPk,
          isIncome: isIncome,
        );
        // Inserting the row and recording its mapping have to commit or fail
        // together. If the row landed but the map did not, the next pull would
        // see no mapping and insert a second copy, and the push would see an
        // unmapped local row and create a duplicate on Firefly too - one
        // interrupted sync, duplicated on both sides, permanently.
        bool inserted = await database.transaction(() async {
          await database.createOrUpdateTransaction(newTransaction,
              insert: false, updateSharedEntry: false, fireflySync: true);
          Transaction? saved = await database
              .tryGetTransactionFromPk(newTransaction.transactionPk);
          if (saved == null) return false;
          await _upsertSyncMap(
            type: FireflySyncEntityType.transaction,
            localPk: saved.transactionPk,
            fireflyId: group.id,
            fireflyUpdatedAt: group.updatedAt,
            lastSyncedLocalModified: saved.dateTimeModified,
            counterpartyFireflyId: counterpartyId,
            fireflySplitIndex: splitIndex,
          );
          return true;
        });
        if (!inserted) continue;
        report.pulledTransactions++;
      } else {
        Transaction? local =
            await database.tryGetTransactionFromPk(existingMap.localPk);
        if (local == null) continue;
        FireflySyncDirection direction = decideSyncDirection(
          localModified: local.dateTimeModified,
          remoteUpdatedAt: group.updatedAt,
          lastSyncedLocalModified: existingMap.lastSyncedLocalModified,
          lastSyncedRemoteUpdatedAt: existingMap.fireflyUpdatedAt,
        );
        if (direction == FireflySyncDirection.pull) {
          Transaction updated = fireflyApplySplitToExisting(
            local,
            split,
            walletPk: walletPk,
            categoryPk: categoryPk,
            isIncome: isIncome,
          );
          await database.createOrUpdateTransaction(updated,
              insert: false, updateSharedEntry: false, fireflySync: true);
          Transaction? saved =
              await database.tryGetTransactionFromPk(local.transactionPk);
          await _upsertSyncMap(
            syncMapPk: existingMap.syncMapPk,
            type: FireflySyncEntityType.transaction,
            localPk: local.transactionPk,
            fireflyId: group.id,
            fireflyUpdatedAt: group.updatedAt,
            lastSyncedLocalModified:
                saved?.dateTimeModified ?? updated.dateTimeModified,
            counterpartyFireflyId: counterpartyId,
            fireflySplitIndex: splitIndex,
          );
          report.pulledTransactions++;
        }
      }
    }
  }
  return remoteIds;
}

Future<void> _pullTransferSplit({
  required FireflyTransactionGroup group,
  required FireflyTransactionSplit split,
  required int splitIndex,
  required Map<int, String> walletFireflyIdToLocalPk,
  required FireflySyncReport report,
}) async {
  String? sourcePk =
      split.sourceId == null ? null : walletFireflyIdToLocalPk[split.sourceId];
  String? destPk = split.destinationId == null
      ? null
      : walletFireflyIdToLocalPk[split.destinationId];
  if (sourcePk == null || destPk == null) {
    report.skippedUnmappedWallet++;
    return;
  }

  List<FireflySyncMapEntry> existingMaps = await _syncMapsByFireflyId(
      FireflySyncEntityType.transaction, group.id);
  List<FireflySyncMapEntry> thisSplitMaps = existingMaps
      .where((m) => m.fireflySplitIndex == splitIndex)
      .toList();

  if (thisSplitMaps.isEmpty) {
    (Transaction, Transaction) pair = fireflySplitToTransferPair(
      split,
      sourceWalletPk: sourcePk,
      destWalletPk: destPk,
    );
    // Both legs and both mappings commit together or not at all. A partial
    // commit here would leave a half transfer, or an unmapped pair that the
    // next cycle re-imports and also pushes back as a new remote transfer.
    await database.transaction(() async {
      await database.createOrUpdateTransaction(pair.$1,
          insert: false, updateSharedEntry: false, fireflySync: true);
      await database.createOrUpdateTransaction(pair.$2,
          insert: false, updateSharedEntry: false, fireflySync: true);
      Transaction? savedFrom =
          await database.tryGetTransactionFromPk(pair.$1.transactionPk);
      Transaction? savedTo =
          await database.tryGetTransactionFromPk(pair.$2.transactionPk);
      await _upsertSyncMap(
        type: FireflySyncEntityType.transaction,
        localPk: pair.$1.transactionPk,
        fireflyId: group.id,
        fireflyUpdatedAt: group.updatedAt,
        lastSyncedLocalModified: savedFrom?.dateTimeModified,
        fireflySplitIndex: splitIndex,
      );
      await _upsertSyncMap(
        type: FireflySyncEntityType.transaction,
        localPk: pair.$2.transactionPk,
        fireflyId: group.id,
        fireflyUpdatedAt: group.updatedAt,
        lastSyncedLocalModified: savedTo?.dateTimeModified,
        fireflySplitIndex: splitIndex,
      );
    });
    report.pulledTransactions += 2;
    return;
  }

  Transaction? first =
      await database.tryGetTransactionFromPk(thisSplitMaps.first.localPk);
  if (first == null) return;
  DateTime? newestLocal = first.dateTimeModified;
  DateTime? newestWatermark = thisSplitMaps.first.lastSyncedLocalModified;
  for (FireflySyncMapEntry map in thisSplitMaps) {
    Transaction? local = await database.tryGetTransactionFromPk(map.localPk);
    if (local?.dateTimeModified != null &&
        (newestLocal == null ||
            local!.dateTimeModified!.isAfter(newestLocal))) {
      newestLocal = local.dateTimeModified;
    }
    if (map.lastSyncedLocalModified != null &&
        (newestWatermark == null ||
            map.lastSyncedLocalModified!.isAfter(newestWatermark))) {
      newestWatermark = map.lastSyncedLocalModified;
    }
  }
  FireflySyncDirection direction = decideSyncDirection(
    localModified: newestLocal,
    remoteUpdatedAt: group.updatedAt,
    lastSyncedLocalModified: newestWatermark,
    lastSyncedRemoteUpdatedAt: thisSplitMaps.first.fireflyUpdatedAt,
  );
  if (direction != FireflySyncDirection.pull) return;

  String? existingSourcePk;
  String? existingDestPk;
  for (FireflySyncMapEntry map in thisSplitMaps) {
    Transaction? local = await database.tryGetTransactionFromPk(map.localPk);
    if (local == null) continue;
    if (local.amount < 0) {
      existingSourcePk = local.transactionPk;
    } else {
      existingDestPk = local.transactionPk;
    }
  }
  (Transaction, Transaction) rebuilt = fireflySplitToTransferPair(
    split,
    sourceWalletPk: sourcePk,
    destWalletPk: destPk,
    existingSourceTransactionPk: existingSourcePk,
    existingDestTransactionPk: existingDestPk,
  );
  // Merge onto the rows already on disk rather than replacing them outright -
  // createOrUpdateTransaction persists with insertOrReplace, so any column not
  // present in the companion would come back as its default and every
  // Cashew-only field on the transfer would be lost on each remote edit.
  (Transaction, Transaction) pair = (
    _mergeFireflyTransferSide(
        existingSourcePk == null
            ? null
            : await database.tryGetTransactionFromPk(existingSourcePk),
        rebuilt.$1),
    _mergeFireflyTransferSide(
        existingDestPk == null
            ? null
            : await database.tryGetTransactionFromPk(existingDestPk),
        rebuilt.$2),
  );
  await database.createOrUpdateTransaction(pair.$1,
      insert: false, updateSharedEntry: false, fireflySync: true);
  await database.createOrUpdateTransaction(pair.$2,
      insert: false, updateSharedEntry: false, fireflySync: true);
  Transaction? savedFrom =
      await database.tryGetTransactionFromPk(pair.$1.transactionPk);
  Transaction? savedTo =
      await database.tryGetTransactionFromPk(pair.$2.transactionPk);
  FireflySyncMapEntry? fromMap = thisSplitMaps.cast<FireflySyncMapEntry?>().firstWhere(
      (m) => m?.localPk == pair.$1.transactionPk,
      orElse: () => null);
  FireflySyncMapEntry? toMap = thisSplitMaps.cast<FireflySyncMapEntry?>().firstWhere(
      (m) => m?.localPk == pair.$2.transactionPk,
      orElse: () => null);
  await _upsertSyncMap(
    syncMapPk: fromMap?.syncMapPk,
    type: FireflySyncEntityType.transaction,
    localPk: pair.$1.transactionPk,
    fireflyId: group.id,
    fireflyUpdatedAt: group.updatedAt,
    lastSyncedLocalModified: savedFrom?.dateTimeModified,
    fireflySplitIndex: splitIndex,
  );
  await _upsertSyncMap(
    syncMapPk: toMap?.syncMapPk,
    type: FireflySyncEntityType.transaction,
    localPk: pair.$2.transactionPk,
    fireflyId: group.id,
    fireflyUpdatedAt: group.updatedAt,
    lastSyncedLocalModified: savedTo?.dateTimeModified,
    fireflySplitIndex: splitIndex,
  );
  report.pulledTransactions += 2;
}

// Firefly only knows a category's name, so that is the only thing a pull is
// allowed to carry onto an existing local category.
TransactionCategory _mergeFireflyCategory(
    TransactionCategory existing, TransactionCategory rebuilt) {
  return existing.copyWith(
    name: rebuilt.name,
    dateTimeModified: Value(rebuilt.dateTimeModified),
  );
}

// Likewise for accounts: name and currency are Firefly's, everything else on
// the wallet belongs to Cashew.
TransactionWallet _mergeFireflyWallet(
    TransactionWallet existing, TransactionWallet rebuilt) {
  return existing.copyWith(
    name: rebuilt.name,
    currency: Value(rebuilt.currency),
    dateTimeModified: Value(rebuilt.dateTimeModified),
  );
}

// Applies the Firefly-owned fields of a rebuilt transfer leg onto the row
// that is already stored, preserving everything Cashew owns.
Transaction _mergeFireflyTransferSide(
    Transaction? existing, Transaction rebuilt) {
  if (existing == null) return rebuilt;
  return existing.copyWith(
    pairedTransactionFk: Value(rebuilt.pairedTransactionFk),
    name: rebuilt.name,
    amount: rebuilt.amount,
    note: rebuilt.note,
    categoryFk: rebuilt.categoryFk,
    walletFk: rebuilt.walletFk,
    dateCreated: rebuilt.dateCreated,
    dateTimeModified: Value(rebuilt.dateTimeModified),
    income: rebuilt.income,
    paid: rebuilt.paid,
  );
}

// ---------------------------------------------------------------------------
// Remote deletes
// ---------------------------------------------------------------------------

// Removes local rows for records that no longer exist on Firefly.
//
// This is the single most destructive thing the engine does, and its
// correctness rests entirely on one premise: that the caller passed a
// COMPLETE remote id set for the scope being reconciled. Two safeguards keep
// that premise true:
//
//  * The API client refuses to return a partially-paginated list, throwing
//    instead - so a truncated fetch aborts the sync rather than being
//    mistaken for "everything else was deleted".
//  * Transactions are only reconciled inside the booking-date window that was
//    actually pulled. Everything older was never requested, so its absence
//    from remoteTransactionIds carries no information at all. Reconciling it
//    would delete the user's entire history beyond the window on the first
//    sync after this feature shipped.
//
// Accounts and categories have no window - they are fetched as complete lists
// every cycle - so they are reconciled in full.
Future<void> _applyRemoteDeletes({
  required FireflyApiClient client,
  required Set<int> remoteCategoryIds,
  required Set<int> remoteWalletIds,
  required Set<int> remoteTransactionIds,
  // Lower bound of the booking-date window that produced remoteTransactionIds.
  // null means the whole history was pulled and everything is in scope.
  required DateTime? windowStart,
  required FireflySyncReport report,
}) async {
  // Firefly groups already checked one by one this pass: true = still on the
  // server, false = confirmed gone. A journal can hold several mapped splits
  // and there is no point asking about it more than once.
  Map<int, bool> stillOnFirefly = {};

  for (FireflySyncMapEntry map
      in await _syncMapEntriesForType(FireflySyncEntityType.transaction)) {
    if (remoteTransactionIds.contains(map.fireflyId)) continue;

    if (windowStart != null) {
      Transaction? local = await database.tryGetTransactionFromPk(map.localPk);
      // No local row left - nothing to delete, just retire the mapping.
      if (local == null) {
        await _tombstoneMapRow(map);
        continue;
      }
      // Booked before the window we pulled, so we simply did not ask Firefly
      // about it. Leave it alone.
      if (local.dateCreated.isBefore(windowStart)) continue;

      // The local row sits inside the window we asked for, yet the record did
      // not come back. That still is not proof of a deletion: re-dating a
      // transaction on Firefly to before windowStart moves it out of the
      // window while leaving it perfectly intact, and the local copy keeps its
      // old (in-window) date, so this reconciliation is the only thing that
      // would notice. Getting it wrong is unrecoverable - the row is deleted
      // and its mapping tombstoned, and a tombstone stops even "Sync all
      // history" from ever bringing it back. Ask the server about this one
      // record before destroying anything.
      bool? known = stillOnFirefly[map.fireflyId];
      if (known == null) {
        try {
          FireflyTransactionGroup remote =
              await client.getTransaction(map.fireflyId);
          known = true;
          // Re-apply it so the local copy follows whatever moved it out of the
          // window. Once its dateCreated matches the remote booking date the
          // check above skips it on every later cycle.
          await _pullTransactions(client, report, preFetchedGroups: [remote]);
        } on FireflyNotFoundException {
          known = false;
        } catch (_) {
          // A network or server failure is not evidence of a deletion either.
          // Keep the row and retry on the next cycle.
          report.warnings.add(
              "Could not confirm with Firefly whether a transaction was "
              "deleted, so it was kept locally.");
          continue;
        }
        stillOnFirefly[map.fireflyId] = known;
      }
      if (known == true) continue;
    }

    await _deleteLocalTransactionFromRemote(map, report);
  }

  for (FireflySyncMapEntry map
      in await _syncMapEntriesForType(FireflySyncEntityType.category)) {
    if (remoteCategoryIds.contains(map.fireflyId)) continue;
    await _deleteLocalCategoryFromRemote(map, report);
  }

  for (FireflySyncMapEntry map
      in await _syncMapEntriesForType(FireflySyncEntityType.wallet)) {
    if (remoteWalletIds.contains(map.fireflyId)) continue;
    await _deleteLocalWalletFromRemote(map, report);
  }
}

Future<void> _deleteLocalTransactionFromRemote(
    FireflySyncMapEntry map, FireflySyncReport report) async {
  Transaction? local = await database.tryGetTransactionFromPk(map.localPk);
  if (local != null) {
    await database.deleteTransaction(map.localPk, updateSharedEntry: false);
    report.deletedLocal++;
  }
  await _tombstoneMapRow(map);
}

Future<void> _deleteLocalCategoryFromRemote(
    FireflySyncMapEntry map, FireflySyncReport report) async {
  TransactionCategory? local =
      await database.getCategoryInstanceOrNull(map.localPk);
  if (local != null) {
    List<Transaction> inCategory =
        await database.getAllTransactionsFromCategory(local.categoryPk);
    for (Transaction transaction in inCategory) {
      await database.createOrUpdateTransaction(
        transaction.copyWith(categoryFk: kFireflyUncategorizedCategoryPk),
        insert: false,
        updateSharedEntry: false,
        fireflySync: true,
      );
    }
    await database.createDeleteLog(
        DeleteLogType.TransactionCategory, local.categoryPk);
    await (database.delete(database.categories)
          ..where((c) => c.categoryPk.equals(local.categoryPk)))
        .go();
    report.deletedLocal++;
  }
  await _tombstoneMapRow(map);
}

Future<void> _deleteLocalWalletFromRemote(
    FireflySyncMapEntry map, FireflySyncReport report) async {
  TransactionWallet? local =
      await database.getWalletInstanceOrNull(map.localPk);
  if (local == null) {
    await _tombstoneMapRow(map);
    return;
  }
  if (local.walletPk == "0") {
    report.warnings.add(
        "Firefly deleted the account for the default wallet; the local wallet was kept.");
    await _tombstoneMapRow(map);
    return;
  }
  List<Transaction> remaining =
      await database.getAllTransactionsFromWallet(local.walletPk);
  if (remaining.isNotEmpty) {
    report.warnings.add(
        "Firefly deleted account \"${local.name}\" but it still has ${remaining.length} local transaction(s); the wallet was kept.");
    await _tombstoneMapRow(map);
    return;
  }
  await database.deleteWallet(local.walletPk, local.order);
  report.deletedLocal++;
  await _tombstoneMapRow(map);
}

// ---------------------------------------------------------------------------
// Push
// ---------------------------------------------------------------------------

Future<void> _pushCategories(FireflyApiClient client, DateTime lastSynced,
    FireflySyncReport report,
    {required bool includeUnmodifiedRows}) async {
  List<TransactionCategory> changed =
      await database.getAllNewCategories(lastSynced);
  for (TransactionCategory category in changed) {
    // getAllNew*() also returns rows whose dateTimeModified is NULL. Those are
    // not recent edits: they are legacy rows from before the dateTimeModified
    // column existed, and anything restored from an old backup. Uploading them
    // unasked is exactly what pushExistingLocalHistory exists to prevent, so
    // they only go up when the user explicitly asked for their history.
    if (category.dateTimeModified == null && !includeUnmodifiedRows) continue;
    // Local placeholder for "Firefly has no category here" - sending it would
    // create a bogus category on the server and then start attaching real
    // transactions to it.
    if (category.categoryPk == kFireflyUncategorizedCategoryPk) continue;
    // Cashew's reserved balance-correction category. It holds the synthetic
    // balance anchors and the user's own manual corrections - an artefact of
    // how Cashew stores balances, not a category Firefly should grow. It needs
    // its own guard because _ensureFireflySystemCategories creates it with a
    // fresh dateTimeModified, so it looks freshly edited on the very first
    // sync and would be pushed in that same cycle.
    if (category.categoryPk == kBalanceCorrectionCategoryPk) continue;
    if (category.mainCategoryPk != null) {
      report.skippedSubcategories++;
      continue;
    }
    FireflyCategory? remoteShape = categoryToFireflyCategory(category);
    if (remoteShape == null) continue;

    FireflySyncMapEntry? tombstone = await _syncMapByLocalPk(
        FireflySyncEntityType.category, category.categoryPk,
        includeTombstones: true);
    if (tombstone != null && tombstone.isTombstone) continue;

    FireflySyncMapEntry? map = await _syncMapByLocalPk(
        FireflySyncEntityType.category, category.categoryPk);
    if (map == null) {
      FireflyCategory created = await client.createCategory(remoteShape);
      await _upsertSyncMap(
        type: FireflySyncEntityType.category,
        localPk: category.categoryPk,
        fireflyId: created.id,
        fireflyUpdatedAt: created.updatedAt,
        lastSyncedLocalModified: category.dateTimeModified,
      );
      report.pushedCategories++;
    } else {
      FireflySyncDirection direction = decideSyncDirection(
        localModified: category.dateTimeModified,
        remoteUpdatedAt: map.fireflyUpdatedAt,
        lastSyncedLocalModified: map.lastSyncedLocalModified,
        lastSyncedRemoteUpdatedAt: map.fireflyUpdatedAt,
      );
      if (direction == FireflySyncDirection.push) {
        FireflyCategory updated =
            await client.updateCategory(map.fireflyId, remoteShape);
        await _upsertSyncMap(
          syncMapPk: map.syncMapPk,
          type: FireflySyncEntityType.category,
          localPk: category.categoryPk,
          fireflyId: map.fireflyId,
          fireflyUpdatedAt: updated.updatedAt,
          lastSyncedLocalModified: category.dateTimeModified,
        );
        report.pushedCategories++;
      }
    }
  }
}

Future<void> _pushAccounts(FireflyApiClient client, DateTime lastSynced,
    FireflySyncReport report,
    {required bool includeUnmodifiedRows}) async {
  List<TransactionWallet> changed = await database.getAllNewWallets(lastSynced);
  for (TransactionWallet wallet in changed) {
    // getAllNew*() also returns rows whose dateTimeModified is NULL. Those are
    // not recent edits: they are legacy rows from before the dateTimeModified
    // column existed, and anything restored from an old backup. Uploading them
    // unasked is exactly what pushExistingLocalHistory exists to prevent, so
    // they only go up when the user explicitly asked for their history.
    if (wallet.dateTimeModified == null && !includeUnmodifiedRows) continue;
    FireflySyncMapEntry? tombstone = await _syncMapByLocalPk(
        FireflySyncEntityType.wallet, wallet.walletPk,
        includeTombstones: true);
    if (tombstone != null && tombstone.isTombstone) continue;

    FireflySyncMapEntry? map =
        await _syncMapByLocalPk(FireflySyncEntityType.wallet, wallet.walletPk);
    if (map == null) {
      FireflyAccount created =
          await client.createAccount(walletToFireflyAccount(wallet));
      await _upsertSyncMap(
        type: FireflySyncEntityType.wallet,
        localPk: wallet.walletPk,
        fireflyId: created.id,
        fireflyUpdatedAt: created.updatedAt,
        lastSyncedLocalModified: wallet.dateTimeModified,
      );
      report.pushedWallets++;
    } else {
      FireflySyncDirection direction = decideSyncDirection(
        localModified: wallet.dateTimeModified,
        remoteUpdatedAt: map.fireflyUpdatedAt,
        lastSyncedLocalModified: map.lastSyncedLocalModified,
        lastSyncedRemoteUpdatedAt: map.fireflyUpdatedAt,
      );
      if (direction == FireflySyncDirection.push) {
        // Cashew has no account-role concept, so pushing a wallet would send
        // the default role and demote a savings account or credit card back
        // to a plain asset account. Carry the server's own role through the
        // update instead of overwriting it.
        String? existingRole;
        try {
          existingRole = (await client.getAccount(map.fireflyId)).accountRole;
        } catch (_) {}
        FireflyAccount updated = await client.updateAccount(
          map.fireflyId,
          walletToFireflyAccount(wallet, existingAccountRole: existingRole),
        );
        await _upsertSyncMap(
          syncMapPk: map.syncMapPk,
          type: FireflySyncEntityType.wallet,
          localPk: wallet.walletPk,
          fireflyId: map.fireflyId,
          fireflyUpdatedAt: updated.updatedAt,
          lastSyncedLocalModified: wallet.dateTimeModified,
        );
        report.pushedWallets++;
      }
    }
  }
}

Future<void> _pushTransactions(
    FireflyApiClient client,
    DateTime lastSynced,
    _FireflyCounterpartyIndex counterparties,
    FireflySyncReport report,
    {required bool includeUnmodifiedRows}) async {
  List<Transaction> changed = await database.getAllNewTransactions(lastSynced);
  Set<String> handledThisPass = {};

  for (Transaction transaction in changed) {
    if (handledThisPass.contains(transaction.transactionPk)) continue;
    // getAllNew*() also returns rows whose dateTimeModified is NULL. Those are
    // not recent edits: they are legacy rows from before the dateTimeModified
    // column existed, and anything restored from an old backup. Uploading them
    // unasked is exactly what pushExistingLocalHistory exists to prevent, so
    // they only go up when the user explicitly asked for their history.
    if (transaction.dateTimeModified == null && !includeUnmodifiedRows) {
      continue;
    }

    // Balance anchors exist only because the local database holds a window
    // rather than the whole ledger. Firefly already knows the balance they
    // stand in for, so pushing one would double-count it on the remote side.
    if (isFireflyBalanceAnchorPk(transaction.transactionPk)) continue;

    FireflySyncMapEntry? tombstone = await _syncMapByLocalPk(
        FireflySyncEntityType.transaction, transaction.transactionPk,
        includeTombstones: true);
    if (tombstone != null && tombstone.isTombstone) continue;

    if (transaction.pairedTransactionFk != null) {
      await _pushTransfer(
        client: client,
        transaction: transaction,
        handledThisPass: handledThisPass,
        report: report,
      );
      continue;
    }

    FireflySyncMapEntry? walletMap = await _syncMapByLocalPk(
        FireflySyncEntityType.wallet, transaction.walletFk);
    if (walletMap == null) {
      report.skippedUnmappedWallet++;
      continue;
    }

    FireflySyncMapEntry? categoryMap = await _syncMapByLocalPk(
        FireflySyncEntityType.category, transaction.categoryFk);
    TransactionCategory? category;
    try {
      category = await database.getCategoryInstance(transaction.categoryFk);
    } catch (_) {}
    // Round-trips as uncategorised rather than inventing a category remotely.
    if (transaction.categoryFk == kFireflyUncategorizedCategoryPk) {
      category = null;
    }

    FireflySyncMapEntry? map = await _syncMapByLocalPk(
        FireflySyncEntityType.transaction, transaction.transactionPk);

    FireflyAccount? counterparty = resolvePushCounterparty(
      isIncome: transaction.amount > 0,
      transactionName: transaction.name,
      categoryName: category?.name,
      storedCounterpartyId: map?.counterpartyFireflyId,
      counterpartiesById: counterparties.byId,
      expenseByName: counterparties.expenseByName,
      revenueByName: counterparties.revenueByName,
    );

    if (map != null) {
      List<FireflySyncMapEntry> groupMaps =
          await _syncMapsByFireflyId(FireflySyncEntityType.transaction, map.fireflyId);
      bool multiSplit = groupMaps.any((m) => m.fireflySplitIndex != map.fireflySplitIndex);
      if (multiSplit) {
        await _pushExistingMultiSplitGroup(
          client: client,
          groupMaps: groupMaps,
          counterparties: counterparties,
          report: report,
        );
        for (FireflySyncMapEntry groupMap in groupMaps) {
          handledThisPass.add(groupMap.localPk);
        }
        continue;
      }
    }

    FireflyTransactionSplit split = transactionToFireflySplit(
      transaction,
      walletFireflyId: walletMap.fireflyId,
      categoryFireflyId: categoryMap?.fireflyId,
      categoryName: category?.name,
      counterpartyFireflyId: counterparty?.id,
      counterpartyName: counterparty?.name ?? transaction.name,
    );
    FireflyTransactionGroup group =
        FireflyTransactionGroup(id: 0, splits: [split]);

    if (map == null) {
      FireflyTransactionGroup created = await client.createTransaction(group);
      int? createdCounterpartyId = counterparty?.id;
      if (createdCounterpartyId == null && created.splits.isNotEmpty) {
        createdCounterpartyId = transaction.amount > 0
            ? created.splits.first.sourceId
            : created.splits.first.destinationId;
      }
      await _upsertSyncMap(
        type: FireflySyncEntityType.transaction,
        localPk: transaction.transactionPk,
        fireflyId: created.id,
        fireflyUpdatedAt: created.updatedAt,
        lastSyncedLocalModified: transaction.dateTimeModified,
        counterpartyFireflyId: createdCounterpartyId,
      );
      report.pushedTransactions++;
    } else {
      FireflySyncDirection direction = decideSyncDirection(
        localModified: transaction.dateTimeModified,
        remoteUpdatedAt: map.fireflyUpdatedAt,
        lastSyncedLocalModified: map.lastSyncedLocalModified,
        lastSyncedRemoteUpdatedAt: map.fireflyUpdatedAt,
      );
      if (direction == FireflySyncDirection.push) {
        // Firefly replaces a journal's ENTIRE split list on PUT, and the
        // multiSplit test above is computed purely from the local sync map -
        // it only knows about splits this install actually imported. A journal
        // whose other splits sit on an unlinked account, a liability, or
        // outside the sync window maps to exactly one local row and looks
        // single-split from here. Sending that one split would delete the
        // others on the server, so compare against the live journal first.
        FireflyTransactionGroup remoteGroup;
        try {
          remoteGroup = await client.getTransaction(map.fireflyId);
        } on FireflyNotFoundException {
          await _tombstoneMapRow(map);
          continue;
        }
        if (remoteGroup.splits.length > 1) {
          report.warnings.add(
              "Did not push a change to a split transaction: it has "
              "${remoteGroup.splits.length} splits on Firefly but only one is "
              "stored locally, so updating it would have deleted the rest.");
          continue;
        }
        FireflyTransactionGroup updated =
            await client.updateTransaction(map.fireflyId, group);
        await _upsertSyncMap(
          syncMapPk: map.syncMapPk,
          type: FireflySyncEntityType.transaction,
          localPk: transaction.transactionPk,
          fireflyId: map.fireflyId,
          fireflyUpdatedAt: updated.updatedAt,
          lastSyncedLocalModified: transaction.dateTimeModified,
          counterpartyFireflyId: counterparty?.id ?? map.counterpartyFireflyId,
          fireflySplitIndex: map.fireflySplitIndex,
        );
        report.pushedTransactions++;
      }
    }
  }
}

// Rebuilds the Firefly split for the local row a sync-map entry points at.
//
// Returns null when the row is gone or its wallet is not linked - callers must
// read that as "this group cannot be safely rebuilt", never as "skip this
// split", because Firefly replaces a journal's whole split list on PUT.
Future<FireflyTransactionSplit?> _splitForMappedLocalRow({
  required FireflySyncMapEntry map,
  required _FireflyCounterpartyIndex counterparties,
  Transaction? local,
}) async {
  local ??= await database.tryGetTransactionFromPk(map.localPk);
  if (local == null) return null;
  FireflySyncMapEntry? walletMap =
      await _syncMapByLocalPk(FireflySyncEntityType.wallet, local.walletFk);
  if (walletMap == null) return null;
  FireflySyncMapEntry? categoryMap = await _syncMapByLocalPk(
      FireflySyncEntityType.category, local.categoryFk);
  TransactionCategory? category;
  try {
    category = await database.getCategoryInstance(local.categoryFk);
  } catch (_) {}
  if (local.categoryFk == kFireflyUncategorizedCategoryPk) category = null;
  FireflyAccount? counterparty = resolvePushCounterparty(
    isIncome: local.amount > 0,
    transactionName: local.name,
    categoryName: category?.name,
    storedCounterpartyId: map.counterpartyFireflyId,
    counterpartiesById: counterparties.byId,
    expenseByName: counterparties.expenseByName,
    revenueByName: counterparties.revenueByName,
  );
  return transactionToFireflySplit(
    local,
    walletFireflyId: walletMap.fireflyId,
    categoryFireflyId: categoryMap?.fireflyId,
    categoryName: category?.name,
    counterpartyFireflyId: counterparty?.id,
    counterpartyName: counterparty?.name ?? local.name,
  );
}

Future<void> _pushExistingMultiSplitGroup({
  required FireflyApiClient client,
  required List<FireflySyncMapEntry> groupMaps,
  required _FireflyCounterpartyIndex counterparties,
  required FireflySyncReport report,
}) async {
  groupMaps.sort((a, b) => a.fireflySplitIndex.compareTo(b.fireflySplitIndex));
  List<FireflyTransactionSplit> splits = [];
  // Firefly replaces a journal's entire split list on PUT. If we rebuild fewer
  // splits than the remote group actually has - because a local row was
  // deleted, its wallet is not linked, or the split was never mapped locally
  // in the first place - sending that list silently deletes the missing splits
  // on the server. Track it and bail out instead.
  bool droppedASplit = false;
  DateTime? newestLocal;
  DateTime? newestWatermark;
  DateTime? remoteUpdatedAt = groupMaps.first.fireflyUpdatedAt;
  for (FireflySyncMapEntry map in groupMaps) {
    Transaction? local = await database.tryGetTransactionFromPk(map.localPk);
    if (local == null) {
      droppedASplit = true;
      continue;
    }
    if (newestLocal == null ||
        (local.dateTimeModified != null &&
            local.dateTimeModified!.isAfter(newestLocal))) {
      newestLocal = local.dateTimeModified;
    }
    if (map.lastSyncedLocalModified != null &&
        (newestWatermark == null ||
            map.lastSyncedLocalModified!.isAfter(newestWatermark))) {
      newestWatermark = map.lastSyncedLocalModified;
    }
    FireflyTransactionSplit? split = await _splitForMappedLocalRow(
        map: map, counterparties: counterparties, local: local);
    if (split == null) {
      droppedASplit = true;
      continue;
    }
    splits.add(split);
  }
  if (splits.isEmpty) return;
  FireflySyncDirection direction = decideSyncDirection(
    localModified: newestLocal,
    remoteUpdatedAt: remoteUpdatedAt,
    lastSyncedLocalModified: newestWatermark,
    lastSyncedRemoteUpdatedAt: remoteUpdatedAt,
  );
  if (direction != FireflySyncDirection.push) return;

  if (droppedASplit) {
    report.warnings.add(
        "Skipped updating a split transaction on Firefly because part of it "
        "could not be rebuilt locally; sending it would have deleted the "
        "missing splits on the server.");
    return;
  }

  // Even with every mapping intact, the remote journal can hold splits this
  // install never imported (they were outside the sync window, or their
  // account is not linked). Compare against the live group before overwriting.
  FireflyTransactionGroup remoteGroup;
  try {
    remoteGroup = await client.getTransaction(groupMaps.first.fireflyId);
  } on FireflyNotFoundException {
    for (FireflySyncMapEntry map in groupMaps) {
      await _tombstoneMapRow(map);
    }
    return;
  }
  if (remoteGroup.splits.length != splits.length) {
    report.warnings.add(
        "Skipped updating a split transaction on Firefly: it has "
        "${remoteGroup.splits.length} splits remotely but only "
        "${splits.length} are stored locally, so the update would have "
        "deleted the rest.");
    return;
  }

  FireflyTransactionGroup updated = await client.updateTransaction(
    groupMaps.first.fireflyId,
    FireflyTransactionGroup(id: groupMaps.first.fireflyId, splits: splits),
  );
  for (FireflySyncMapEntry map in groupMaps) {
    Transaction? local = await database.tryGetTransactionFromPk(map.localPk);
    await _upsertSyncMap(
      syncMapPk: map.syncMapPk,
      type: FireflySyncEntityType.transaction,
      localPk: map.localPk,
      fireflyId: map.fireflyId,
      fireflyUpdatedAt: updated.updatedAt,
      lastSyncedLocalModified: local?.dateTimeModified,
      counterpartyFireflyId: map.counterpartyFireflyId,
      fireflySplitIndex: map.fireflySplitIndex,
    );
  }
  report.pushedTransactions++;
}

Future<void> _pushTransfer({
  required FireflyApiClient client,
  required Transaction transaction,
  required Set<String> handledThisPass,
  required FireflySyncReport report,
}) async {
  Transaction? paired =
      await database.tryGetTransactionFromPk(transaction.pairedTransactionFk!);
  if (paired == null) return;

  Transaction fromTransaction =
      transaction.amount < 0 ? transaction : paired;
  Transaction toTransaction = transaction.amount < 0 ? paired : transaction;

  FireflySyncMapEntry? fromWalletMap = await _syncMapByLocalPk(
      FireflySyncEntityType.wallet, fromTransaction.walletFk);
  FireflySyncMapEntry? toWalletMap = await _syncMapByLocalPk(
      FireflySyncEntityType.wallet, toTransaction.walletFk);
  handledThisPass.add(transaction.transactionPk);
  handledThisPass.add(paired.transactionPk);
  if (fromWalletMap == null || toWalletMap == null) {
    report.skippedUnmappedWallet++;
    return;
  }

  // Whichever leg the user touched last supplies the text for the single
  // remote split.
  bool toSideIsNewer = toTransaction.dateTimeModified != null &&
      (fromTransaction.dateTimeModified == null ||
          toTransaction.dateTimeModified!
              .isAfter(fromTransaction.dateTimeModified!));
  FireflyTransactionSplit split = transferPairToFireflySplit(
    fromTransaction: fromTransaction,
    toTransaction: toTransaction,
    fromWalletFireflyId: fromWalletMap.fireflyId,
    toWalletFireflyId: toWalletMap.fireflyId,
    descriptionOverride: toSideIsNewer ? toTransaction.name : null,
    notesOverride: toSideIsNewer ? toTransaction.note : null,
  );
  FireflyTransactionGroup group = FireflyTransactionGroup(
    id: 0,
    splits: [split],
  );

  FireflySyncMapEntry? fromMap = await _syncMapByLocalPk(
      FireflySyncEntityType.transaction, fromTransaction.transactionPk);
  FireflySyncMapEntry? toMap = await _syncMapByLocalPk(
      FireflySyncEntityType.transaction, toTransaction.transactionPk);

  if (fromMap == null && toMap == null) {
    FireflyTransactionGroup created = await client.createTransaction(group);
    await _upsertSyncMap(
      type: FireflySyncEntityType.transaction,
      localPk: fromTransaction.transactionPk,
      fireflyId: created.id,
      fireflyUpdatedAt: created.updatedAt,
      lastSyncedLocalModified: fromTransaction.dateTimeModified,
    );
    await _upsertSyncMap(
      type: FireflySyncEntityType.transaction,
      localPk: toTransaction.transactionPk,
      fireflyId: created.id,
      fireflyUpdatedAt: created.updatedAt,
      lastSyncedLocalModified: toTransaction.dateTimeModified,
    );
    report.pushedTransactions++;
  } else {
    FireflySyncMapEntry linkedMap = (fromMap ?? toMap)!;
    // Decide per leg, against that leg's own watermark, and push if either one
    // changed. Judging the transfer solely by the source row meant an edit to
    // the destination row was never pushed - and because the sync watermark
    // advances regardless, the next cycle would not see it either, so the edit
    // was silently lost from Firefly for good.
    FireflySyncDirection fromDirection = decideSyncDirection(
      localModified: fromTransaction.dateTimeModified,
      remoteUpdatedAt: linkedMap.fireflyUpdatedAt,
      lastSyncedLocalModified: fromMap?.lastSyncedLocalModified,
      lastSyncedRemoteUpdatedAt:
          fromMap?.fireflyUpdatedAt ?? linkedMap.fireflyUpdatedAt,
    );
    FireflySyncDirection toDirection = decideSyncDirection(
      localModified: toTransaction.dateTimeModified,
      remoteUpdatedAt: linkedMap.fireflyUpdatedAt,
      lastSyncedLocalModified: toMap?.lastSyncedLocalModified,
      lastSyncedRemoteUpdatedAt:
          toMap?.fireflyUpdatedAt ?? linkedMap.fireflyUpdatedAt,
    );
    FireflySyncDirection direction =
        (fromDirection == FireflySyncDirection.push ||
                toDirection == FireflySyncDirection.push)
            ? FireflySyncDirection.push
            : FireflySyncDirection.none;
    if (direction == FireflySyncDirection.push) {
      // Same hazard as in _pushTransactions: we rebuild the transfer as a
      // single-split group, and a PUT replaces whatever else the remote
      // journal holds.
      FireflyTransactionGroup remoteGroup;
      try {
        remoteGroup = await client.getTransaction(linkedMap.fireflyId);
      } on FireflyNotFoundException {
        if (fromMap != null) await _tombstoneMapRow(fromMap);
        if (toMap != null) await _tombstoneMapRow(toMap);
        return;
      }
      if (remoteGroup.splits.length > 1) {
        report.warnings.add(
            "Did not push a change to a transfer: its Firefly transaction has "
            "${remoteGroup.splits.length} splits but only one is stored "
            "locally, so updating it would have deleted the rest.");
        return;
      }
      FireflyTransactionGroup updated =
          await client.updateTransaction(linkedMap.fireflyId, group);
      await _upsertSyncMap(
        syncMapPk: fromMap?.syncMapPk,
        type: FireflySyncEntityType.transaction,
        localPk: fromTransaction.transactionPk,
        fireflyId: linkedMap.fireflyId,
        fireflyUpdatedAt: updated.updatedAt,
        lastSyncedLocalModified: fromTransaction.dateTimeModified,
      );
      await _upsertSyncMap(
        syncMapPk: toMap?.syncMapPk,
        type: FireflySyncEntityType.transaction,
        localPk: toTransaction.transactionPk,
        fireflyId: linkedMap.fireflyId,
        fireflyUpdatedAt: updated.updatedAt,
        lastSyncedLocalModified: toTransaction.dateTimeModified,
      );
      report.pushedTransactions++;
    }
  }
}

Future<void> _pushDeletes(
    FireflyApiClient client,
    DateTime lastSynced,
    _FireflyCounterpartyIndex counterparties,
    FireflySyncReport report) async {
  List<DeleteLog> deleteLogs = await database.getAllNewDeleteLogs(lastSynced);
  Set<int> remoteDeletedTransactionIds = {};
  for (DeleteLog log in deleteLogs) {
    FireflySyncEntityType? type;
    if (log.type == DeleteLogType.Transaction) {
      type = FireflySyncEntityType.transaction;
    } else if (log.type == DeleteLogType.TransactionWallet) {
      if (log.entryPk == "0") continue;
      type = FireflySyncEntityType.wallet;
    } else if (log.type == DeleteLogType.TransactionCategory) {
      if (log.entryPk == "0") continue;
      type = FireflySyncEntityType.category;
    } else {
      continue;
    }

    FireflySyncMapEntry? map = await _syncMapByLocalPk(type, log.entryPk,
        includeTombstones: true);
    if (map == null) continue;
    if (map.isTombstone) continue;

    try {
      if (type == FireflySyncEntityType.transaction) {
        if (remoteDeletedTransactionIds.contains(map.fireflyId)) {
          await _tombstoneMapRow(map);
          continue;
        }
        List<FireflySyncMapEntry> groupMaps = await _syncMapsByFireflyId(
            FireflySyncEntityType.transaction, map.fireflyId);
        // A Firefly journal can hold several splits, each one its own local
        // row. Deleting one of those rows must remove only that split -
        // deleting the whole journal would destroy the sibling splits on the
        // server while their local rows live on, which is silent data loss on
        // records the user never touched.
        List<FireflySyncMapEntry> surviving = [];
        bool pairedLegStillLocal = false;
        for (FireflySyncMapEntry sibling in groupMaps) {
          if (sibling.localPk == map.localPk) continue;
          bool siblingExists =
              await database.tryGetTransactionFromPk(sibling.localPk) != null;
          // A transfer is two local rows mapped to the SAME remote split. A
          // surviving sibling that shares this split index is that other leg,
          // not another split of the journal. Counting it as a survivor sent
          // every transfer delete down the split-removal path below, where the
          // completeness check could never pass (one remote split against two
          // known local rows), so deleting a transfer in Cashew never reached
          // Firefly and the warning repeated on every cycle.
          if (sibling.fireflySplitIndex == map.fireflySplitIndex) {
            if (siblingExists) pairedLegStillLocal = true;
            continue;
          }
          if (siblingExists) surviving.add(sibling);
        }
        if (surviving.isNotEmpty) {
          await _removeSplitFromRemoteGroup(
            client: client,
            deletedMap: map,
            survivingMaps: surviving,
            counterparties: counterparties,
            report: report,
          );
          continue;
        }
        await client.deleteTransaction(map.fireflyId);
        remoteDeletedTransactionIds.add(map.fireflyId);
        report.deletedRemote++;
        for (FireflySyncMapEntry sibling in groupMaps) {
          await _tombstoneMapRow(sibling);
        }
        if (pairedLegStillLocal) {
          // database.deleteTransaction does not follow pairedTransactionFk, so
          // Cashew can be left holding half a transfer. Firefly has no way to
          // represent that, and the whole journal is gone now; say so rather
          // than leaving a row that silently stops syncing.
          report.warnings.add(
              "A transfer was removed from Firefly because one of its two "
              "sides was deleted in Cashew. The other side is still stored "
              "locally and is no longer synced.");
        }
      } else if (type == FireflySyncEntityType.wallet) {
        await client.deleteAccount(map.fireflyId);
        report.deletedRemote++;
        await _tombstoneMapRow(map);
      } else if (type == FireflySyncEntityType.category) {
        await client.deleteCategory(map.fireflyId);
        report.deletedRemote++;
        await _tombstoneMapRow(map);
      }
    } on FireflyNotFoundException {
      if (type == FireflySyncEntityType.transaction) {
        for (FireflySyncMapEntry sibling in await _syncMapsByFireflyId(
            FireflySyncEntityType.transaction, map.fireflyId,
            includeTombstones: true)) {
          await _tombstoneMapRow(sibling);
        }
      } else {
        await _tombstoneMapRow(map);
      }
    } catch (e) {
      report.warnings.add("Could not delete ${type.name} on Firefly: $e");
      print("Firefly push-delete error (will retry): " + e.toString());
    }
  }
}

// Removes a single split from a remote journal whose other splits still exist
// locally, by rewriting the group without it.
//
// The rewrite is only attempted when every remote split is accounted for
// locally (the removed one plus the survivors). If the remote group holds
// splits this install never imported - outside the sync window, or on an
// unlinked account - the PUT would delete them too, so we leave the whole
// group alone and keep the map row untombstoned so the delete is retried on a
// later cycle rather than forgotten.
Future<void> _removeSplitFromRemoteGroup({
  required FireflyApiClient client,
  required FireflySyncMapEntry deletedMap,
  required List<FireflySyncMapEntry> survivingMaps,
  required _FireflyCounterpartyIndex counterparties,
  required FireflySyncReport report,
}) async {
  FireflyTransactionGroup remoteGroup;
  try {
    remoteGroup = await client.getTransaction(deletedMap.fireflyId);
  } on FireflyNotFoundException {
    // Already gone remotely - nothing to remove, just stop tracking the row.
    await _tombstoneMapRow(deletedMap);
    return;
  }
  if (remoteGroup.splits.length != survivingMaps.length + 1) {
    report.warnings.add(
        "Did not remove a deleted split from a Firefly transaction: the "
        "remote transaction has ${remoteGroup.splits.length} splits but "
        "${survivingMaps.length + 1} are known locally, so rewriting it "
        "would have deleted the rest.");
    return;
  }

  survivingMaps
      .sort((a, b) => a.fireflySplitIndex.compareTo(b.fireflySplitIndex));
  List<FireflyTransactionSplit> splits = [];
  for (FireflySyncMapEntry map in survivingMaps) {
    FireflyTransactionSplit? split = await _splitForMappedLocalRow(
        map: map, counterparties: counterparties);
    if (split == null) {
      report.warnings.add(
          "Did not remove a deleted split from a Firefly transaction because "
          "another of its splits could not be rebuilt locally.");
      return;
    }
    splits.add(split);
  }
  if (splits.isEmpty) return;

  FireflyTransactionGroup updated = await client.updateTransaction(
    deletedMap.fireflyId,
    FireflyTransactionGroup(id: deletedMap.fireflyId, splits: splits),
  );
  await _tombstoneMapRow(deletedMap);
  // The surviving splits shift down by one position in the rewritten journal,
  // so their stored indices have to move with them or the next pull would
  // match rows to the wrong splits.
  for (int i = 0; i < survivingMaps.length; i++) {
    Transaction? local =
        await database.tryGetTransactionFromPk(survivingMaps[i].localPk);
    await _upsertSyncMap(
      syncMapPk: survivingMaps[i].syncMapPk,
      type: FireflySyncEntityType.transaction,
      localPk: survivingMaps[i].localPk,
      fireflyId: deletedMap.fireflyId,
      fireflyUpdatedAt: updated.updatedAt,
      lastSyncedLocalModified: local?.dateTimeModified,
      counterpartyFireflyId: survivingMaps[i].counterpartyFireflyId,
      fireflySplitIndex: i,
    );
  }
  report.deletedRemote++;
}

// ---------------------------------------------------------------------------
// Balance anchors
// ---------------------------------------------------------------------------
//
// Only a recent window of Firefly's history is stored locally, so summing the
// local rows of a wallet under-reports its balance by everything that was
// never pulled. Each synced wallet therefore carries one synthetic row holding
// exactly that difference:
//
//     anchor = firefly_current_balance - sum(the wallet's other local rows)
//
// so that local sum + anchor == the balance Firefly reports. Because the
// anchor lives in the reserved balance-correction category "0", Cashew's
// existing onlyShowIfNotBalanceCorrection() filter already includes it in net
// totals and net worth while keeping it out of income/expense breakdowns and
// spending graphs - no existing query had to change.
//
// The anchor self-corrects: as older transactions get cached on demand the
// local sum grows and the anchor shrinks by the same amount, so the reported
// balance stays put.

// Anything below this is treated as no change, to avoid rewriting the anchor
// (and so waking the auto-sync watcher) over floating-point noise.
const double _kAnchorEpsilon = 0.005;

Future<void> _refreshBalanceAnchors(
    FireflyApiClient client, FireflySyncReport report) async {
  List<FireflyAccount> accounts =
      await client.getAccounts(type: kFireflyAssetAccountType);
  Map<int, FireflyAccount> byId = {for (var a in accounts) a.id: a};

  for (FireflySyncMapEntry map
      in await _syncMapEntriesForType(FireflySyncEntityType.wallet)) {
    FireflyAccount? remote = byId[map.fireflyId];
    if (remote == null) continue;
    await _refreshBalanceAnchorForWallet(
      walletPk: map.localPk,
      remoteBalance: remote.currentBalance,
      report: report,
    );
  }
}

Future<void> _refreshBalanceAnchorForWallet({
  required String walletPk,
  required double? remoteBalance,
  required FireflySyncReport report,
}) async {
  String anchorPk = fireflyBalanceAnchorPk(walletPk);
  Transaction? existing = await database.tryGetTransactionFromPk(anchorPk);

  if (remoteBalance == null) {
    // Without an authoritative balance we cannot compute an anchor. Leave any
    // existing one untouched rather than replacing it with a guess - a stale
    // anchor is much closer to the truth than none at all.
    if (existing == null) {
      report.warnings.add(
          "Firefly did not report a balance for one account; its total may be "
          "short by the history that is not stored locally.");
    }
    return;
  }

  double localSum = await database.getSumOfWalletExcludingTransaction(
      walletPk, anchorPk);
  double anchorAmount = remoteBalance - localSum;

  // Nothing to carry, and nothing already stored - do not create a row.
  if (existing == null && anchorAmount.abs() < _kAnchorEpsilon) return;
  // Unchanged. Skipping the write matters: rewriting it would bump
  // dateTimeModified, which trips the auto-sync watcher and schedules another
  // sync, every single cycle.
  if (existing != null &&
      (existing.amount - anchorAmount).abs() < _kAnchorEpsilon) {
    return;
  }

  DateTime? earliest = await database.getEarliestTransactionDateOfWallet(
      walletPk, anchorPk);
  DateTime anchorDate =
      (earliest ?? fireflySyncWindowStart()).subtract(const Duration(days: 1));

  await database.createOrUpdateTransaction(
    buildFireflyBalanceAnchor(
      walletPk: walletPk,
      amount: anchorAmount,
      date: anchorDate,
      name: "firefly-balance-anchor".tr(),
    ),
    insert: false,
    updateSharedEntry: false,
    fireflySync: true,
  );
}

// ---------------------------------------------------------------------------
// On-demand fetches
// ---------------------------------------------------------------------------
//
// Everything below reaches past the rolling sync window, on an explicit user
// action - searching, filtering by date, opening an account, or pulling to
// refresh a balance. Records fetched here are cached into the local database
// and are ordinary local rows from then on.
//
// None of these run delete reconciliation and none of them advance
// fireflyLastSyncedAt. They fetch a deliberately partial view of the remote
// data, and _applyRemoteDeletes must only ever be handed a complete one.

final ValueNotifier<bool> fireflyOnDemandBusyNotifier = ValueNotifier(false);

Future<T?> _withFireflyClient<T>(
    Future<T> Function(FireflyApiClient client) body) async {
  if (!fireflyEnabled) return null;
  String hostUrl = fireflyHostUrl;
  String? pat = await getFireflyPat();
  if (hostUrl.isEmpty || pat == null || pat.isEmpty) return null;

  FireflyApiClient client =
      FireflyApiClient(baseUrl: hostUrl, personalAccessToken: pat);
  fireflyOnDemandBusyNotifier.value = true;
  try {
    // Queued behind (and ahead of) the routine sync. These fetches run the
    // same _pullTransactions code against overlapping data, so letting one
    // interleave with a sync means both can look up the same Firefly group,
    // both find no mapping, and both insert their own local copy of it.
    return await _withFireflyEngineLock(
        () => _withFireflyWrites(() => body(client)));
  } catch (e) {
    print("Firefly on-demand fetch error: " + e.toString());
    fireflySyncErrorNotifier.value = e.toString();
    return null;
  } finally {
    fireflyOnDemandBusyNotifier.value = false;
    client.close();
  }
}

// Caches a booking-date range that falls outside the rolling window, e.g.
// when the user scrolls or filters back past it.
Future<FireflySyncReport?> fireflyFetchTransactionRange({
  required DateTime start,
  DateTime? end,
}) async {
  return await _withFireflyClient((client) async {
    FireflySyncReport report = FireflySyncReport();
    await _ensureFireflySystemCategories();
    List<FireflyTransactionGroup> groups =
        await client.getTransactions(start: start, end: end);
    await _pullTransactions(client, report, preFetchedGroups: groups);
    await _refreshBalanceAnchors(client, report);
    fireflySyncReportNotifier.value = report;
    return report;
  });
}

// Caches everything Firefly holds for one wallet, optionally date-bounded.
// Backs "show me this account's full history".
Future<FireflySyncReport?> fireflyFetchTransactionsForWallet(
  String walletPk, {
  DateTime? start,
  DateTime? end,
}) async {
  return await _withFireflyClient((client) async {
    FireflySyncReport report = FireflySyncReport();
    FireflySyncMapEntry? map =
        await _syncMapByLocalPk(FireflySyncEntityType.wallet, walletPk);
    if (map == null) {
      report.warnings.add("That account is not linked to Firefly yet.");
      return report;
    }
    await _ensureFireflySystemCategories();
    List<FireflyTransactionGroup> groups = await client
        .getTransactionsForAccount(map.fireflyId, start: start, end: end);
    await _pullTransactions(client, report, preFetchedGroups: groups);
    await _refreshBalanceAnchorForWallet(
      walletPk: walletPk,
      remoteBalance: (await client.getAccount(map.fireflyId)).currentBalance,
      report: report,
    );
    fireflySyncReportNotifier.value = report;
    return report;
  });
}

// Runs a Firefly-side full-text search and caches whatever comes back, so
// results from outside the window become available locally.
Future<FireflySyncReport?> fireflySearchAndCacheTransactions(
    String query) async {
  if (query.trim().isEmpty) return null;
  return await _withFireflyClient((client) async {
    FireflySyncReport report = FireflySyncReport();
    await _ensureFireflySystemCategories();
    List<FireflyTransactionGroup> groups =
        await client.searchTransactions(query.trim());
    await _pullTransactions(client, report, preFetchedGroups: groups);
    await _refreshBalanceAnchors(client, report);
    fireflySyncReportNotifier.value = report;
    return report;
  });
}

// Re-reads balances straight from Firefly and re-anchors every linked wallet.
// Cheap compared with a sync (one account list, no transactions), so it is
// suitable for a pull-to-refresh on a balance or net-worth view.
Future<bool> fireflyRefreshBalances() async {
  FireflySyncReport? report = await _withFireflyClient((client) async {
    FireflySyncReport report = FireflySyncReport();
    await _ensureFireflySystemCategories();
    await _refreshBalanceAnchors(client, report);
    return report;
  });
  return report != null;
}

// Widens the window permanently and resyncs, for "my older transactions are
// missing". Expensive on a populated instance, so only ever user-initiated.
Future<bool> fireflySyncAllHistory() async {
  return await fireflySyncNow(fullResync: true);
}

// ---------------------------------------------------------------------------
// UI entry points
// ---------------------------------------------------------------------------
//
// Thin wrappers the app's views call directly. Each one is a no-op when
// Firefly is off, only reaches the network when the view is actually asking
// for something the local window cannot answer, and remembers what it already
// fetched so that toggling a filter back and forth does not re-download the
// same data. Every one of them is fire-and-forget from the caller's point of
// view: results land in the local database and the existing Drift streams
// push them into the open view on their own.

String _fireflyDayKey(DateTime date) =>
    date.toIso8601String().substring(0, 10);

final Set<String> _fireflyFetchedRangeKeys = {};
final Set<String> _fireflyFetchedSearchQueries = {};
final Set<String> _fireflyFetchedWalletPks = {};

// Clears the "already fetched" memory. Called when the link is reconfigured,
// since a different server (or a widened window) invalidates all of it.
void fireflyClearOnDemandCacheMemory() {
  _fireflyFetchedRangeKeys.clear();
  _fireflyFetchedSearchQueries.clear();
  _fireflyFetchedWalletPks.clear();
}

// The user filtered or scrolled to a date range. Only ranges that reach back
// past the rolling window need anything from the server.
Future<void> fireflyEnsureRangeCached(DateTime? start, DateTime? end) async {
  if (!fireflyEnabled) return;
  if (start == null) return;
  if (!start.isBefore(fireflySyncWindowStart())) return;
  String key =
      _fireflyDayKey(start) + ".." + (end == null ? "" : _fireflyDayKey(end));
  if (!_fireflyFetchedRangeKeys.add(key)) return;
  FireflySyncReport? report =
      await fireflyFetchTransactionRange(start: start, end: end);
  // Failed fetches must not be remembered as done, or the range would stay
  // permanently missing until the app restarts.
  if (report == null) _fireflyFetchedRangeKeys.remove(key);
}

// The user typed a search. Firefly searches its whole history, so this is the
// path by which results older than the window become visible at all.
Future<void> fireflyEnsureSearchCached(String? query) async {
  if (!fireflyEnabled) return;
  String trimmed = (query ?? "").trim();
  // Below three characters the query matches too much to be worth a round
  // trip, and the local rows already answer it.
  if (trimmed.length < 3) return;
  String key = trimmed.toLowerCase();
  if (!_fireflyFetchedSearchQueries.add(key)) return;
  FireflySyncReport? report = await fireflySearchAndCacheTransactions(trimmed);
  if (report == null) _fireflyFetchedSearchQueries.remove(key);
}

// The user opened one account. Pulls that account's full history once per app
// run, so its transaction list and running balance are complete.
Future<void> fireflyEnsureWalletHistoryCached(String walletPk) async {
  if (!fireflyEnabled) return;
  if (!_fireflyFetchedWalletPks.add(walletPk)) return;
  FireflySyncReport? report = await fireflyFetchTransactionsForWallet(walletPk);
  if (report == null) _fireflyFetchedWalletPks.remove(walletPk);
}

// Uploads local transactions that predate linking to Firefly. Explicitly
// user-initiated: on a populated instance this creates a remote copy of every
// local record, and there is no safe way to tell which of them Firefly
// already has.
Future<bool> fireflyUploadExistingLocalHistory() async {
  return await fireflySyncNow(pushExistingLocalHistory: true);
}
