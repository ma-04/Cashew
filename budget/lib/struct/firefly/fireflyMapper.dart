// Pure, stateless mapping functions between Cashew's local Drift rows and
// Firefly III's REST resources. No DB/HTTP/Flutter globals are touched here
// on purpose - all foreign-key lookups (wallet/category Firefly ids <-> local
// pks) are resolved by the caller (fireflySyncEngine.dart) so this file stays
// trivially unit-testable. See test/firefly/fireflyMapperTest.dart.
//
// Phase 1 scope only covers Accounts/Transactions/Categories - see
// budget/FIREFLY_SYNC_FUTURE_SCOPE.md for what's deliberately not handled
// here (subcategories, splits, tags, budgets, non-asset accounts, etc).

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart' show uuid;
import 'package:budget/struct/firefly/fireflyModels.dart';

// Every local Wallet is pushed as this Firefly account type; only Firefly
// accounts of this type are pulled in as/kept as local Wallets.
const String kFireflyAssetAccountType = "asset";

// The local pk Cashew already treats as "no specific category" - reused
// as the category for pulled transfers, which have no Firefly category.
const String kUncategorizedCategoryPk = "0";

// ---------------------------------------------------------------------------
// Accounts <-> Wallets
// ---------------------------------------------------------------------------

FireflyAccount walletToFireflyAccount(TransactionWallet wallet) {
  return FireflyAccount(
    id: 0, // unused - ignored by FireflyApiClient's create/update request body
    name: wallet.name,
    type: kFireflyAssetAccountType,
    currencyCode: wallet.currency?.toUpperCase(),
    active: true,
  );
}

// existingWalletPk: pass the local pk when updating an already-linked wallet.
// Leave null when materializing a brand new local wallet from a pulled
// Firefly account - the DAO's insert:true path ignores this placeholder and
// generates a fresh uuid.
TransactionWallet fireflyAccountToWallet(
  FireflyAccount account, {
  required int order,
  String? existingWalletPk,
}) {
  return TransactionWallet(
    walletPk: existingWalletPk ?? "-1",
    name: account.name,
    dateCreated: account.createdAt ?? DateTime.now(),
    dateTimeModified: DateTime.now(),
    order: order,
    currency: account.currencyCode?.toLowerCase(),
    decimals: 2,
  );
}

// ---------------------------------------------------------------------------
// Categories
// ---------------------------------------------------------------------------

// Returns null for subcategories (mainCategoryPk != null) - Firefly has no
// nested categories, and phase 1 deliberately skips subcategory sync rather
// than lossily flattening names. See FIREFLY_SYNC_FUTURE_SCOPE.md.
FireflyCategory? categoryToFireflyCategory(TransactionCategory category) {
  if (category.mainCategoryPk != null) return null;
  return FireflyCategory(id: 0, name: category.name);
}

TransactionCategory fireflyCategoryToCategory(
  FireflyCategory fireflyCategory, {
  required int order,
  String? existingCategoryPk,
}) {
  return TransactionCategory(
    categoryPk: existingCategoryPk ?? "-1",
    name: fireflyCategory.name,
    dateCreated: fireflyCategory.createdAt ?? DateTime.now(),
    dateTimeModified: DateTime.now(),
    order: order,
    income: false,
  );
}

// ---------------------------------------------------------------------------
// Transactions
// ---------------------------------------------------------------------------

enum FireflyPulledSplitKind { withdrawal, deposit, transfer, skip }

// reconciliation/opening balance splits are phase-1 deferred (skip) - see
// FIREFLY_SYNC_FUTURE_SCOPE.md.
FireflyPulledSplitKind classifySplitType(String fireflyType) {
  switch (fireflyType) {
    case "withdrawal":
      return FireflyPulledSplitKind.withdrawal;
    case "deposit":
      return FireflyPulledSplitKind.deposit;
    case "transfer":
      return FireflyPulledSplitKind.transfer;
    default:
      return FireflyPulledSplitKind.skip;
  }
}

// Non-transfer local transaction -> Firefly split (withdrawal or deposit).
// Sign convention matches createOrUpdateTransaction: income == amount > 0.
FireflyTransactionSplit transactionToFireflySplit(
  Transaction transaction, {
  required int walletFireflyId,
  String? walletCurrencyCode,
  int? categoryFireflyId,
  String? categoryName,
}) {
  bool isIncome = transaction.amount > 0;
  return FireflyTransactionSplit(
    type: isIncome ? "deposit" : "withdrawal",
    date: transaction.dateCreated,
    amount: transaction.amount.abs(),
    description:
        transaction.name.trim().isEmpty ? "(no description)" : transaction.name,
    sourceId: isIncome ? null : walletFireflyId,
    destinationId: isIncome ? walletFireflyId : null,
    categoryId: categoryFireflyId,
    categoryName: categoryFireflyId == null ? categoryName : null,
    currencyCode: walletCurrencyCode?.toUpperCase(),
    notes: transaction.note.trim().isEmpty ? null : transaction.note,
  );
}

// A local transfer is two paired Transaction rows (fromTransaction has the
// negative amount, toTransaction the positive one) - collapsed into a single
// Firefly "transfer" split, matching Firefly's model of transfers.
FireflyTransactionSplit transferPairToFireflySplit({
  required Transaction fromTransaction,
  required Transaction toTransaction,
  required int fromWalletFireflyId,
  required int toWalletFireflyId,
  String? currencyCode,
}) {
  return FireflyTransactionSplit(
    type: "transfer",
    date: fromTransaction.dateCreated,
    amount: fromTransaction.amount.abs(),
    description: fromTransaction.name.trim().isNotEmpty
        ? fromTransaction.name
        : (toTransaction.name.trim().isNotEmpty
            ? toTransaction.name
            : "(no description)"),
    sourceId: fromWalletFireflyId,
    destinationId: toWalletFireflyId,
    currencyCode: currencyCode?.toUpperCase(),
    notes: fromTransaction.note.trim().isEmpty ? null : fromTransaction.note,
  );
}

// Firefly withdrawal/deposit split -> local transaction. walletPk/categoryPk
// must already be resolved by the caller via FireflySyncMap.
// existingTransactionPk null => a brand new local row (caller should insert
// with insert:true, letting the DAO generate the real pk).
Transaction fireflySplitToTransaction(
  FireflyTransactionSplit split, {
  required String walletPk,
  required String categoryPk,
  String? existingTransactionPk,
}) {
  bool isIncome = split.type == "deposit";
  double signedAmount = isIncome ? split.amount.abs() : -split.amount.abs();
  return Transaction(
    transactionPk: existingTransactionPk ?? "-1",
    name: split.description,
    amount: signedAmount,
    note: split.notes ?? "",
    categoryFk: categoryPk,
    walletFk: walletPk,
    dateCreated: split.date,
    dateTimeModified: DateTime.now(),
    income: isIncome,
    paid: true,
    skipPaid: true,
    methodAdded: MethodAdded.firefly,
  );
}

// Firefly transfer split -> a pair of linked local transactions. Both pks
// are generated up front (rather than relying on the DAO's insert-time
// uuid) so each row can reference the other via pairedTransactionFk before
// either exists in the DB. Caller should always insert these with
// insert:false, since the pks are already final.
(Transaction, Transaction) fireflySplitToTransferPair(
  FireflyTransactionSplit split, {
  required String sourceWalletPk,
  required String destWalletPk,
  String? existingSourceTransactionPk,
  String? existingDestTransactionPk,
}) {
  String sourcePk = existingSourceTransactionPk ?? uuid.v4();
  String destPk = existingDestTransactionPk ?? uuid.v4();
  DateTime now = DateTime.now();
  Transaction sourceTransaction = Transaction(
    transactionPk: sourcePk,
    pairedTransactionFk: destPk,
    name: split.description,
    amount: -split.amount.abs(),
    note: split.notes ?? "",
    categoryFk: kUncategorizedCategoryPk,
    walletFk: sourceWalletPk,
    dateCreated: split.date,
    dateTimeModified: now,
    income: false,
    paid: true,
    skipPaid: true,
    methodAdded: MethodAdded.firefly,
  );
  Transaction destTransaction = Transaction(
    transactionPk: destPk,
    pairedTransactionFk: sourcePk,
    name: split.description,
    amount: split.amount.abs(),
    note: split.notes ?? "",
    categoryFk: kUncategorizedCategoryPk,
    walletFk: destWalletPk,
    dateCreated: split.date,
    dateTimeModified: now,
    income: true,
    paid: true,
    skipPaid: true,
    methodAdded: MethodAdded.firefly,
  );
  return (sourceTransaction, destTransaction);
}

// ---------------------------------------------------------------------------
// Conflict resolution
// ---------------------------------------------------------------------------

enum FireflySyncDirection { none, push, pull }

// Last-write-wins conflict resolution, mirroring the existing Google Drive
// sync's dateTimeModified-based diffing (lib/struct/syncClient.dart).
//
// - Neither side changed since the last successful sync => none.
// - Only one side changed => that side wins outright.
// - Both changed (a real conflict) => whichever timestamp is newer wins;
//   a missing timestamp on one side loses to the side that has one.
FireflySyncDirection decideSyncDirection({
  required DateTime? localModified,
  required DateTime? remoteUpdatedAt,
  required DateTime? lastSyncedLocalModified,
  required DateTime? lastSyncedRemoteUpdatedAt,
}) {
  bool localChanged = lastSyncedLocalModified == null ||
      (localModified != null &&
          localModified.isAfter(lastSyncedLocalModified));
  bool remoteChanged = lastSyncedRemoteUpdatedAt == null ||
      (remoteUpdatedAt != null &&
          remoteUpdatedAt.isAfter(lastSyncedRemoteUpdatedAt));

  if (!localChanged && !remoteChanged) return FireflySyncDirection.none;
  if (localChanged && !remoteChanged) return FireflySyncDirection.push;
  if (!localChanged && remoteChanged) return FireflySyncDirection.pull;

  // Both changed since the last sync - resolve by most-recent timestamp.
  if (localModified == null) return FireflySyncDirection.pull;
  if (remoteUpdatedAt == null) return FireflySyncDirection.push;
  return localModified.isAfter(remoteUpdatedAt)
      ? FireflySyncDirection.push
      : FireflySyncDirection.pull;
}
