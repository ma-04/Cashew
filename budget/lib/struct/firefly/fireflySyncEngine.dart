// Orchestrates 2-way sync between the local database and a self-hosted
// Firefly III instance. Structurally mirrors lib/struct/syncClient.dart's
// syncData() (in-flight guard, debounce, loading indicators) but is a fully
// separate, self-contained module - Google Drive sync and Firefly sync are
// mutually exclusive per install (enforced in the settings UI), so nothing
// here is called from or calls into syncClient.dart.
//
// Sync order per cycle: pull (categories -> accounts -> transactions), then
// push (categories -> accounts -> transactions -> deletes). Pulling first
// means a remote-side conflict is visible before any local push could
// overwrite it. FireflySyncMap rows are written incrementally per record
// (not one final batch commit) so a killed/interrupted sync resumes
// correctly next cycle instead of duplicating or orphaning records.
//
// Phase 1 scope: Accounts (Wallets) / Transactions / Categories only.
// See budget/FIREFLY_SYNC_FUTURE_SCOPE.md for what's deliberately deferred.

import 'package:drift/drift.dart' show Value, InsertMode;
import 'package:flutter/foundation.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/firefly/fireflyApiClient.dart';
import 'package:budget/struct/firefly/fireflyMapper.dart';
import 'package:budget/struct/firefly/fireflyModels.dart';
import 'package:budget/struct/firefly/fireflySettings.dart';
import 'package:budget/widgets/util/debouncer.dart';

enum FireflySyncStatus { neverSynced, idle, syncing, error }

final ValueNotifier<FireflySyncStatus> fireflySyncStatusNotifier =
    ValueNotifier(FireflySyncStatus.neverSynced);
final ValueNotifier<String?> fireflySyncErrorNotifier = ValueNotifier(null);

bool _canSyncFirefly = true;
final Debouncer fireflyPushDebouncer = Debouncer(milliseconds: 5000);

// Called from the auto-sync watcher on any local change - debounced so a
// burst of edits results in one sync, not one per row.
void scheduleFireflyPush() {
  if (!fireflyEnabled) return;
  fireflyPushDebouncer.run(() {
    fireflySyncNow();
  });
}

// Hits GET /about with the given (not-yet-saved) credentials - used by the
// "Test Connection" button before the user commits to enabling sync.
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

Future<bool> fireflySyncNow({bool fullResync = false}) async {
  if (!fireflyEnabled) return false;
  if (!_canSyncFirefly) return false;
  _canSyncFirefly = false;
  fireflySyncStatusNotifier.value = FireflySyncStatus.syncing;
  fireflySyncErrorNotifier.value = null;

  FireflyApiClient? client;
  try {
    String hostUrl = fireflyHostUrl;
    String? pat = await getFireflyPat();
    if (hostUrl.isEmpty || pat == null || pat.isEmpty) {
      throw FireflyAuthException("Firefly host or access token not set");
    }
    client = FireflyApiClient(baseUrl: hostUrl, personalAccessToken: pat);

    DateTime lastSynced =
        fullResync ? DateTime(2000) : (fireflyLastSyncedAt ?? DateTime(2000));
    DateTime syncStartedAt = DateTime.now();

    await _pullCategories(client, lastSynced);
    await _pullAccounts(client, lastSynced);
    await _pullTransactions(client, lastSynced, syncStartedAt);

    await _pushCategories(client, lastSynced);
    await _pushAccounts(client, lastSynced);
    await _pushTransactions(client, lastSynced);
    await _pushDeletes(client, lastSynced);

    await setFireflyLastSyncedAt(syncStartedAt);
    fireflySyncStatusNotifier.value = FireflySyncStatus.idle;
    return true;
  } catch (e) {
    print("Firefly sync error: " + e.toString());
    fireflySyncErrorNotifier.value = e.toString();
    fireflySyncStatusNotifier.value = FireflySyncStatus.error;
    return false;
  } finally {
    client?.close();
    _canSyncFirefly = true;
  }
}

// ---------------------------------------------------------------------------
// FireflySyncMap helpers - kept here rather than in tables.dart since this
// is the only file that touches this table.
// ---------------------------------------------------------------------------

Future<List<FireflySyncMapEntry>> _syncMapEntriesForType(
    FireflySyncEntityType type) {
  return (database.select(database.fireflySyncMap)
        ..where((tbl) => tbl.entityType.equalsValue(type)))
      .get();
}

Future<FireflySyncMapEntry?> _syncMapByLocalPk(
    FireflySyncEntityType type, String localPk) {
  return (database.select(database.fireflySyncMap)
        ..where((tbl) =>
            tbl.entityType.equalsValue(type) & tbl.localPk.equals(localPk)))
      .getSingleOrNull();
}

Future<void> _upsertSyncMap({
  String? syncMapPk,
  required FireflySyncEntityType type,
  required String localPk,
  required int fireflyId,
  DateTime? fireflyUpdatedAt,
  DateTime? lastSyncedLocalModified,
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
        ),
        mode: InsertMode.insertOrReplace,
      );
}

Future<void> _deleteSyncMapRow(String syncMapPk) async {
  await (database.delete(database.fireflySyncMap)
        ..where((tbl) => tbl.syncMapPk.equals(syncMapPk)))
      .go();
}

// ---------------------------------------------------------------------------
// Pull
// ---------------------------------------------------------------------------

Future<void> _pullCategories(FireflyApiClient client, DateTime lastSynced) async {
  List<FireflyCategory> remoteCategories = await client.getCategories();
  List<TransactionCategory> localMainCategories =
      (await database.getAllCategories()).toList();
  int nextOrder = localMainCategories.isEmpty
      ? 0
      : localMainCategories.map((c) => c.order).reduce((a, b) => a > b ? a : b) +
          1;

  for (FireflyCategory remote in remoteCategories) {
    FireflySyncMapEntry? map =
        await _syncMapByLocalPk(FireflySyncEntityType.category, "");
    map = await (database.select(database.fireflySyncMap)
          ..where((tbl) =>
              tbl.entityType.equalsValue(FireflySyncEntityType.category) &
              tbl.fireflyId.equals(remote.id)))
        .getSingleOrNull();

    if (map == null) {
      // Not linked yet - try to dedup against an existing unmapped local
      // main category by exact case-insensitive name match.
      TransactionCategory? nameMatch;
      for (TransactionCategory candidate in localMainCategories) {
        if (candidate.mainCategoryPk != null) continue;
        if (candidate.name.trim().toLowerCase() !=
            remote.name.trim().toLowerCase()) continue;
        FireflySyncMapEntry? existingMapForCandidate = await _syncMapByLocalPk(
            FireflySyncEntityType.category, candidate.categoryPk);
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
      } else {
        TransactionCategory newCategory = fireflyCategoryToCategory(remote,
            order: nextOrder);
        nextOrder++;
        await database.createOrUpdateCategory(newCategory,
            insert: true, updateSharedEntry: false);
        TransactionCategory inserted =
            await database.getCategoryInstanceGivenName(remote.name);
        await _upsertSyncMap(
          type: FireflySyncEntityType.category,
          localPk: inserted.categoryPk,
          fireflyId: remote.id,
          fireflyUpdatedAt: remote.updatedAt,
          lastSyncedLocalModified: inserted.dateTimeModified,
        );
      }
      continue;
    }

    TransactionCategory? local =
        await database.getCategoryInstanceOrNull(map.localPk);
    if (local == null) {
      await _deleteSyncMapRow(map.syncMapPk);
      continue;
    }

    FireflySyncDirection direction = decideSyncDirection(
      localModified: local.dateTimeModified,
      remoteUpdatedAt: remote.updatedAt,
      lastSyncedLocalModified: map.lastSyncedLocalModified,
      lastSyncedRemoteUpdatedAt: map.fireflyUpdatedAt,
    );
    if (direction == FireflySyncDirection.pull) {
      TransactionCategory updated = fireflyCategoryToCategory(
        remote,
        order: local.order,
        existingCategoryPk: local.categoryPk,
      );
      await database.createOrUpdateCategory(updated,
          insert: false, updateSharedEntry: false);
      await _upsertSyncMap(
        syncMapPk: map.syncMapPk,
        type: FireflySyncEntityType.category,
        localPk: local.categoryPk,
        fireflyId: remote.id,
        fireflyUpdatedAt: remote.updatedAt,
        lastSyncedLocalModified: updated.dateTimeModified,
      );
    }
  }
}

Future<void> _pullAccounts(FireflyApiClient client, DateTime lastSynced) async {
  List<FireflyAccount> remoteAccounts =
      await client.getAccounts(type: kFireflyAssetAccountType);
  List<TransactionWallet> localWallets = await database.getAllWallets();
  int nextOrder = localWallets.isEmpty
      ? 0
      : localWallets.map((w) => w.order).reduce((a, b) => a > b ? a : b) + 1;

  for (FireflyAccount remote in remoteAccounts) {
    FireflySyncMapEntry? map = await (database.select(database.fireflySyncMap)
          ..where((tbl) =>
              tbl.entityType.equalsValue(FireflySyncEntityType.wallet) &
              tbl.fireflyId.equals(remote.id)))
        .getSingleOrNull();

    if (map == null) {
      TransactionWallet? nameMatch;
      for (TransactionWallet candidate in localWallets) {
        if (candidate.name.trim().toLowerCase() !=
            remote.name.trim().toLowerCase()) continue;
        FireflySyncMapEntry? existingMapForCandidate = await _syncMapByLocalPk(
            FireflySyncEntityType.wallet, candidate.walletPk);
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
      } else {
        TransactionWallet newWallet =
            fireflyAccountToWallet(remote, order: nextOrder);
        nextOrder++;
        await database.createOrUpdateWallet(newWallet, insert: true);
        TransactionWallet inserted =
            await database.getWalletInstanceGivenName(remote.name);
        await _upsertSyncMap(
          type: FireflySyncEntityType.wallet,
          localPk: inserted.walletPk,
          fireflyId: remote.id,
          fireflyUpdatedAt: remote.updatedAt,
          lastSyncedLocalModified: inserted.dateTimeModified,
        );
      }
      continue;
    }

    TransactionWallet? local =
        await database.getWalletInstanceOrNull(map.localPk);
    if (local == null) {
      await _deleteSyncMapRow(map.syncMapPk);
      continue;
    }

    FireflySyncDirection direction = decideSyncDirection(
      localModified: local.dateTimeModified,
      remoteUpdatedAt: remote.updatedAt,
      lastSyncedLocalModified: map.lastSyncedLocalModified,
      lastSyncedRemoteUpdatedAt: map.fireflyUpdatedAt,
    );
    if (direction == FireflySyncDirection.pull) {
      TransactionWallet updated = fireflyAccountToWallet(
        remote,
        order: local.order,
        existingWalletPk: local.walletPk,
      );
      await database.createOrUpdateWallet(updated, insert: false);
      await _upsertSyncMap(
        syncMapPk: map.syncMapPk,
        type: FireflySyncEntityType.wallet,
        localPk: local.walletPk,
        fireflyId: remote.id,
        fireflyUpdatedAt: remote.updatedAt,
        lastSyncedLocalModified: updated.dateTimeModified,
      );
    }
  }
}

Future<void> _pullTransactions(
    FireflyApiClient client, DateTime lastSynced, DateTime syncStartedAt) async {
  List<FireflyTransactionGroup> groups = await client.getTransactions(
    start: lastSynced,
    end: syncStartedAt.add(Duration(days: 1)),
  );

  List<FireflySyncMapEntry> walletMaps =
      await _syncMapEntriesForType(FireflySyncEntityType.wallet);
  Map<int, String> walletFireflyIdToLocalPk = {
    for (var m in walletMaps) m.fireflyId: m.localPk
  };
  List<FireflySyncMapEntry> categoryMaps =
      await _syncMapEntriesForType(FireflySyncEntityType.category);
  Map<int, String> categoryFireflyIdToLocalPk = {
    for (var m in categoryMaps) m.fireflyId: m.localPk
  };

  for (FireflyTransactionGroup group in groups) {
    if (group.splits.isEmpty) continue;
    // Cashew has no concept of multi-split journals - only the first split
    // is synced; extras are silently skipped (see FIREFLY_SYNC_FUTURE_SCOPE.md).
    FireflyTransactionSplit split = group.splits.first;
    FireflyPulledSplitKind kind = classifySplitType(split.type);
    if (kind == FireflyPulledSplitKind.skip) continue;

    FireflySyncMapEntry? existingMap = await (database
            .select(database.fireflySyncMap)
          ..where((tbl) =>
              tbl.entityType.equalsValue(FireflySyncEntityType.transaction) &
              tbl.fireflyId.equals(group.id)))
        .getSingleOrNull();

    if (kind == FireflyPulledSplitKind.transfer) {
      String? sourcePk =
          split.sourceId == null ? null : walletFireflyIdToLocalPk[split.sourceId];
      String? destPk = split.destinationId == null
          ? null
          : walletFireflyIdToLocalPk[split.destinationId];
      if (sourcePk == null || destPk == null) continue; // one side not a synced asset account

      if (existingMap == null) {
        (Transaction, Transaction) pair = fireflySplitToTransferPair(
          split,
          sourceWalletPk: sourcePk,
          destWalletPk: destPk,
        );
        await database.createOrUpdateTransaction(pair.$1,
            insert: false, updateSharedEntry: false);
        await database.createOrUpdateTransaction(pair.$2,
            insert: false, updateSharedEntry: false);
        await _upsertSyncMap(
          type: FireflySyncEntityType.transaction,
          localPk: pair.$1.transactionPk,
          fireflyId: group.id,
          fireflyUpdatedAt: group.updatedAt,
          lastSyncedLocalModified: pair.$1.dateTimeModified,
        );
        await _upsertSyncMap(
          type: FireflySyncEntityType.transaction,
          localPk: pair.$2.transactionPk,
          fireflyId: group.id,
          fireflyUpdatedAt: group.updatedAt,
          lastSyncedLocalModified: pair.$2.dateTimeModified,
        );
      }
      // Updates to already-linked transfers are left to the push side
      // (last-write-wins is evaluated per-transaction there); pulling an
      // update for a 2-row transfer is deferred to a future iteration.
      continue;
    }

    // withdrawal / deposit
    String? walletPk = kind == FireflyPulledSplitKind.withdrawal
        ? (split.sourceId == null ? null : walletFireflyIdToLocalPk[split.sourceId])
        : (split.destinationId == null
            ? null
            : walletFireflyIdToLocalPk[split.destinationId]);
    if (walletPk == null) continue; // not one of our synced asset accounts

    String categoryPk = split.categoryId == null
        ? kUncategorizedCategoryPk
        : (categoryFireflyIdToLocalPk[split.categoryId] ?? kUncategorizedCategoryPk);

    if (existingMap == null) {
      Transaction newTransaction = fireflySplitToTransaction(
        split,
        walletPk: walletPk,
        categoryPk: categoryPk,
      );
      await database.createOrUpdateTransaction(newTransaction,
          insert: true, updateSharedEntry: false);
      Transaction? inserted = await database.tryGetTransactionFromPk(
          newTransaction.transactionPk);
      // insert:true generates a fresh pk, so re-fetch by matching fields is
      // unreliable; instead find the most recently created transaction on
      // this wallet with a null map entry. Fall back to skipping the map
      // row if this fails - the transaction still exists locally either way.
      inserted ??= (await database.getAllTransactionsFromWallet(walletPk))
          .where((t) => t.methodAdded == MethodAdded.firefly)
          .fold<Transaction?>(null, (latest, t) =>
              latest == null || t.dateCreated.isAfter(latest.dateCreated)
                  ? t
                  : latest);
      if (inserted != null) {
        await _upsertSyncMap(
          type: FireflySyncEntityType.transaction,
          localPk: inserted.transactionPk,
          fireflyId: group.id,
          fireflyUpdatedAt: group.updatedAt,
          lastSyncedLocalModified: inserted.dateTimeModified,
        );
      }
    } else {
      Transaction? local =
          await database.tryGetTransactionFromPk(existingMap.localPk);
      if (local == null) {
        await _deleteSyncMapRow(existingMap.syncMapPk);
        continue;
      }
      FireflySyncDirection direction = decideSyncDirection(
        localModified: local.dateTimeModified,
        remoteUpdatedAt: group.updatedAt,
        lastSyncedLocalModified: existingMap.lastSyncedLocalModified,
        lastSyncedRemoteUpdatedAt: existingMap.fireflyUpdatedAt,
      );
      if (direction == FireflySyncDirection.pull) {
        Transaction updated = fireflySplitToTransaction(
          split,
          walletPk: walletPk,
          categoryPk: categoryPk,
          existingTransactionPk: local.transactionPk,
        );
        await database.createOrUpdateTransaction(updated,
            insert: false, updateSharedEntry: false);
        await _upsertSyncMap(
          syncMapPk: existingMap.syncMapPk,
          type: FireflySyncEntityType.transaction,
          localPk: local.transactionPk,
          fireflyId: group.id,
          fireflyUpdatedAt: group.updatedAt,
          lastSyncedLocalModified: updated.dateTimeModified,
        );
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Push
// ---------------------------------------------------------------------------

Future<void> _pushCategories(FireflyApiClient client, DateTime lastSynced) async {
  List<TransactionCategory> changed = await database.getAllNewCategories(lastSynced);
  for (TransactionCategory category in changed) {
    if (category.mainCategoryPk != null) continue; // subcategories deferred
    FireflyCategory? remoteShape = categoryToFireflyCategory(category);
    if (remoteShape == null) continue;

    FireflySyncMapEntry? map =
        await _syncMapByLocalPk(FireflySyncEntityType.category, category.categoryPk);
    if (map == null) {
      FireflyCategory created = await client.createCategory(remoteShape);
      await _upsertSyncMap(
        type: FireflySyncEntityType.category,
        localPk: category.categoryPk,
        fireflyId: created.id,
        fireflyUpdatedAt: created.updatedAt,
        lastSyncedLocalModified: category.dateTimeModified,
      );
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
      }
    }
  }
}

Future<void> _pushAccounts(FireflyApiClient client, DateTime lastSynced) async {
  List<TransactionWallet> changed = await database.getAllNewWallets(lastSynced);
  for (TransactionWallet wallet in changed) {
    FireflyAccount remoteShape = walletToFireflyAccount(wallet);
    FireflySyncMapEntry? map =
        await _syncMapByLocalPk(FireflySyncEntityType.wallet, wallet.walletPk);
    if (map == null) {
      FireflyAccount created = await client.createAccount(remoteShape);
      await _upsertSyncMap(
        type: FireflySyncEntityType.wallet,
        localPk: wallet.walletPk,
        fireflyId: created.id,
        fireflyUpdatedAt: created.updatedAt,
        lastSyncedLocalModified: wallet.dateTimeModified,
      );
    } else {
      FireflySyncDirection direction = decideSyncDirection(
        localModified: wallet.dateTimeModified,
        remoteUpdatedAt: map.fireflyUpdatedAt,
        lastSyncedLocalModified: map.lastSyncedLocalModified,
        lastSyncedRemoteUpdatedAt: map.fireflyUpdatedAt,
      );
      if (direction == FireflySyncDirection.push) {
        FireflyAccount updated =
            await client.updateAccount(map.fireflyId, remoteShape);
        await _upsertSyncMap(
          syncMapPk: map.syncMapPk,
          type: FireflySyncEntityType.wallet,
          localPk: wallet.walletPk,
          fireflyId: map.fireflyId,
          fireflyUpdatedAt: updated.updatedAt,
          lastSyncedLocalModified: wallet.dateTimeModified,
        );
      }
    }
  }
}

Future<void> _pushTransactions(FireflyApiClient client, DateTime lastSynced) async {
  List<Transaction> changed = await database.getAllNewTransactions(lastSynced);
  Set<String> handledThisPass = {};

  for (Transaction transaction in changed) {
    if (handledThisPass.contains(transaction.transactionPk)) continue;

    if (transaction.pairedTransactionFk != null) {
      Transaction? paired = await database
          .tryGetTransactionFromPk(transaction.pairedTransactionFk!);
      if (paired == null) continue; // orphaned half of a transfer

      Transaction fromTransaction =
          transaction.amount < 0 ? transaction : paired;
      Transaction toTransaction = transaction.amount < 0 ? paired : transaction;

      FireflySyncMapEntry? fromWalletMap = await _syncMapByLocalPk(
          FireflySyncEntityType.wallet, fromTransaction.walletFk);
      FireflySyncMapEntry? toWalletMap = await _syncMapByLocalPk(
          FireflySyncEntityType.wallet, toTransaction.walletFk);
      handledThisPass.add(transaction.transactionPk);
      handledThisPass.add(paired.transactionPk);
      if (fromWalletMap == null || toWalletMap == null) continue; // one side not a synced wallet

      FireflyTransactionSplit split = transferPairToFireflySplit(
        fromTransaction: fromTransaction,
        toTransaction: toTransaction,
        fromWalletFireflyId: fromWalletMap.fireflyId,
        toWalletFireflyId: toWalletMap.fireflyId,
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
      } else {
        FireflySyncMapEntry linkedMap = (fromMap ?? toMap)!;
        FireflySyncDirection direction = decideSyncDirection(
          localModified: fromTransaction.dateTimeModified,
          remoteUpdatedAt: linkedMap.fireflyUpdatedAt,
          lastSyncedLocalModified: linkedMap.lastSyncedLocalModified,
          lastSyncedRemoteUpdatedAt: linkedMap.fireflyUpdatedAt,
        );
        if (direction == FireflySyncDirection.push) {
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
        }
      }
      continue;
    }

    // Non-transfer
    FireflySyncMapEntry? walletMap = await _syncMapByLocalPk(
        FireflySyncEntityType.wallet, transaction.walletFk);
    if (walletMap == null) continue; // wallet not linked yet, will retry next cycle

    FireflySyncMapEntry? categoryMap = await _syncMapByLocalPk(
        FireflySyncEntityType.category, transaction.categoryFk);

    FireflyTransactionSplit split = transactionToFireflySplit(
      transaction,
      walletFireflyId: walletMap.fireflyId,
      categoryFireflyId: categoryMap?.fireflyId,
    );
    FireflyTransactionGroup group = FireflyTransactionGroup(id: 0, splits: [split]);

    FireflySyncMapEntry? map = await _syncMapByLocalPk(
        FireflySyncEntityType.transaction, transaction.transactionPk);
    if (map == null) {
      FireflyTransactionGroup created = await client.createTransaction(group);
      await _upsertSyncMap(
        type: FireflySyncEntityType.transaction,
        localPk: transaction.transactionPk,
        fireflyId: created.id,
        fireflyUpdatedAt: created.updatedAt,
        lastSyncedLocalModified: transaction.dateTimeModified,
      );
    } else {
      FireflySyncDirection direction = decideSyncDirection(
        localModified: transaction.dateTimeModified,
        remoteUpdatedAt: map.fireflyUpdatedAt,
        lastSyncedLocalModified: map.lastSyncedLocalModified,
        lastSyncedRemoteUpdatedAt: map.fireflyUpdatedAt,
      );
      if (direction == FireflySyncDirection.push) {
        FireflyTransactionGroup updated =
            await client.updateTransaction(map.fireflyId, group);
        await _upsertSyncMap(
          syncMapPk: map.syncMapPk,
          type: FireflySyncEntityType.transaction,
          localPk: transaction.transactionPk,
          fireflyId: map.fireflyId,
          fireflyUpdatedAt: updated.updatedAt,
          lastSyncedLocalModified: transaction.dateTimeModified,
        );
      }
    }
  }
}

Future<void> _pushDeletes(FireflyApiClient client, DateTime lastSynced) async {
  List<DeleteLog> deleteLogs = await database.getAllNewDeleteLogs(lastSynced);
  for (DeleteLog log in deleteLogs) {
    FireflySyncEntityType? type;
    if (log.type == DeleteLogType.Transaction) {
      type = FireflySyncEntityType.transaction;
    } else if (log.type == DeleteLogType.TransactionWallet) {
      if (log.entryPk == "0") continue; // default wallet is never truly deleted locally
      type = FireflySyncEntityType.wallet;
    } else if (log.type == DeleteLogType.TransactionCategory) {
      if (log.entryPk == "0") continue; // uncategorized is never truly deleted locally
      type = FireflySyncEntityType.category;
    } else {
      continue; // not a Firefly-synced entity type
    }

    FireflySyncMapEntry? map = await _syncMapByLocalPk(type, log.entryPk);
    if (map == null) continue;

    try {
      if (type == FireflySyncEntityType.transaction) {
        await client.deleteTransaction(map.fireflyId);
      } else if (type == FireflySyncEntityType.wallet) {
        await client.deleteAccount(map.fireflyId);
      } else if (type == FireflySyncEntityType.category) {
        await client.deleteCategory(map.fireflyId);
      }
    } catch (e) {
      // Best-effort: e.g. already deleted server-side (404). Still drop the
      // local map row below so we don't retry forever.
      print("Firefly push-delete error (continuing): " + e.toString());
    }
    await _deleteSyncMapRow(map.syncMapPk);
  }
}
