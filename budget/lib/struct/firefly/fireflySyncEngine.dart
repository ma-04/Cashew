// Two-way sync between the local database and a self-hosted Firefly III
// server. Firefly sync and Google Drive sync are mutually exclusive on one
// installation; the settings page keeps that rule.
//
// Each cycle pulls the categories, the accounts, the counterparties and the
// transactions, applies the remote deletes, refreshes the balance anchors,
// then pushes the categories, the accounts, the transactions and the local
// deletes. The pull is first, thus a remote change is visible before a push
// can write over it.
//
// WINDOW
//
// Firefly is the system of record and can hold many years of data. A routine
// sync reads only a recent range of booking dates (fireflySyncWindowDays,
// default 30 days). The local database gets an older record only when the
// user asks for it: a search, a filter or an open account calls the on-demand
// functions at the end of this file, which read that range and keep it.
//
// The rest of this file must obey two rules:
//
//  1. The local database is an incomplete copy of the remote one. Do not read
//     "not in the local database" as "deleted on the server", or "not on the
//     server" as "deleted in this application", outside of the range that the
//     sync read. See _applyRemoteDeletes.
//  2. The sum of the local rows of a wallet is not its balance. Each synced
//     wallet has a balance anchor row (see fireflyMapper.dart) that holds the
//     total of the data before the window. The value comes from the
//     current_balance field of Firefly. Wallet totals and net worth stay
//     correct because of the anchor. See _refreshBalanceAnchors.
//
// The start and end filters of Firefly apply to the booking date, not to
// updated_at. Thus a change that the user makes today to an old transaction
// is not visible until an on-demand fetch reads that record. The "Sync all
// history" action makes the window larger.

import 'package:drift/drift.dart'
    show
        Value,
        InsertMode,
        BooleanExpressionOperators,
        StringExpressionOperators;
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
  int skippedAmbiguousSplits = 0;
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
      parts.add(
          "$skippedUnmappedWallet transactions skipped (wallet not linked)");
    }
    if (skippedAmbiguousSplits > 0) {
      parts.add("$skippedAmbiguousSplits splits skipped (record not known)");
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
// A depth counter, not a flag. An on-demand fetch can start and stop while a
// sync is in operation. A flag that the fetch clears would make the remaining
// writes of that sync look like user edits, which starts one more push each
// cycle.
int _applyingFireflyWriteDepth = 0;
bool get _applyingFireflyWrites => _applyingFireflyWriteDepth > 0;
bool _userEditDuringSync = false;
final Debouncer fireflyPushDebouncer = Debouncer(milliseconds: 5000);

// Makes each piece of engine work that reads Firefly and writes to the local
// database run in sequence: the routine sync and each on-demand fetch at the
// end of this file.
//
// _canSyncFirefly stops only a second sync. It does not stop an on-demand
// fetch. Without this queue a fetch and a sync can be in _pullTransactions for
// the same Firefly group together, read the sync map before either one writes
// to it, and each insert its own local copy of that remote transaction.
Future<void> _fireflyEngineQueue = Future<void>.value();

Future<T> _withFireflyEngineLock<T>(Future<T> Function() body) {
  Future<T> result = _fireflyEngineQueue.then((_) => body());
  // The queue must continue after a failure, or one exception stops the
  // engine for the remaining life of the application. The caller that awaits
  // result still gets the error.
  _fireflyEngineQueue = result.then<void>((_) {}, onError: (Object _) {});
  return result;
}

void scheduleFireflyPush() {
  if (!fireflyEnabled) return;
  if (_applyingFireflyWrites) {
    // This is true for the writes of the engine, but a user edit in the same
    // period looks the same here. To return and record nothing loses that
    // edit, because the watermark moves in each case. Record it, thus one more
    // cycle runs when this one stops. A wrong guess costs one empty sync.
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
  // Push the local changes, but do not pull. A cycle that ran while the user
  // made a change uses this for the second cycle: the change is already behind
  // the watermark of the first cycle, and a pull is not necessary because each
  // push reads the live remote record before it writes.
  bool pushOnly = false,
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

    _FireflyPushBacklog backlog = _FireflyPushBacklog();

    await _withFireflyEngineLock(() => _withFireflyWrites(() async {
          // A local copy that cannot be null. The closure captures the outer
          // variable, thus Dart does not keep the result of the null test.
          FireflyApiClient api = client!;
          _FireflyCounterpartyIndex counterparties;
          if (pushOnly) {
            counterparties = await _loadCounterparties(api);
          } else {
            Set<int> remoteCategoryIds = await _pullCategories(api, report);
            Set<int> remoteWalletIds = await _pullAccounts(api, report);
            counterparties = await _loadCounterparties(api);
            Set<int> remoteTransactionIds =
                await _pullTransactions(api, report, windowStart: windowStart);
            await _applyRemoteDeletes(
              client: api,
              remoteCategoryIds: remoteCategoryIds,
              remoteWalletIds: remoteWalletIds,
              remoteTransactionIds: remoteTransactionIds,
              windowStart: windowStart,
              report: report,
            );
          }
          await _pushCategories(api, lastSynced, report, backlog,
              includeUnmodifiedRows: pushExistingLocalHistory);
          await _pushAccounts(api, lastSynced, report, backlog,
              includeUnmodifiedRows: pushExistingLocalHistory);
          await _pushTransactions(
              api, lastSynced, counterparties, report, backlog,
              includeUnmodifiedRows: pushExistingLocalHistory);
          await _pushDeletes(api, lastSynced, report, backlog);
          // Last, because the push changes the remote balances that this
          // reads. A balance from before the push would make each wallet that
          // the cycle pushed to wrong by the amount that it pushed.
          if (!pushOnly ||
              report.pushedTransactions > 0 ||
              report.pushedWallets > 0 ||
              report.deletedRemote > 0) {
            await _refreshBalanceAnchors(api, report);
          }
        }));

    await setFireflyLastSyncedAt(backlog.nextWatermark(syncStartedAt));
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
      fireflyPushDebouncer.run(() {
        fireflySyncNow(pushOnly: true);
      });
    }
  }
}

// Holds the modification time of the oldest local row that a cycle did not
// push. The cycle then moves the push watermark back to that time, thus the
// next cycle finds the row again. Without this the watermark moves past each
// row that a warning or a conflict stopped, and the app never pushes it.
class _FireflyPushBacklog {
  DateTime? oldestNotPushed;

  void recordNotPushed(DateTime? localModified) {
    if (localModified == null) return;
    if (oldestNotPushed == null || localModified.isBefore(oldestNotPushed!)) {
      oldestNotPushed = localModified;
    }
  }

  // getAllNew*() selects each row with a time equal to or later than the
  // watermark, thus the time of the row itself is the correct watermark.
  DateTime nextWatermark(DateTime syncStartedAt) {
    DateTime? oldest = oldestNotPushed;
    if (oldest == null || oldest.isAfter(syncStartedAt)) return syncStartedAt;
    return oldest;
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

Future<List<FireflySyncMapEntry>> _syncMapEntriesForType(
    FireflySyncEntityType type,
    {bool includeTombstones = false}) {
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
  int? fireflyJournalId,
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
          fireflyJournalId: Value(fireflyJournalId),
        ),
        mode: InsertMode.insertOrReplace,
      );
}

// Removes the link between a local row and a Firefly record, but keeps the
// local row. A tombstone is not correct here: a tombstone stops each later
// push of that row, and the user can mark the row paid again, which must
// create the Firefly record again.
Future<void> _deleteSyncMapRow(FireflySyncMapEntry map) async {
  await (database.delete(database.fireflySyncMap)
        ..where((tbl) => tbl.syncMapPk.equals(map.syncMapPk)))
      .go();
}

// Removes every link to the Firefly server, and the balance anchors that the
// server balances gave. An id in the map is correct for one server only. If
// the user gives a different host, the same id on that host points to a
// different record, and a push then writes to the wrong record. The local
// rows stay: the next sync links them again.
Future<void> fireflyForgetSyncState() async {
  await database.delete(database.fireflySyncMap).go();
  await (database.delete(database.transactions)
        ..where(
            (tbl) => tbl.transactionPk.like("$kFireflyBalanceAnchorPkPrefix%")))
      .go();
  fireflyClearOnDemandCacheMemory();
  await clearFireflyLastSyncedAt();
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
    fireflyJournalId: map.fireflyJournalId,
  );
}

Future<Set<int>> _pullCategories(
    FireflyApiClient client, FireflySyncReport report) async {
  List<FireflyCategory> remoteCategories = await client.getCategories();
  Set<int> remoteIds = {for (var remote in remoteCategories) remote.id};
  List<TransactionCategory> localMainCategories =
      (await database.getAllCategories()).toList();
  int nextOrder = localMainCategories.isEmpty
      ? 0
      : localMainCategories
              .map((c) => c.order)
              .reduce((a, b) => a > b ? a : b) +
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
        TransactionCategory newCategory =
            fireflyCategoryToCategory(remote, order: nextOrder);
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
      // Write onto the row that is on disk. createOrUpdateCategory saves
      // with insertOrReplace, thus a new object blanks each column that
      // Firefly does not know: the color, the icon, the emoji, the income
      // flag and the link to the parent category.
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
        lastSyncedLocalModified:
            saved?.dateTimeModified ?? updated.dateTimeModified,
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
      // The same reason as in _mergeFireflyCategory: createOrUpdateWallet
      // saves with insertOrReplace. A wallet that is built from the Firefly
      // account alone loses its color, icon, currency format, decimal count
      // and home screen position at each remote rename.
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
        lastSyncedLocalModified:
            saved?.dateTimeModified ?? updated.dateTimeModified,
      );
      report.pulledWallets++;
    }
  }
  return remoteIds;
}

// Creates the two local categories that the Firefly integration needs. The
// function does nothing if they are there.
Future<void> _ensureFireflySystemCategories() async {
  await initializeBalanceCorrectionCategory();
  if (await database
          .getCategoryInstanceOrNull(kFireflyUncategorizedCategoryPk) !=
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
  // The first booking date to read. null reads the full history.
  DateTime? windowStart,
  // Groups that the caller read before, to apply in place of a new list. The
  // on-demand fetches give them, thus they use this same apply code.
  List<FireflyTransactionGroup>? preFetchedGroups,
}) async {
  List<FireflyTransactionGroup> groups =
      preFetchedGroups ?? await client.getTransactions(start: windowStart);
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
    bool groupIsReported = false;

    for (int splitIndex = 0; splitIndex < group.splits.length; splitIndex++) {
      FireflyTransactionSplit split = group.splits[splitIndex];
      int? journalId = split.transactionJournalId;

      // The rows are read for each split: this loop writes rows, thus a list
      // that it reads one time for the group goes stale inside the loop.
      List<FireflySyncMapEntry> liveMaps = [];
      Set<int> liveJournalIds = {};
      Set<int> tombstonedJournalIds = {};
      Set<int> tombstonedPositions = {};
      for (FireflySyncMapEntry map in await _syncMapsByFireflyId(
          FireflySyncEntityType.transaction, group.id,
          includeTombstones: true)) {
        if (map.isTombstone) {
          if (map.fireflyJournalId != null) {
            tombstonedJournalIds.add(map.fireflyJournalId!);
          } else {
            tombstonedPositions.add(map.fireflySplitIndex);
          }
          continue;
        }
        liveMaps.add(map);
        if (map.fireflyJournalId != null) {
          liveJournalIds.add(map.fireflyJournalId!);
        }
      }
      bool positionMatchIsSafe =
          fireflyPositionMatchIsSafe(groupMaps: liveMaps, splits: group.splits);

      // A tombstone is for one split, not for the full group. To skip the
      // group when one split has a tombstone stopped each other split of it:
      // they kept their links but got no more remote changes.
      //
      // A tombstone that the app wrote before the journal-id column was there
      // holds a position only, and Firefly moves the positions when it deletes
      // a split. Such a tombstone thus counts only while no live row claims
      // this split and while the positions are safe.
      bool splitIsTombstoned;
      if (journalId != null && tombstonedJournalIds.contains(journalId)) {
        splitIsTombstoned = true;
      } else if (journalId != null) {
        // The split has an id, and no tombstone names that id. A tombstone
        // that holds a position only is thus for a split that the app removed
        // before, and Firefly moved a later split into that position. To let
        // the position count here hides this split for ever: the app makes no
        // record for it, and it gives no message.
        splitIsTombstoned = false;
      } else {
        splitIsTombstoned =
            positionMatchIsSafe && tombstonedPositions.contains(splitIndex);
      }
      if (splitIsTombstoned) continue;

      List<FireflySyncMapEntry> splitMaps = matchSplitToSyncMaps(
        groupMaps: liveMaps,
        splitJournalId: journalId,
        splitIndex: splitIndex,
        matchByPosition: positionMatchIsSafe,
      );

      // Give the id to each matched row here, before a test below can end
      // this split. A row that keeps a null id stays matched by position, and
      // the next split that Firefly deletes then moves it onto a neighbour.
      if (journalId != null) {
        for (int i = 0; i < splitMaps.length; i++) {
          if (splitMaps[i].fireflyJournalId != null) continue;
          splitMaps[i] = await _writeSplitJournalId(splitMaps[i], journalId);
        }
      }

      FireflyPulledSplitKind kind = classifySplitType(split.type);
      if (kind == FireflyPulledSplitKind.skip) {
        report.skippedUnsupported++;
        continue;
      }

      // The opening balance and the reconciliation journals are bookkeeping
      // entries of Firefly. They come from the setup of the account, not from
      // an action of the user. To import them as usual transactions is unsafe:
      // the first local change sends such a row back as a usual withdrawal or
      // deposit and makes the opening balance of the remote account wrong.
      // Their amounts are already in the current_balance value that gives the
      // balance anchor, thus this skip loses nothing.
      if (splitKindIsBalanceCorrection(kind)) {
        report.skippedUnsupported++;
        continue;
      }

      // The group holds a row that no id identifies, and the positions are
      // not safe. To match by position can put the remote change on the wrong
      // local row, and to make a new row makes a second copy of a row that is
      // already here. The app does neither, and it names the group.
      if (splitMaps.isEmpty &&
          !positionMatchIsSafe &&
          liveMaps.any((map) => map.fireflyJournalId == null)) {
        if (!groupIsReported) {
          groupIsReported = true;
          report.warnings.add(
              "A Firefly transaction with several splits changed, and this "
              "app cannot say which of its records is which split. The "
              "records stay as they are. To repair them, use \"Reset Firefly "
              "links\" in the Firefly settings.");
        }
        report.skippedAmbiguousSplits++;
        continue;
      }

      if (kind == FireflyPulledSplitKind.transfer) {
        await _pullTransferSplit(
          group: group,
          split: split,
          splitIndex: splitIndex,
          splitMaps: splitMaps,
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

      FireflySyncMapEntry? existingMap =
          splitMaps.isEmpty ? null : splitMaps.first;

      if (existingMap == null) {
        Transaction newTransaction = fireflySplitToTransaction(
          split,
          walletPk: walletPk,
          categoryPk: categoryPk,
          isIncome: isIncome,
        );
        // The new row and its map row must commit together. If the row
        // commits and the map row does not, the next pull finds no link and
        // inserts a second copy, and the push finds a local row with no link
        // and creates a second remote record.
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
            fireflyJournalId: split.transactionJournalId,
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
            fireflyJournalId:
                split.transactionJournalId ?? existingMap.fireflyJournalId,
          );
          report.pulledTransactions++;
        }
      }
    }

    await _unlinkRowsOfRemovedSplits(group, report);
  }
  return remoteIds;
}

// Removes the local row of a split that Firefly no longer holds.
//
// _applyRemoteDeletes asks whether a GROUP is on the server. It thus cannot
// see a split that Firefly removed from a group that stays. Such a split
// leaves a local row that keeps its link for ever, and a remote change that
// puts a new split in its place makes a second local row next to it.
//
// The group here comes from the server, thus it holds each split that is
// there. A row that names a journal id that the group does not hold is for a
// split that is gone.
Future<void> _unlinkRowsOfRemovedSplits(
    FireflyTransactionGroup group, FireflySyncReport report) async {
  Set<int> liveJournalIds = {
    for (FireflyTransactionSplit split in group.splits)
      if (split.transactionJournalId != null) split.transactionJournalId!
  };
  // One split with no id makes the set too small, and each row would then look
  // removed. Do nothing until the server names each split.
  if (liveJournalIds.length != group.splits.length) return;

  for (FireflySyncMapEntry map in await _syncMapsByFireflyId(
      FireflySyncEntityType.transaction, group.id)) {
    // A row with no journal id gives no proof: its position can point at
    // another split. The quarantine in the pull loop names such a group.
    if (map.fireflyJournalId == null) continue;
    if (liveJournalIds.contains(map.fireflyJournalId)) continue;
    await _deleteLocalTransactionFromRemote(map, report);
  }
}

// Writes the journal id on a map row and gives the row with that id. The
// upsert replaces the row, thus each other field must go with the write.
Future<FireflySyncMapEntry> _writeSplitJournalId(
    FireflySyncMapEntry map, int journalId) async {
  await _upsertSyncMap(
    syncMapPk: map.syncMapPk,
    type: FireflySyncEntityType.transaction,
    localPk: map.localPk,
    fireflyId: map.fireflyId,
    fireflyUpdatedAt: map.fireflyUpdatedAt,
    lastSyncedLocalModified: map.lastSyncedLocalModified,
    counterpartyFireflyId: map.counterpartyFireflyId,
    fireflySplitIndex: map.fireflySplitIndex,
    fireflyJournalId: journalId,
  );
  return map.copyWith(fireflyJournalId: Value(journalId));
}

Future<void> _pullTransferSplit({
  required FireflyTransactionGroup group,
  required FireflyTransactionSplit split,
  required int splitIndex,
  // The rows that hold this split. The caller matched them and gave them the
  // journal id of the split.
  required List<FireflySyncMapEntry> splitMaps,
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

  if (splitMaps.isEmpty) {
    (Transaction, Transaction) pair = fireflySplitToTransferPair(
      split,
      sourceWalletPk: sourcePk,
      destWalletPk: destPk,
    );
    // The two legs and the two map rows commit together. A part commit
    // leaves one half of a transfer, or a pair with no link that the next
    // cycle imports again and also sends back as a new remote transfer.
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
        fireflyJournalId: split.transactionJournalId,
      );
      await _upsertSyncMap(
        type: FireflySyncEntityType.transaction,
        localPk: pair.$2.transactionPk,
        fireflyId: group.id,
        fireflyUpdatedAt: group.updatedAt,
        lastSyncedLocalModified: savedTo?.dateTimeModified,
        fireflySplitIndex: splitIndex,
        fireflyJournalId: split.transactionJournalId,
      );
    });
    report.pulledTransactions += 2;
    return;
  }

  Transaction? first =
      await database.tryGetTransactionFromPk(splitMaps.first.localPk);
  if (first == null) return;
  DateTime? newestLocal = first.dateTimeModified;
  DateTime? newestWatermark = splitMaps.first.lastSyncedLocalModified;
  for (FireflySyncMapEntry map in splitMaps) {
    Transaction? local = await database.tryGetTransactionFromPk(map.localPk);
    // Kept in a local variable: Dart does not make `local` non-null from a
    // test of `local?.field`, thus the field needs one read and one test.
    DateTime? localModified = local?.dateTimeModified;
    if (localModified != null &&
        (newestLocal == null || localModified.isAfter(newestLocal))) {
      newestLocal = localModified;
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
    lastSyncedRemoteUpdatedAt: splitMaps.first.fireflyUpdatedAt,
  );
  if (direction != FireflySyncDirection.pull) return;

  String? existingSourcePk;
  String? existingDestPk;
  for (FireflySyncMapEntry map in splitMaps) {
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
  // Write onto the rows that are on disk. createOrUpdateTransaction saves
  // with insertOrReplace, thus each column that the companion does not hold
  // gets its default value, and each local-only field of the transfer is lost
  // at every remote change.
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
  FireflySyncMapEntry? fromMap = splitMaps
      .cast<FireflySyncMapEntry?>()
      .firstWhere((m) => m?.localPk == pair.$1.transactionPk,
          orElse: () => null);
  FireflySyncMapEntry? toMap = splitMaps
      .cast<FireflySyncMapEntry?>()
      .firstWhere((m) => m?.localPk == pair.$2.transactionPk,
          orElse: () => null);
  await _upsertSyncMap(
    syncMapPk: fromMap?.syncMapPk,
    type: FireflySyncEntityType.transaction,
    localPk: pair.$1.transactionPk,
    fireflyId: group.id,
    fireflyUpdatedAt: group.updatedAt,
    lastSyncedLocalModified: savedFrom?.dateTimeModified,
    fireflySplitIndex: splitIndex,
    fireflyJournalId: split.transactionJournalId ?? fromMap?.fireflyJournalId,
  );
  await _upsertSyncMap(
    syncMapPk: toMap?.syncMapPk,
    type: FireflySyncEntityType.transaction,
    localPk: pair.$2.transactionPk,
    fireflyId: group.id,
    fireflyUpdatedAt: group.updatedAt,
    lastSyncedLocalModified: savedTo?.dateTimeModified,
    fireflySplitIndex: splitIndex,
    fireflyJournalId: split.transactionJournalId ?? toMap?.fireflyJournalId,
  );
  report.pulledTransactions += 2;
}

// Firefly knows only the name of a category. Thus a pull writes only the name
// onto a local category that is there.
TransactionCategory _mergeFireflyCategory(
    TransactionCategory existing, TransactionCategory rebuilt) {
  return existing.copyWith(
    name: rebuilt.name,
    dateTimeModified: Value(rebuilt.dateTimeModified),
  );
}

// The same for accounts: the name and the currency are from Firefly. The
// other fields of the wallet belong to this application.
TransactionWallet _mergeFireflyWallet(
    TransactionWallet existing, TransactionWallet rebuilt) {
  return existing.copyWith(
    name: rebuilt.name,
    currency: Value(rebuilt.currency),
    dateTimeModified: Value(rebuilt.dateTimeModified),
  );
}

// Writes the Firefly fields of a rebuilt transfer leg onto the stored row and
// keeps each field that this application owns.
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

// Removes the local rows of records that are no longer on the Firefly server.
//
// This is the most destructive operation of the engine. It is correct only if
// the caller gives a COMPLETE set of remote ids for the scope. Two rules keep
// that true:
//
//  * The API client does not return a part of a paged list. It throws, thus a
//    short read stops the sync and does not look like "each other record is
//    deleted".
//  * The code compares transactions only in the range of booking dates that
//    the sync read. It did not ask for an older record, thus the absence of
//    that record from remoteTransactionIds gives no information. To compare it
//    deletes the full history of the user before the window.
//
// Accounts and categories have no window. Each cycle reads the complete
// lists, thus the code compares all of them.
Future<void> _applyRemoteDeletes({
  required FireflyApiClient client,
  required Set<int> remoteCategoryIds,
  required Set<int> remoteWalletIds,
  required Set<int> remoteTransactionIds,
  // The first booking date of the window that gave remoteTransactionIds. null
  // means that the sync read the full history and each record is in scope.
  required DateTime? windowStart,
  required FireflySyncReport report,
}) async {
  // The Firefly groups that this pass asked about: true = on the server,
  // false = gone. A group can hold more than one mapped split, thus the code
  // asks about each group one time only.
  Map<int, bool> stillOnFirefly = {};

  for (FireflySyncMapEntry map
      in await _syncMapEntriesForType(FireflySyncEntityType.transaction)) {
    if (remoteTransactionIds.contains(map.fireflyId)) continue;

    if (windowStart != null) {
      Transaction? local = await database.tryGetTransactionFromPk(map.localPk);
      // No local row. Nothing to delete, thus close the link only.
      if (local == null) {
        await _tombstoneMapRow(map);
        continue;
      }
      // The date is before the window, thus the sync did not ask Firefly
      // about this record. Keep it.
      if (local.dateCreated.isBefore(windowStart)) continue;

      // The local row is in the window, but the record did not come back.
      // This is not proof of a delete: a new date before windowStart moves the
      // remote record out of the window and keeps it complete, while the local
      // copy keeps the old date. An error here is permanent, because the code
      // deletes the row and writes a tombstone, and a tombstone stops even
      // "Sync all history". Thus ask the server about this one record first.
      bool? known = stillOnFirefly[map.fireflyId];
      if (known == null) {
        try {
          FireflyTransactionGroup remote =
              await client.getTransaction(map.fireflyId);
          known = true;
          // Apply it again, thus the local copy gets the new date. When
          // dateCreated agrees with the remote booking date, the test above
          // skips this row in each later cycle.
          await _pullTransactions(client, report, preFetchedGroups: [remote]);
        } on FireflyNotFoundException {
          known = false;
        } catch (_) {
          // A network error or a server error is not proof of a delete. Keep
          // the row and try again in the next cycle.
          report.warnings
              .add("Could not confirm with Firefly whether a transaction was "
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
    // database.deleteCategory() also removes the subcategories, the
    // associated titles and the budget limits of this category, and it writes
    // the delete log. A plain delete of the row leaves a subcategory that
    // points at a parent that is gone. The transactions above no longer point
    // at this category, thus deleteCategory() does not delete a transaction.
    await database.deleteCategory(local.categoryPk, local.order);
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

Future<void> _pushCategories(FireflyApiClient client, DateTime lastSynced,
    FireflySyncReport report, _FireflyPushBacklog backlog,
    {required bool includeUnmodifiedRows}) async {
  List<TransactionCategory> changed =
      await database.getAllNewCategories(lastSynced);
  for (TransactionCategory category in changed) {
    // getAllNew*() also returns each row that has no dateTimeModified. Such a
    // row is not a recent change: it is a row from a version before that
    // column, or a row from an old backup. The app sends it only if the user
    // asks for the local history.
    if (category.dateTimeModified == null && !includeUnmodifiedRows) continue;
    // The local category for "Firefly has no category". Firefly must not get
    // a category with this name.
    if (category.categoryPk == kFireflyUncategorizedCategoryPk) continue;
    // The balance-correction category holds the balance anchors and the
    // manual corrections of the user. It is local only.
    // _ensureFireflySystemCategories writes it with a new dateTimeModified,
    // thus the first cycle finds it as a changed row.
    if (category.categoryPk == kBalanceCorrectionCategoryPk) continue;
    // A subcategory has no Firefly form, thus no later cycle can send it.
    // recordNotPushed is for a row that a next cycle can still send: to hold
    // the watermark at a row that never goes keeps it there for ever.
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
      if (!fireflyLocalRowChanged(
        localModified: category.dateTimeModified,
        lastSyncedLocalModified: map.lastSyncedLocalModified,
      )) {
        continue;
      }
      // Read the live record. map.fireflyUpdatedAt holds the time that the
      // last sync saw. If the two are compared with each other, a change made
      // on Firefly after that sync is invisible and the push destroys it.
      FireflyCategory remote;
      try {
        remote = await client.getCategory(map.fireflyId);
      } on FireflyNotFoundException {
        await _tombstoneMapRow(map);
        continue;
      }
      FireflySyncDirection direction = decideSyncDirection(
        localModified: category.dateTimeModified,
        remoteUpdatedAt: remote.updatedAt,
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
    FireflySyncReport report, _FireflyPushBacklog backlog,
    {required bool includeUnmodifiedRows}) async {
  List<TransactionWallet> changed = await database.getAllNewWallets(lastSynced);
  for (TransactionWallet wallet in changed) {
    // getAllNew*() also returns each row that has no dateTimeModified. Such a
    // row is not a recent change: it is a row from a version before that
    // column, or a row from an old backup. The app sends it only if the user
    // asks for the local history.
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
      if (!fireflyLocalRowChanged(
        localModified: wallet.dateTimeModified,
        lastSyncedLocalModified: map.lastSyncedLocalModified,
      )) {
        continue;
      }
      // Read the live record. It gives the time of the last remote change and
      // the account role. The local database has no account role, thus an
      // update that does not send the current role changes a savings account
      // or a credit card into a plain asset account.
      FireflyAccount remote;
      try {
        remote = await client.getAccount(map.fireflyId);
      } on FireflyNotFoundException {
        await _tombstoneMapRow(map);
        continue;
      }
      FireflySyncDirection direction = decideSyncDirection(
        localModified: wallet.dateTimeModified,
        remoteUpdatedAt: remote.updatedAt,
        lastSyncedLocalModified: map.lastSyncedLocalModified,
        lastSyncedRemoteUpdatedAt: map.fireflyUpdatedAt,
      );
      if (direction == FireflySyncDirection.push) {
        FireflyAccount updated = await client.updateAccount(
          map.fireflyId,
          walletToFireflyAccount(wallet,
              existingAccountRole: remote.accountRole),
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

// Builds the split list for a PUT that changes one split of a group.
//
// Firefly deletes each split that the request does not include, and it creates
// a new split when a changed split has no transaction_journal_id. The request
// therefore holds the changed split with its journal id, and the id alone for
// each other split. Firefly finds a submitted id in this group only. A stale
// id makes Firefly create a new split and delete the old one, thus this
// function first looks for the id in the live group and returns null if it is
// not there.
//
// A group with one split is different: Firefly updates that split and ignores
// the submitted id.
List<FireflyTransactionSplit>? _splitsForPartialGroupUpdate({
  required FireflyTransactionGroup remoteGroup,
  required FireflyTransactionSplit changedSplit,
  required int? changedJournalId,
}) {
  if (remoteGroup.splits.length <= 1) return [changedSplit];
  if (changedJournalId == null) return null;
  if (remoteGroup.splits.any((split) => split.transactionJournalId == null)) {
    return null;
  }
  if (!remoteGroup.splits
      .any((split) => split.transactionJournalId == changedJournalId)) {
    return null;
  }
  return [
    for (FireflyTransactionSplit remote in remoteGroup.splits)
      if (remote.transactionJournalId == changedJournalId)
        changedSplit
      else
        FireflyTransactionSplit.unchangedSplit(remote.transactionJournalId!)
  ];
}

// The journal id to store after an update. Firefly keeps the id of a split
// that the request identifies, thus the stored id stays correct. A group with
// one split has no submitted id, thus the response gives the id.
int? _journalIdAfterUpdate(
    FireflyTransactionGroup updated, int? storedJournalId) {
  if (storedJournalId != null &&
      updated.splits
          .any((split) => split.transactionJournalId == storedJournalId)) {
    return storedJournalId;
  }
  if (updated.splits.length == 1) {
    return updated.splits.first.transactionJournalId ?? storedJournalId;
  }
  return storedJournalId;
}

// The position of a split in the group after an update. The answer of the
// server holds each split in its order, thus the id gives the position. The
// stored position stays if the answer does not name the split.
int _splitIndexAfterUpdate(
    FireflyTransactionGroup updated, int? journalId, int storedIndex) {
  if (journalId == null) return storedIndex;
  for (int i = 0; i < updated.splits.length; i++) {
    if (updated.splits[i].transactionJournalId == journalId) return i;
  }
  return storedIndex;
}

// Deletes the Firefly record of a local row that the user marked as not paid,
// and removes the link rows. Each map row must point at the same Firefly
// group: a transfer has two local rows for one remote split.
Future<void> _removeRemoteRowThatIsNotPaid({
  required FireflyApiClient client,
  required List<FireflySyncMapEntry> maps,
  required FireflySyncReport report,
  required _FireflyPushBacklog backlog,
  required DateTime? localModified,
}) async {
  if (maps.isEmpty) return;
  FireflySyncMapEntry first = maps.first;
  FireflyTransactionGroup remoteGroup;
  try {
    remoteGroup = await client.getTransaction(first.fireflyId);
  } on FireflyNotFoundException {
    for (FireflySyncMapEntry map in maps) {
      await _deleteSyncMapRow(map);
    }
    return;
  }
  try {
    if (remoteGroup.splits.length <= 1) {
      await client.deleteTransaction(first.fireflyId);
    } else if (first.fireflyJournalId != null &&
        remoteGroup.splits.any(
            (split) => split.transactionJournalId == first.fireflyJournalId)) {
      await client.deleteTransactionJournal(first.fireflyJournalId!);
    } else {
      report.warnings.add(
          "Did not remove a transaction from Firefly that is no longer paid: "
          "it is one split of a transaction with "
          "${remoteGroup.splits.length} splits, and the app does not know "
          "which one.");
      backlog.recordNotPushed(localModified);
      return;
    }
  } catch (e) {
    report.warnings.add(
        "Could not remove a transaction from Firefly that is no longer paid: "
        "$e");
    backlog.recordNotPushed(localModified);
    return;
  }
  report.deletedRemote++;
  for (FireflySyncMapEntry map in maps) {
    await _deleteSyncMapRow(map);
  }
}

Future<void> _pushTransactions(
    FireflyApiClient client,
    DateTime lastSynced,
    _FireflyCounterpartyIndex counterparties,
    FireflySyncReport report,
    _FireflyPushBacklog backlog,
    {required bool includeUnmodifiedRows}) async {
  List<Transaction> changed = await database.getAllNewTransactions(lastSynced);
  Set<String> handledThisPass = {};

  for (Transaction transaction in changed) {
    if (handledThisPass.contains(transaction.transactionPk)) continue;
    // getAllNew*() also returns each row that has no dateTimeModified. Such a
    // row is not a recent change: it is a row from a version before that
    // column, or a row from an old backup. The app sends it only if the user
    // asks for the local history.
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
        backlog: backlog,
      );
      continue;
    }

    // Firefly has no state for a transaction that is not yet paid. Each
    // transaction that Firefly holds changes the balance of its account. A
    // local row that is not paid is an expected payment, thus the app does not
    // send it. If the user marks the row paid, the next cycle creates it.
    if (transaction.paid == false) {
      FireflySyncMapEntry? paidMap = await _syncMapByLocalPk(
          FireflySyncEntityType.transaction, transaction.transactionPk);
      if (paidMap != null) {
        await _removeRemoteRowThatIsNotPaid(
          client: client,
          maps: [paidMap],
          report: report,
          backlog: backlog,
          localModified: transaction.dateTimeModified,
        );
      }
      continue;
    }

    FireflySyncMapEntry? walletMap = await _syncMapByLocalPk(
        FireflySyncEntityType.wallet, transaction.walletFk);
    if (walletMap == null) {
      report.skippedUnmappedWallet++;
      backlog.recordNotPushed(transaction.dateTimeModified);
      continue;
    }

    FireflySyncMapEntry? categoryMap = await _syncMapByLocalPk(
        FireflySyncEntityType.category, transaction.categoryFk);
    TransactionCategory? category;
    try {
      category = await database.getCategoryInstance(transaction.categoryFk);
    } catch (_) {}
    // The row goes back with no category. The app must not make a category on
    // the server for it.
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
      List<FireflySyncMapEntry> groupMaps = await _syncMapsByFireflyId(
          FireflySyncEntityType.transaction, map.fireflyId);
      bool multiSplit =
          groupMaps.any((m) => m.fireflySplitIndex != map.fireflySplitIndex);
      if (multiSplit) {
        await _pushExistingMultiSplitGroup(
          client: client,
          groupMaps: groupMaps,
          counterparties: counterparties,
          report: report,
          backlog: backlog,
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
      transactionJournalId: map?.fireflyJournalId,
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
        fireflyJournalId: created.splits.isEmpty
            ? null
            : created.splits.first.transactionJournalId,
      );
      report.pushedTransactions++;
    } else {
      if (!fireflyLocalRowChanged(
        localModified: transaction.dateTimeModified,
        lastSyncedLocalModified: map.lastSyncedLocalModified,
      )) {
        continue;
      }
      // Read the live group. It gives the time of the last remote change, and
      // it shows each split that Firefly holds. The multiSplit test above uses
      // the sync map only, thus it does not know a split on an account that is
      // not linked, or a split outside the window of the sync.
      FireflyTransactionGroup remoteGroup;
      try {
        remoteGroup = await client.getTransaction(map.fireflyId);
      } on FireflyNotFoundException {
        await _tombstoneMapRow(map);
        continue;
      }
      FireflySyncDirection direction = decideSyncDirection(
        localModified: transaction.dateTimeModified,
        remoteUpdatedAt: remoteGroup.updatedAt,
        lastSyncedLocalModified: map.lastSyncedLocalModified,
        lastSyncedRemoteUpdatedAt: map.fireflyUpdatedAt,
      );
      if (direction == FireflySyncDirection.push) {
        List<FireflyTransactionSplit>? splits = _splitsForPartialGroupUpdate(
          remoteGroup: remoteGroup,
          changedSplit: split,
          changedJournalId: map.fireflyJournalId,
        );
        if (splits == null) {
          report.warnings
              .add("Did not push a change to a split transaction: it has "
                  "${remoteGroup.splits.length} splits on Firefly, and the app "
                  "does not know which one belongs to this record.");
          backlog.recordNotPushed(transaction.dateTimeModified);
          continue;
        }
        FireflyTransactionGroup updated = await client.updateTransaction(
            map.fireflyId,
            FireflyTransactionGroup(id: map.fireflyId, splits: splits));
        await _upsertSyncMap(
          syncMapPk: map.syncMapPk,
          type: FireflySyncEntityType.transaction,
          localPk: transaction.transactionPk,
          fireflyId: map.fireflyId,
          fireflyUpdatedAt: updated.updatedAt,
          lastSyncedLocalModified: transaction.dateTimeModified,
          counterpartyFireflyId: counterparty?.id ?? map.counterpartyFireflyId,
          fireflySplitIndex: map.fireflySplitIndex,
          fireflyJournalId:
              _journalIdAfterUpdate(updated, map.fireflyJournalId),
        );
        report.pushedTransactions++;
      }
    }
  }
}

// Rebuilds the Firefly split of the local row that a sync-map row points at.
// It returns null if the local row is gone or if the wallet of that row is not
// linked.
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
  FireflySyncMapEntry? categoryMap =
      await _syncMapByLocalPk(FireflySyncEntityType.category, local.categoryFk);
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
    transactionJournalId: map.fireflyJournalId,
  );
}

// Pushes the local changes of a group that holds more than one split.
//
// The request holds one entry for each split that Firefly has, in the order
// that Firefly gives. A split with a local row gets the rebuilt content. Each
// other split gets its id alone, which keeps it as it is. If a local row is
// not known as a split of the live group, the app cannot say which split it
// is, and this function makes no request.
Future<void> _pushExistingMultiSplitGroup({
  required FireflyApiClient client,
  required List<FireflySyncMapEntry> groupMaps,
  required _FireflyCounterpartyIndex counterparties,
  required FireflySyncReport report,
  required _FireflyPushBacklog backlog,
}) async {
  DateTime? newestLocal;
  DateTime? newestWatermark;
  for (FireflySyncMapEntry map in groupMaps) {
    Transaction? local = await database.tryGetTransactionFromPk(map.localPk);
    if (local?.dateTimeModified != null &&
        (newestLocal == null ||
            local!.dateTimeModified!.isAfter(newestLocal))) {
      newestLocal = local!.dateTimeModified;
    }
    if (map.lastSyncedLocalModified != null &&
        (newestWatermark == null ||
            map.lastSyncedLocalModified!.isAfter(newestWatermark))) {
      newestWatermark = map.lastSyncedLocalModified;
    }
  }
  if (!fireflyLocalRowChanged(
    localModified: newestLocal,
    lastSyncedLocalModified: newestWatermark,
  )) {
    return;
  }

  FireflyTransactionGroup remoteGroup;
  try {
    remoteGroup = await client.getTransaction(groupMaps.first.fireflyId);
  } on FireflyNotFoundException {
    for (FireflySyncMapEntry map in groupMaps) {
      await _tombstoneMapRow(map);
    }
    return;
  }

  FireflySyncDirection direction = decideSyncDirection(
    localModified: newestLocal,
    remoteUpdatedAt: remoteGroup.updatedAt,
    lastSyncedLocalModified: newestWatermark,
    lastSyncedRemoteUpdatedAt: groupMaps.first.fireflyUpdatedAt,
  );
  if (direction != FireflySyncDirection.push) return;

  // A row that holds no journal id at all cannot go into the request: the
  // app cannot say which split it is, and a request that does not name it
  // makes Firefly delete that split. The group waits for the next pull, which
  // gives the id.
  if (groupMaps.any((map) => map.fireflyJournalId == null)) {
    report.warnings.add(
        "Did not push a change to a split transaction: the app cannot say "
        "which of its ${remoteGroup.splits.length} splits each local record "
        "belongs to.");
    backlog.recordNotPushed(newestLocal);
    return;
  }

  // A row whose journal id is not in the live group points at a split that
  // the server no longer holds. To stop the full group for that one row stops
  // each other row of it, thus the app unlinks that row and pushes the rest.
  List<FireflySyncMapEntry> mappedGroupMaps = [];
  for (FireflySyncMapEntry map in groupMaps) {
    if (remoteGroup.splits
        .any((split) => split.transactionJournalId == map.fireflyJournalId)) {
      mappedGroupMaps.add(map);
      continue;
    }
    await _tombstoneMapRow(map);
    report.warnings.add(
        "A record of a split transaction is no longer on Firefly. This app "
        "keeps the record and no longer syncs it.");
  }
  if (mappedGroupMaps.isEmpty) return;
  groupMaps = mappedGroupMaps;

  // A PUT must name each split by its id. A split that comes with no id thus
  // stops the request. To read the id with `!` throws here and stops the full
  // cycle, and each later cycle again.
  if (remoteGroup.splits.any((split) => split.transactionJournalId == null)) {
    report.warnings.add(
        "Did not push a change to a split transaction: Firefly gave a split "
        "with no journal id.");
    backlog.recordNotPushed(newestLocal);
    return;
  }

  List<FireflyTransactionSplit> splits = [];
  Map<int, int> positionByJournalId = {};
  for (int i = 0; i < remoteGroup.splits.length; i++) {
    FireflyTransactionSplit remote = remoteGroup.splits[i];
    int journalId = remote.transactionJournalId!;
    positionByJournalId[journalId] = i;
    Iterable<FireflySyncMapEntry> matches =
        groupMaps.where((map) => map.fireflyJournalId == journalId);
    FireflyTransactionSplit? rebuilt = matches.isEmpty
        ? null
        : await _splitForMappedLocalRow(
            map: matches.first, counterparties: counterparties);
    splits.add(rebuilt ?? FireflyTransactionSplit.unchangedSplit(journalId));
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
      fireflySplitIndex:
          positionByJournalId[map.fireflyJournalId] ?? map.fireflySplitIndex,
      fireflyJournalId: _journalIdAfterUpdate(updated, map.fireflyJournalId),
    );
  }
  report.pushedTransactions++;
}

Future<void> _pushTransfer({
  required FireflyApiClient client,
  required Transaction transaction,
  required Set<String> handledThisPass,
  required FireflySyncReport report,
  required _FireflyPushBacklog backlog,
}) async {
  Transaction? paired =
      await database.tryGetTransactionFromPk(transaction.pairedTransactionFk!);
  if (paired == null) {
    // Firefly holds a transfer as one split with two accounts, thus the app
    // cannot send one side alone. Keep the change for a later cycle: the row
    // is behind the watermark after this cycle, and no other test finds it.
    handledThisPass.add(transaction.transactionPk);
    report.warnings.add(
        "Did not push a change to a transfer: this app holds one of its two "
        "sides only.");
    backlog.recordNotPushed(transaction.dateTimeModified);
    return;
  }

  Transaction fromTransaction = transaction.amount < 0 ? transaction : paired;
  Transaction toTransaction = transaction.amount < 0 ? paired : transaction;

  FireflySyncMapEntry? fromWalletMap = await _syncMapByLocalPk(
      FireflySyncEntityType.wallet, fromTransaction.walletFk);
  FireflySyncMapEntry? toWalletMap = await _syncMapByLocalPk(
      FireflySyncEntityType.wallet, toTransaction.walletFk);
  handledThisPass.add(transaction.transactionPk);
  handledThisPass.add(paired.transactionPk);
  if (fromWalletMap == null || toWalletMap == null) {
    report.skippedUnmappedWallet++;
    backlog.recordNotPushed(transaction.dateTimeModified);
    return;
  }

  FireflySyncMapEntry? fromMap = await _syncMapByLocalPk(
      FireflySyncEntityType.transaction, fromTransaction.transactionPk);
  FireflySyncMapEntry? toMap = await _syncMapByLocalPk(
      FireflySyncEntityType.transaction, toTransaction.transactionPk);

  // The two local rows of a transfer are one Firefly split, thus their rows
  // must give the same group. Two different groups mean that the user made
  // the pair from two records that each already had a Firefly record. To go
  // on writes both rows onto one group and leaves the other group on the
  // server with no local row, and the next pull then makes a second copy of
  // it. The app makes no request and tells the user.
  if (fromMap != null &&
      toMap != null &&
      fromMap.fireflyId != toMap.fireflyId) {
    report.warnings.add(
        "Did not push a change to a transfer: its two sides point at two "
        "different Firefly transactions. Remove one side and make it again.");
    backlog.recordNotPushed(transaction.dateTimeModified);
    return;
  }

  // Firefly counts each transaction that it holds in the balance of its
  // accounts, thus a transfer that is not yet paid stays local. Both sides
  // must be paid.
  if (fromTransaction.paid == false || toTransaction.paid == false) {
    List<FireflySyncMapEntry> maps = [
      if (fromMap != null) fromMap,
      if (toMap != null) toMap,
    ];
    if (maps.isNotEmpty) {
      await _removeRemoteRowThatIsNotPaid(
        client: client,
        maps: maps,
        report: report,
        backlog: backlog,
        localModified: transaction.dateTimeModified,
      );
    }
    return;
  }

  // The side that the user changed last gives the text of the one remote
  // split.
  bool toSideIsNewer = toTransaction.dateTimeModified != null &&
      (fromTransaction.dateTimeModified == null ||
          toTransaction.dateTimeModified!
              .isAfter(fromTransaction.dateTimeModified!));
  int? storedJournalId = fromMap?.fireflyJournalId ?? toMap?.fireflyJournalId;
  FireflyTransactionSplit split = transferPairToFireflySplit(
    fromTransaction: fromTransaction,
    toTransaction: toTransaction,
    fromWalletFireflyId: fromWalletMap.fireflyId,
    toWalletFireflyId: toWalletMap.fireflyId,
    descriptionOverride: toSideIsNewer ? toTransaction.name : null,
    notesOverride: toSideIsNewer ? toTransaction.note : null,
    transactionJournalId: storedJournalId,
  );

  if (fromMap == null && toMap == null) {
    FireflyTransactionGroup created = await client
        .createTransaction(FireflyTransactionGroup(id: 0, splits: [split]));
    // The two local rows are one remote split, thus they share its journal id.
    int? createdJournalId = created.splits.isEmpty
        ? null
        : created.splits.first.transactionJournalId;
    await _upsertSyncMap(
      type: FireflySyncEntityType.transaction,
      localPk: fromTransaction.transactionPk,
      fireflyId: created.id,
      fireflyUpdatedAt: created.updatedAt,
      lastSyncedLocalModified: fromTransaction.dateTimeModified,
      fireflySplitIndex: 0,
      fireflyJournalId: createdJournalId,
    );
    await _upsertSyncMap(
      type: FireflySyncEntityType.transaction,
      localPk: toTransaction.transactionPk,
      fireflyId: created.id,
      fireflyUpdatedAt: created.updatedAt,
      lastSyncedLocalModified: toTransaction.dateTimeModified,
      fireflySplitIndex: 0,
      fireflyJournalId: createdJournalId,
    );
    report.pushedTransactions++;
    return;
  }

  FireflySyncMapEntry linkedMap = (fromMap ?? toMap)!;
  // Each side has its own watermark, and the user can change either side. If
  // the app looks at the source row only, a change to the destination row
  // never goes to Firefly.
  bool fromChanged = fireflyLocalRowChanged(
    localModified: fromTransaction.dateTimeModified,
    lastSyncedLocalModified: fromMap?.lastSyncedLocalModified,
  );
  bool toChanged = fireflyLocalRowChanged(
    localModified: toTransaction.dateTimeModified,
    lastSyncedLocalModified: toMap?.lastSyncedLocalModified,
  );
  if (!fromChanged && !toChanged) return;

  FireflyTransactionGroup remoteGroup;
  try {
    remoteGroup = await client.getTransaction(linkedMap.fireflyId);
  } on FireflyNotFoundException {
    if (fromMap != null) await _tombstoneMapRow(fromMap);
    if (toMap != null) await _tombstoneMapRow(toMap);
    return;
  }

  DateTime? newestLocal = toSideIsNewer
      ? toTransaction.dateTimeModified
      : fromTransaction.dateTimeModified;
  FireflySyncDirection direction = decideSyncDirection(
    localModified: newestLocal,
    remoteUpdatedAt: remoteGroup.updatedAt,
    lastSyncedLocalModified: null,
    lastSyncedRemoteUpdatedAt: linkedMap.fireflyUpdatedAt,
  );
  if (direction != FireflySyncDirection.push) return;

  List<FireflyTransactionSplit>? splits = _splitsForPartialGroupUpdate(
    remoteGroup: remoteGroup,
    changedSplit: split,
    changedJournalId: storedJournalId,
  );
  if (splits == null) {
    report.warnings.add(
        "Did not push a change to a transfer: its Firefly transaction has "
        "${remoteGroup.splits.length} splits, and the app does not know which "
        "one is the transfer.");
    backlog.recordNotPushed(newestLocal);
    return;
  }

  FireflyTransactionGroup updated = await client.updateTransaction(
      linkedMap.fireflyId,
      FireflyTransactionGroup(id: linkedMap.fireflyId, splits: splits));
  // _upsertSyncMap writes with insertOrReplace, thus each field that this call
  // does not give gets its default value. If the journal id is not given here,
  // each transfer push erases it.
  int? transferJournalId = _journalIdAfterUpdate(updated, storedJournalId);
  // The position of the split in the group. The answer of the server gives it
  // when it names the split, thus a group that moved its splits stays right.
  int transferSplitIndex = _splitIndexAfterUpdate(
    updated,
    transferJournalId,
    fromMap?.fireflySplitIndex ?? toMap?.fireflySplitIndex ?? 0,
  );
  await _upsertSyncMap(
    syncMapPk: fromMap?.syncMapPk,
    type: FireflySyncEntityType.transaction,
    localPk: fromTransaction.transactionPk,
    fireflyId: linkedMap.fireflyId,
    fireflyUpdatedAt: updated.updatedAt,
    lastSyncedLocalModified: fromTransaction.dateTimeModified,
    fireflySplitIndex: transferSplitIndex,
    fireflyJournalId: transferJournalId,
  );
  await _upsertSyncMap(
    syncMapPk: toMap?.syncMapPk,
    type: FireflySyncEntityType.transaction,
    localPk: toTransaction.transactionPk,
    fireflyId: linkedMap.fireflyId,
    fireflyUpdatedAt: updated.updatedAt,
    lastSyncedLocalModified: toTransaction.dateTimeModified,
    fireflySplitIndex: transferSplitIndex,
    fireflyJournalId: transferJournalId,
  );
  report.pushedTransactions++;
}

Future<void> _pushDeletes(FireflyApiClient client, DateTime lastSynced,
    FireflySyncReport report, _FireflyPushBacklog backlog) async {
  List<DeleteLog> deleteLogs = await database.getAllNewDeleteLogs(lastSynced);
  Set<int> remoteDeletedTransactionIds = {};

  // First pass: the wallets. A wallet that the user deletes in this app is
  // unlinked from Firefly, and the Firefly account stays. DELETE on a Firefly
  // account destroys each transaction of that account, and also each other
  // split of the groups that hold them, which is history that the user did
  // not delete.
  //
  // deleteWallet() deletes the transactions of the wallet before it writes the
  // delete log of the wallet, thus the local rows are gone and the second pass
  // cannot read the wallet of a deleted transaction. The Firefly ids that this
  // pass collects tell the second pass which transaction to keep.
  Set<int> unlinkedAccountIds = {};
  for (DeleteLog log in deleteLogs) {
    if (log.type != DeleteLogType.TransactionWallet) continue;
    if (log.entryPk == "0") continue;
    FireflySyncMapEntry? map = await _syncMapByLocalPk(
        FireflySyncEntityType.wallet, log.entryPk,
        includeTombstones: true);
    if (map == null) continue;
    // The id goes into the set on each cycle, also when a cycle before this
    // one closed the link. The second pass uses the set to hold back a
    // transaction of the removed account. An empty set on a retry cycle lets
    // that transaction take the delete path and destroys the remote record.
    unlinkedAccountIds.add(map.fireflyId);
    if (map.isTombstone) continue;
    await _tombstoneMapRow(map);
    report.warnings
        .add("An account was removed in this app. Its Firefly account and the "
            "transactions of that account stay on the server, and this app no "
            "longer syncs them.");
  }

  for (DeleteLog log in deleteLogs) {
    FireflySyncEntityType? type;
    if (log.type == DeleteLogType.Transaction) {
      type = FireflySyncEntityType.transaction;
    } else if (log.type == DeleteLogType.TransactionCategory) {
      if (log.entryPk == "0") continue;
      type = FireflySyncEntityType.category;
    } else {
      continue;
    }

    FireflySyncMapEntry? map =
        await _syncMapByLocalPk(type, log.entryPk, includeTombstones: true);
    if (map == null) continue;
    if (map.isTombstone) continue;

    try {
      if (type == FireflySyncEntityType.transaction) {
        if (remoteDeletedTransactionIds.contains(map.fireflyId)) {
          await _tombstoneMapRow(map);
          continue;
        }
        if (unlinkedAccountIds.isNotEmpty &&
            await _transactionIsOnUnlinkedAccount(
                client: client,
                fireflyId: map.fireflyId,
                unlinkedAccountIds: unlinkedAccountIds)) {
          // The user deleted the account, not this transaction.
          await _tombstoneMapRow(map);
          continue;
        }
        List<FireflySyncMapEntry> groupMaps = await _syncMapsByFireflyId(
            FireflySyncEntityType.transaction, map.fireflyId);
        // A transfer is two local rows that point at one remote split. Such a
        // row is the other side of the transfer, not another split.
        bool pairedLegStillLocal = false;
        for (FireflySyncMapEntry sibling in groupMaps) {
          if (sibling.localPk == map.localPk) continue;
          bool sameRemoteSplit =
              (sibling.fireflyJournalId != null && map.fireflyJournalId != null)
                  ? sibling.fireflyJournalId == map.fireflyJournalId
                  : sibling.fireflySplitIndex == map.fireflySplitIndex;
          if (!sameRemoteSplit) continue;
          if (await database.tryGetTransactionFromPk(sibling.localPk) != null) {
            pairedLegStillLocal = true;
          }
        }
        // A Firefly group can hold several splits, and each split is one local
        // row. The delete must remove that split only, because a delete of the
        // group destroys each other split with it.
        //
        // The rows of this app do not say how many splits the group holds: a
        // split that the app never imported, or that it skipped, has no local
        // row. The live group must therefore be read before a delete, which is
        // what _removeSplitFromRemoteGroup does.
        bool groupWasDeleted = await _removeSplitFromRemoteGroup(
          client: client,
          deletedMap: map,
          groupMaps: groupMaps,
          report: report,
          backlog: backlog,
          deleteLoggedAt: log.dateTimeModified,
        );
        if (!groupWasDeleted) continue;
        remoteDeletedTransactionIds.add(map.fireflyId);
        if (pairedLegStillLocal) {
          // database.deleteTransaction does not follow pairedTransactionFk,
          // thus this app can hold one half of a transfer. Firefly cannot
          // store that.
          report.warnings
              .add("A transfer was removed from Firefly because one of its two "
                  "sides was deleted in Cashew. The other side is still stored "
                  "locally and is no longer synced.");
        }
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
      backlog.recordNotPushed(log.dateTimeModified);
      print("Firefly push-delete error (will retry): " + e.toString());
    }
  }
}

// True if one side of the Firefly transaction is an account that the user
// removed in this app during this cycle.
Future<bool> _transactionIsOnUnlinkedAccount({
  required FireflyApiClient client,
  required int fireflyId,
  required Set<int> unlinkedAccountIds,
}) async {
  FireflyTransactionGroup remoteGroup;
  try {
    remoteGroup = await client.getTransaction(fireflyId);
  } on FireflyNotFoundException {
    return false;
  }
  return remoteGroup.splits.any((split) =>
      unlinkedAccountIds.contains(split.sourceId) ||
      unlinkedAccountIds.contains(split.destinationId));
}

// Removes one split from a Firefly group and keeps the other splits.
//
// DELETE on a transaction-journal removes that split alone. A PUT that
// rewrites the group would give each other split a new journal id and would
// delete each split that this app does not know.
//
// Firefly answers a journal id of another group, or an id that is not there,
// with a 401 error and not with a 404 error. The app therefore first reads the
// live group and looks for the id in it.
// Gives true when the full group went, and false when it stays.
Future<bool> _removeSplitFromRemoteGroup({
  required FireflyApiClient client,
  required FireflySyncMapEntry deletedMap,
  // Each row of this app that points at the group. The links of all of them
  // close when the full group goes.
  required List<FireflySyncMapEntry> groupMaps,
  required FireflySyncReport report,
  required _FireflyPushBacklog backlog,
  required DateTime deleteLoggedAt,
}) async {
  FireflyTransactionGroup remoteGroup;
  try {
    remoteGroup = await client.getTransaction(deletedMap.fireflyId);
  } on FireflyNotFoundException {
    await _tombstoneGroupMaps(deletedMap, groupMaps);
    return false;
  }
  if (remoteGroup.splits.length <= 1) {
    await client.deleteTransaction(deletedMap.fireflyId);
    await _tombstoneGroupMaps(deletedMap, groupMaps);
    report.deletedRemote++;
    return true;
  }
  int? journalId = deletedMap.fireflyJournalId;
  if (journalId == null ||
      !remoteGroup.splits
          .any((split) => split.transactionJournalId == journalId)) {
    report.warnings.add(
        "Did not remove a deleted record from a Firefly split transaction: "
        "the app cannot say which of its ${remoteGroup.splits.length} splits "
        "the record is.");
    backlog.recordNotPushed(deleteLoggedAt);
    return false;
  }
  await client.deleteTransactionJournal(journalId);
  await _tombstoneMapRow(deletedMap);
  report.deletedRemote++;
  return false;
}

Future<void> _tombstoneGroupMaps(
    FireflySyncMapEntry deletedMap, List<FireflySyncMapEntry> groupMaps) async {
  await _tombstoneMapRow(deletedMap);
  for (FireflySyncMapEntry sibling in groupMaps) {
    if (sibling.syncMapPk == deletedMap.syncMapPk) continue;
    await _tombstoneMapRow(sibling);
  }
}

// The balance anchor of a wallet is one local row that holds the total of the
// data before the window:
//
//     anchor = firefly_current_balance - sum(the other local rows)
//
// Thus the local sum plus the anchor is the balance that Firefly reports. The
// anchor is in the reserved balance-correction category "0", thus the filter
// onlyShowIfNotBalanceCorrection() keeps it in the net totals and net worth,
// and out of the income and expense views. The anchor corrects itself: when
// an on-demand fetch adds older rows, the local sum increases and the anchor
// decreases by the same amount.

// A difference that is less than this is no change. To write the anchor again
// starts the auto-sync watcher, thus small floating-point noise must not do
// it.
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
    // Without a balance from the server the code cannot calculate an anchor.
    // Keep the anchor that is there: an old anchor is nearer to the truth
    // than a guess.
    if (existing == null) {
      report.warnings.add(
          "Firefly did not report a balance for one account; its total may be "
          "short by the history that is not stored locally.");
    }
    return;
  }

  // Firefly reports the balance of today and does not count a transaction
  // with a date in the future. The local sum must use the same rule, or each
  // such transaction makes the anchor wrong by its amount.
  double localSum = await database.getSumOfWalletExcludingTransaction(
      walletPk, anchorPk,
      notLaterThan: DateTime.now());
  double anchorAmount = remoteBalance - localSum;

  // Nothing to hold, and no row on disk. Do not make a row.
  if (existing == null && anchorAmount.abs() < _kAnchorEpsilon) return;
  // No change. The write is not permitted here: it sets a new
  // dateTimeModified, which starts the auto-sync watcher and one more sync in
  // each cycle.
  if (existing != null &&
      (existing.amount - anchorAmount).abs() < _kAnchorEpsilon) {
    return;
  }

  DateTime? earliest =
      await database.getEarliestTransactionDateOfWallet(walletPk, anchorPk);
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

// The functions below read data from before the sync window, after an action
// of the user: a search, a filter on a date, an open account, or a pull to
// refresh a balance. They write each record into the local database, where it
// is a usual local row.
//
// None of them compares deletes and none of them moves fireflyLastSyncedAt.
// They read a part of the remote data on purpose, and _applyRemoteDeletes
// accepts a complete set only.

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
    // In the same queue as the routine sync. These fetches use the same
    // _pullTransactions code on data that can be the same. If one runs during
    // a sync, both can read the same Firefly group, both find no link, and
    // each insert its own local copy.
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

// Reads and keeps a range of booking dates from before the window, for
// example when the user scrolls or filters back past it.
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

// Reads each record that Firefly holds for one wallet, with an optional range
// of dates. This gives the full history of an account.
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

// Sends a full-text search to Firefly and keeps each record that comes back,
// thus a result from before the window becomes a local row.
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

// Reads the balances from Firefly again and writes the anchor of each linked
// wallet. This costs one account list and no transactions, thus a pull to
// refresh on a balance view or a net worth view can use it.
Future<bool> fireflyRefreshBalances() async {
  FireflySyncReport? report = await _withFireflyClient((client) async {
    FireflySyncReport report = FireflySyncReport();
    await _ensureFireflySystemCategories();
    await _refreshBalanceAnchors(client, report);
    return report;
  });
  return report != null;
}

// Makes the window larger and syncs again, for "my older transactions are not
// here". This is expensive on a full server, thus only the user starts it.
Future<bool> fireflySyncAllHistory() async {
  return await fireflySyncNow(fullResync: true);
}

// The functions below are the ones that the views of the application call.
// Each one does nothing if Firefly is off, uses the network only if the view
// asks for data that the local window does not hold, and keeps a record of
// what it read, thus a filter that the user sets two times reads the data one
// time. The caller does not wait for a result: the data goes into the local
// database, and the Drift streams put it into the open view.

String _fireflyDayKey(DateTime date) => date.toIso8601String().substring(0, 10);

final Set<String> _fireflyFetchedRangeKeys = {};
final Set<String> _fireflyFetchedSearchQueries = {};
final Set<String> _fireflyFetchedWalletPks = {};

// Clears the record of what the fetches read. A different server, or a larger
// window, makes each entry of that record wrong.
void fireflyClearOnDemandCacheMemory() {
  _fireflyFetchedRangeKeys.clear();
  _fireflyFetchedSearchQueries.clear();
  _fireflyFetchedWalletPks.clear();
}

// The user set a filter or scrolled to a range of dates. Only a range that
// starts before the window needs data from the server.
Future<void> fireflyEnsureRangeCached(DateTime? start, DateTime? end) async {
  if (!fireflyEnabled) return;
  if (start == null) return;
  if (!start.isBefore(fireflySyncWindowStart())) return;
  String key =
      _fireflyDayKey(start) + ".." + (end == null ? "" : _fireflyDayKey(end));
  if (!_fireflyFetchedRangeKeys.add(key)) return;
  FireflySyncReport? report =
      await fireflyFetchTransactionRange(start: start, end: end);
  // A fetch that fails must not go into the record, or the range stays empty
  // until the application starts again.
  if (report == null) _fireflyFetchedRangeKeys.remove(key);
}

// The user typed a search. Firefly searches its full history, thus this is
// the only way to see a result from before the window.
Future<void> fireflyEnsureSearchCached(String? query) async {
  if (!fireflyEnabled) return;
  String trimmed = (query ?? "").trim();
  // A query of less than three characters matches too much data, and the
  // local rows give an answer.
  if (trimmed.length < 3) return;
  String key = trimmed.toLowerCase();
  if (!_fireflyFetchedSearchQueries.add(key)) return;
  FireflySyncReport? report = await fireflySearchAndCacheTransactions(trimmed);
  if (report == null) _fireflyFetchedSearchQueries.remove(key);
}

// The user opened one account. This reads the full history of that account
// one time in each run of the application, thus its list of transactions and
// its balance are complete.
Future<void> fireflyEnsureWalletHistoryCached(String walletPk) async {
  if (!fireflyEnabled) return;
  if (!_fireflyFetchedWalletPks.add(walletPk)) return;
  FireflySyncReport? report = await fireflyFetchTransactionsForWallet(walletPk);
  if (report == null) _fireflyFetchedWalletPks.remove(walletPk);
}

// Sends the local transactions that are older than the link to Firefly. Only
// the user starts this: on a server that holds data it makes a remote copy of
// each local row, and there is no safe test for the rows that Firefly has.
Future<bool> fireflyUploadExistingLocalHistory() async {
  return await fireflySyncNow(pushExistingLocalHistory: true);
}
