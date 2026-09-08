// Pure, stateless mapping functions between Cashew's local Drift rows and
// Firefly III's REST resources. No DB/HTTP/Flutter globals are touched here
// on purpose - all foreign-key lookups (wallet/category Firefly ids <-> local
// pks) are resolved by the caller (fireflySyncEngine.dart) so this file stays
// trivially unit-testable. See test/firefly/firefly_mapper_test.dart.
//
// Phase 1 covers Accounts/Transactions/Categories. Subcategories are not
// flattened (see skipped-subcategory reporting in the sync engine).

import 'package:drift/drift.dart' show Value;
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart' show uuid;
import 'package:budget/struct/firefly/fireflyModels.dart';

const String kFireflyAssetAccountType = "asset";
const String kFireflyExpenseAccountType = "expense";
const String kFireflyRevenueAccountType = "revenue";
const String kFireflyCashAccountType = "cash";

// Cashew's reserved balance-correction category, created lazily by
// initializeBalanceCorrectionCategory(). Rows in it are counted in net totals
// and net worth but kept out of income/expense breakdowns and spending graphs
// - which is exactly right for balance anchors and for both legs of a
// transfer, and exactly wrong for ordinary spending.
const String kBalanceCorrectionCategoryPk = "0";

// Firefly lets a transaction have no category at all; Cashew requires one.
// Those rows go into a dedicated local bucket rather than into the
// balance-correction category, so that real spending Firefly happens not to
// have categorised still shows up in budgets, breakdowns and graphs. It is
// never pushed to Firefly - see _pushCategories and _fireflyPushCategoryOf.
const String kFireflyUncategorizedCategoryPk = "firefly-uncategorized";

// ---------------------------------------------------------------------------
// Accounts <-> Wallets
// ---------------------------------------------------------------------------

FireflyAccount walletToFireflyAccount(
  TransactionWallet wallet, {
  // The role the remote account already has, when we are updating one. Firefly
  // requires account_role on every asset-account write, so omitting it on an
  // update would silently reset a savings/credit-card account to a plain one.
  String? existingAccountRole,
}) {
  return FireflyAccount(
    id: 0,
    name: wallet.name,
    type: kFireflyAssetAccountType,
    currencyCode: wallet.currency?.toUpperCase(),
    accountRole: existingAccountRole ?? "defaultAsset",
    active: true,
  );
}

TransactionWallet fireflyAccountToWallet(
  FireflyAccount account, {
  required int order,
  String? existingWalletPk,
}) {
  return TransactionWallet(
    walletPk: existingWalletPk ?? uuid.v4(),
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
    categoryPk: existingCategoryPk ?? uuid.v4(),
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

enum FireflyPulledSplitKind {
  withdrawal,
  deposit,
  transfer,
  openingBalance,
  reconciliation,
  skip,
}

FireflyPulledSplitKind classifySplitType(String fireflyType) {
  switch (fireflyType) {
    case "withdrawal":
      return FireflyPulledSplitKind.withdrawal;
    case "deposit":
      return FireflyPulledSplitKind.deposit;
    case "transfer":
      return FireflyPulledSplitKind.transfer;
    case "opening-balance":
    case "opening balance":
      return FireflyPulledSplitKind.openingBalance;
    case "reconciliation":
      return FireflyPulledSplitKind.reconciliation;
    default:
      return FireflyPulledSplitKind.skip;
  }
}

bool splitKindIsBalanceCorrection(FireflyPulledSplitKind kind) {
  return kind == FireflyPulledSplitKind.openingBalance ||
      kind == FireflyPulledSplitKind.reconciliation;
}

// The asset-account side of a split, if either end is a synced wallet.
int? assetFireflyIdForSplit(
  FireflyTransactionSplit split,
  Set<int> assetFireflyIds,
) {
  if (split.sourceId != null && assetFireflyIds.contains(split.sourceId)) {
    return split.sourceId;
  }
  if (split.destinationId != null &&
      assetFireflyIds.contains(split.destinationId)) {
    return split.destinationId;
  }
  return null;
}

// The non-wallet Firefly account on the other side of the asset (payee).
int? counterpartyFireflyIdForSplit(
  FireflyTransactionSplit split,
  int walletFireflyId,
) {
  if (split.sourceId == walletFireflyId) return split.destinationId;
  if (split.destinationId == walletFireflyId) return split.sourceId;
  return null;
}

String? counterpartyNameForSplit(
  FireflyTransactionSplit split,
  int walletFireflyId,
) {
  if (split.sourceId == walletFireflyId) return split.destinationName;
  if (split.destinationId == walletFireflyId) return split.sourceName;
  return split.destinationName ?? split.sourceName;
}

// Money into the asset account is income.
bool splitIsIncomeForAsset(
  FireflyTransactionSplit split,
  int walletFireflyId,
) {
  return split.destinationId == walletFireflyId;
}

FireflyAccount? resolvePushCounterparty({
  required bool isIncome,
  required String transactionName,
  required String? categoryName,
  required int? storedCounterpartyId,
  required Map<int, FireflyAccount> counterpartiesById,
  required Map<String, FireflyAccount> expenseByName,
  required Map<String, FireflyAccount> revenueByName,
}) {
  if (storedCounterpartyId != null &&
      counterpartiesById.containsKey(storedCounterpartyId)) {
    return counterpartiesById[storedCounterpartyId];
  }
  Map<String, FireflyAccount> byName = isIncome ? revenueByName : expenseByName;
  String nameKey = transactionName.trim().toLowerCase();
  if (nameKey.isNotEmpty && byName.containsKey(nameKey)) {
    return byName[nameKey];
  }
  String categoryKey = (categoryName ?? "").trim().toLowerCase();
  if (categoryKey.isNotEmpty && byName.containsKey(categoryKey)) {
    return byName[categoryKey];
  }
  return null;
}

FireflyTransactionSplit transactionToFireflySplit(
  Transaction transaction, {
  required int walletFireflyId,
  String? walletCurrencyCode,
  int? categoryFireflyId,
  String? categoryName,
  int? counterpartyFireflyId,
  String? counterpartyName,
}) {
  bool isIncome = transaction.amount > 0;
  String fallbackName = transaction.name.trim().isEmpty
      ? "(no description)"
      : transaction.name;
  return FireflyTransactionSplit(
    type: isIncome ? "deposit" : "withdrawal",
    date: transaction.dateCreated,
    amount: transaction.amount.abs(),
    description: fallbackName,
    sourceId: isIncome ? counterpartyFireflyId : walletFireflyId,
    sourceName: isIncome && counterpartyFireflyId == null
        ? (counterpartyName ?? fallbackName)
        : null,
    destinationId: isIncome ? walletFireflyId : counterpartyFireflyId,
    destinationName: !isIncome && counterpartyFireflyId == null
        ? (counterpartyName ?? fallbackName)
        : null,
    categoryId: categoryFireflyId,
    categoryName: categoryFireflyId == null ? categoryName : null,
    currencyCode: walletCurrencyCode?.toUpperCase(),
    notes: transaction.note.trim().isEmpty ? null : transaction.note,
  );
}

FireflyTransactionSplit transferPairToFireflySplit({
  required Transaction fromTransaction,
  required Transaction toTransaction,
  required int fromWalletFireflyId,
  required int toWalletFireflyId,
  String? currencyCode,
  // A transfer is one Firefly split but two local rows, and the user may have
  // edited either of them. The caller decides which side's text wins (the more
  // recently modified one) and passes it here; without this the destination
  // side's edits would never reach Firefly.
  String? descriptionOverride,
  String? notesOverride,
}) {
  String description = (descriptionOverride ?? "").trim().isNotEmpty
      ? descriptionOverride!
      : (fromTransaction.name.trim().isNotEmpty
          ? fromTransaction.name
          : (toTransaction.name.trim().isNotEmpty
              ? toTransaction.name
              : "(no description)"));
  String notes = (notesOverride ?? "").trim().isNotEmpty
      ? notesOverride!
      : fromTransaction.note;
  return FireflyTransactionSplit(
    type: "transfer",
    date: fromTransaction.dateCreated,
    amount: fromTransaction.amount.abs(),
    description: description,
    sourceId: fromWalletFireflyId,
    destinationId: toWalletFireflyId,
    currencyCode: currencyCode?.toUpperCase(),
    notes: notes.trim().isEmpty ? null : notes,
  );
}

Transaction fireflySplitToTransaction(
  FireflyTransactionSplit split, {
  required String walletPk,
  required String categoryPk,
  required bool isIncome,
  String? existingTransactionPk,
}) {
  double signedAmount = isIncome ? split.amount.abs() : -split.amount.abs();
  return Transaction(
    transactionPk: existingTransactionPk ?? uuid.v4(),
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

// Applies the fields Firefly owns onto an existing local row.
//
// createOrUpdateTransaction persists with InsertMode.insertOrReplace, and
// SQLite REPLACE deletes the old row before re-inserting it - so any column
// missing from the companion comes back as its default rather than its former
// value. Rebuilding a fresh Transaction here would therefore silently drop
// every Cashew-only field (subcategory, objective, budget exclusions, loan
// links, notes the user attached locally...) each time a remote edit is
// pulled. Copying onto the row we already have keeps them.
Transaction fireflyApplySplitToExisting(
  Transaction local,
  FireflyTransactionSplit split, {
  required String walletPk,
  required String categoryPk,
  required bool isIncome,
}) {
  double signedAmount = isIncome ? split.amount.abs() : -split.amount.abs();
  return local.copyWith(
    name: split.description,
    amount: signedAmount,
    note: split.notes ?? "",
    categoryFk: categoryPk,
    walletFk: walletPk,
    dateCreated: split.date,
    dateTimeModified: Value(DateTime.now()),
    income: isIncome,
    paid: true,
  );
}

// ---------------------------------------------------------------------------
// Balance anchor
// ---------------------------------------------------------------------------
//
// Only a recent window of Firefly's history is kept locally, so summing the
// local rows for a wallet would report a balance that is wrong by exactly the
// history that was never pulled. To fix that without holding the full ledger,
// each synced wallet gets one synthetic "anchor" row carrying everything that
// happened before the window:
//
//     anchor = firefly_current_balance - sum(other local rows for the wallet)
//
// It is stored with categoryFk "0", Cashew's balance-correction category,
// which is exactly the right vehicle: onlyShowIfNotBalanceCorrection() in
// tables.dart includes category-"0" rows in net totals (isIncome == null) and
// excludes them from income/expense breakdowns. So wallet balances and net
// worth come out right with no change to any existing query, while spending
// graphs and budgets are unaffected by it.
//
// The pk is derived from the wallet pk rather than random so the row can be
// recomputed idempotently on every sync, and so the push side can recognise
// and skip it - an anchor must never be sent to Firefly, it is a local
// artefact of not storing the whole ledger.

const String kFireflyBalanceAnchorPkPrefix = "firefly-balance-anchor-";

String fireflyBalanceAnchorPk(String walletPk) =>
    kFireflyBalanceAnchorPkPrefix + walletPk;

bool isFireflyBalanceAnchorPk(String transactionPk) =>
    transactionPk.startsWith(kFireflyBalanceAnchorPkPrefix);

Transaction buildFireflyBalanceAnchor({
  required String walletPk,
  required double amount,
  required DateTime date,
  required String name,
}) {
  return Transaction(
    transactionPk: fireflyBalanceAnchorPk(walletPk),
    name: name,
    amount: amount,
    note: "",
    categoryFk: kBalanceCorrectionCategoryPk,
    walletFk: walletPk,
    dateCreated: date,
    dateTimeModified: DateTime.now(),
    income: amount > 0,
    paid: true,
    skipPaid: true,
    methodAdded: MethodAdded.firefly,
  );
}

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
    categoryFk: kBalanceCorrectionCategoryPk,
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
    categoryFk: kBalanceCorrectionCategoryPk,
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

  if (localModified == null) return FireflySyncDirection.pull;
  if (remoteUpdatedAt == null) return FireflySyncDirection.push;
  return localModified.isAfter(remoteUpdatedAt)
      ? FireflySyncDirection.push
      : FireflySyncDirection.pull;
}

// ---------------------------------------------------------------------------
// Split identity
// ---------------------------------------------------------------------------
//
// A Firefly journal group can hold several splits, and every local row mapped
// to that group stores the same group id. What distinguishes one split from
// another used to be fireflySplitIndex - the split's array position - which is
// not a stable identity: deleting a split from the middle of a journal on the
// Firefly side renumbers everything after it, so a stored index starts
// pointing at its neighbour. One local row then gets overwritten from the
// wrong split and the last one is re-imported as a duplicate, silently
// skewing the account balance.
//
// Firefly gives each split a transaction_journal_id that survives its siblings
// being deleted. These helpers match on that, and fall back to the position
// only for rows written before the id was stored - which the caller then
// backfills, so any given row takes the fallback path at most once.

// Only rows with no journal id may be matched by position. A row that already
// carries a *different* journal id belongs to a different split, and matching
// it by position is exactly the corruption being fixed here.
bool _matchesSplit(
    FireflySyncMapEntry map, int? splitJournalId, int splitIndex) {
  if (splitJournalId != null && map.fireflyJournalId != null) {
    return map.fireflyJournalId == splitJournalId;
  }
  return map.fireflyJournalId == null && map.fireflySplitIndex == splitIndex;
}

// The sync-map row for one split, or null if this split is not mapped yet.
FireflySyncMapEntry? matchSplitToSyncMap({
  required List<FireflySyncMapEntry> groupMaps,
  required int? splitJournalId,
  required int splitIndex,
}) {
  List<FireflySyncMapEntry> matches = matchSplitToSyncMaps(
    groupMaps: groupMaps,
    splitJournalId: splitJournalId,
    splitIndex: splitIndex,
  );
  return matches.isEmpty ? null : matches.first;
}

// Every sync-map row belonging to one split. A transfer is two local rows
// sharing a single remote split, so this can legitimately return two.
//
// Journal-id matches win outright: if any row carries this split's journal id,
// rows still awaiting backfill are not considered, because a position match
// against an already-identified split is what caused the mis-pairing.
List<FireflySyncMapEntry> matchSplitToSyncMaps({
  required List<FireflySyncMapEntry> groupMaps,
  required int? splitJournalId,
  required int splitIndex,
}) {
  if (splitJournalId != null) {
    List<FireflySyncMapEntry> byJournalId = groupMaps
        .where((m) => m.fireflyJournalId == splitJournalId)
        .toList();
    if (byJournalId.isNotEmpty) return byJournalId;
  }
  return groupMaps
      .where((m) => _matchesSplit(m, splitJournalId, splitIndex))
      .toList();
}
