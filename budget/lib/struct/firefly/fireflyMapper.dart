// Functions that map local Drift rows to and from Firefly III resources.
// They keep no state and touch no database, no network and no global. The
// caller (fireflySyncEngine.dart) resolves each foreign key.

import 'package:drift/drift.dart' show Value;
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart' show uuid;
import 'package:budget/struct/firefly/fireflyModels.dart';

const String kFireflyAssetAccountType = "asset";
const String kFireflyExpenseAccountType = "expense";
const String kFireflyRevenueAccountType = "revenue";
const String kFireflyCashAccountType = "cash";

// The balance-correction category. onlyShowIfNotBalanceCorrection() in
// tables.dart counts a row in this category in the net total and the net
// worth, but keeps it out of the income and expense reports. That is correct
// for a balance anchor and for the two legs of a transfer.
const String kBalanceCorrectionCategoryPk = "0";

// Firefly permits a transaction with no category, but the local database does
// not. Such a transaction goes into this local category and not into the
// balance-correction category, because it is real spending and must stay in
// the budgets and the reports. The sync engine does not push this category.
const String kFireflyUncategorizedCategoryPk = "firefly-uncategorized";

FireflyAccount walletToFireflyAccount(
  TransactionWallet wallet, {
  // The role that the remote account has. Firefly needs account_role in each
  // write to an asset account. If the update does not send the current role,
  // Firefly changes a savings account or a credit card into a plain account.
  String? existingAccountRole,
  // Whether the remote account is active. The local database has no such
  // flag. An update that sends active: true switches on an account that the
  // user deactivated on Firefly. A new account is active.
  bool existingActive = true,
}) {
  return FireflyAccount(
    id: 0,
    name: wallet.name,
    type: kFireflyAssetAccountType,
    currencyCode: wallet.currency?.toUpperCase(),
    accountRole: existingAccountRole ?? "defaultAsset",
    active: existingActive,
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
  int? transactionJournalId,
}) {
  bool isIncome = transaction.amount > 0;
  String fallbackName =
      transaction.name.trim().isEmpty ? "(no description)" : transaction.name;
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
    transactionJournalId: transactionJournalId,
  );
}

FireflyTransactionSplit transferPairToFireflySplit({
  required Transaction fromTransaction,
  required Transaction toTransaction,
  required int fromWalletFireflyId,
  required int toWalletFireflyId,
  // The currencies of the two wallets. The split is in the currency of the
  // source wallet. If the destination wallet has another currency, the split
  // also carries the amount of the destination row as the foreign amount, or
  // Firefly counts the source amount on the destination account.
  String? fromCurrency,
  String? toCurrency,
  // A transfer is one Firefly split, but two local rows. The user can change
  // either row. The caller selects the text of the row that changed last and
  // sends it here. If it does not, the changes to the destination row do not
  // go to Firefly.
  String? descriptionOverride,
  String? notesOverride,
  int? transactionJournalId,
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
  String? from = fromCurrency?.trim().toUpperCase();
  String? to = toCurrency?.trim().toUpperCase();
  bool crossCurrency = from != null && to != null && from != to;
  return FireflyTransactionSplit(
    type: "transfer",
    date: fromTransaction.dateCreated,
    amount: fromTransaction.amount.abs(),
    description: description,
    sourceId: fromWalletFireflyId,
    destinationId: toWalletFireflyId,
    currencyCode: from == null || from.isEmpty ? null : from,
    foreignAmount: crossCurrency ? toTransaction.amount.abs() : null,
    foreignCurrencyCode: crossCurrency ? to : null,
    notes: notes.trim().isEmpty ? null : notes,
    transactionJournalId: transactionJournalId,
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

// Writes the fields that Firefly owns onto the local row.
//
// createOrUpdateTransaction uses InsertMode.insertOrReplace. SQLite REPLACE
// deletes the old row and writes a new one, thus each column that the
// companion does not set gets its default value. A new Transaction object
// would therefore erase each local-only field (the subcategory, the objective,
// the budget exclusions and the loan links) at each pull. A copy of the
// current row keeps these fields.
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

// The local database holds only a recent part of the Firefly history. The sum
// of the local rows of a wallet is therefore too small by the amount of the
// history that the app did not pull. Each synced wallet gets one anchor row
// that holds this amount:
//
//     anchor = firefly_current_balance - sum(the other local rows)
//
// The anchor is a local row only. The push side finds it by its primary key
// and does not send it to Firefly. The key comes from the wallet key, thus
// each sync writes the same row again.

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
  // The currency of the destination wallet. When the split carries a foreign
  // amount in that currency, the destination row gets it. Without this the
  // destination row holds the source amount, which is in another currency.
  String? destCurrency,
  String? existingSourceTransactionPk,
  String? existingDestTransactionPk,
}) {
  String sourcePk = existingSourceTransactionPk ?? uuid.v4();
  String destPk = existingDestTransactionPk ?? uuid.v4();
  DateTime now = DateTime.now();
  double destAmount = transferDestinationAmount(split, destCurrency);
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
    amount: destAmount,
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

// The amount that the destination row of a transfer holds: the foreign
// amount when the split has one in the currency of the destination wallet,
// else the amount of the split.
double transferDestinationAmount(
    FireflyTransactionSplit split, String? destCurrency) {
  String? foreign = split.foreignCurrencyCode?.trim().toUpperCase();
  String? dest = destCurrency?.trim().toUpperCase();
  if (split.foreignAmount != null &&
      foreign != null &&
      foreign.isNotEmpty &&
      dest != null &&
      foreign == dest) {
    return split.foreignAmount!.abs();
  }
  return split.amount.abs();
}

enum FireflySyncDirection { none, push, pull }

// True if the local row changed after the last push or pull of that row. The
// push side tests this first: if the row did not change, the cycle does not
// read the remote record.
bool fireflyLocalRowChanged({
  required DateTime? localModified,
  required DateTime? lastSyncedLocalModified,
}) {
  return lastSyncedLocalModified == null ||
      (localModified != null && localModified.isAfter(lastSyncedLocalModified));
}

FireflySyncDirection decideSyncDirection({
  required DateTime? localModified,
  required DateTime? remoteUpdatedAt,
  required DateTime? lastSyncedLocalModified,
  required DateTime? lastSyncedRemoteUpdatedAt,
}) {
  bool localChanged = lastSyncedLocalModified == null ||
      (localModified != null && localModified.isAfter(lastSyncedLocalModified));
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

// Each local row that belongs to a Firefly group holds the same group id.
// Firefly gives each split a transaction_journal_id that stays the same when a
// sibling split is deleted, but the position of the split in the group does
// not. These functions match on the journal id. They match on the position
// only for a row that the app wrote before it stored the journal id. The
// caller then writes the journal id into that row.
bool _matchesSplit(
    FireflySyncMapEntry map, int? splitJournalId, int splitIndex) {
  if (splitJournalId != null && map.fireflyJournalId != null) {
    return map.fireflyJournalId == splitJournalId;
  }
  return map.fireflyJournalId == null && map.fireflySplitIndex == splitIndex;
}

// The number of remote splits that the map rows of one group point at. A
// transfer is two local rows on one split, thus a count of the rows is too
// large. A row that has a journal id counts one time for that id, a row that
// has none counts one time for its position.
int fireflySplitSlotCount(List<FireflySyncMapEntry> groupMaps) {
  Set<int> journalIds = {};
  Set<int> positions = {};
  for (FireflySyncMapEntry map in groupMaps) {
    if (map.fireflyJournalId != null) {
      journalIds.add(map.fireflyJournalId!);
    } else {
      positions.add(map.fireflySplitIndex);
    }
  }
  return journalIds.length + positions.length;
}

// True if a map row that has no journal id can be matched to a split by its
// position.
//
// Only a row that the app wrote before it stored journal ids has no id. The
// first pull that reads such a group gives each row its id, thus this test
// applies one time for each group.
//
// Firefly moves the splits of a group when it deletes one of them, thus a
// stored position is correct only while the group has the same shape as when
// the app wrote the row. Three tests together give that:
//
//  1. The number of splits agrees with the number of slots that the rows hold.
//  2. The group still holds each split that a row names by id, and that split
//     is at the position that the row holds. A move or a delete thus shows.
//  3. A row that has no id points at a split that no other row names by id.
//
// A group that Firefly reshaped and kept at the same length, and that moved no
// split that a row names, passes these tests. Such a group needs a change of
// two splits between two syncs of one install that came from a build before
// the journal-id column. The caller cannot see this from the group alone.
bool fireflyPositionMatchIsSafe({
  required List<FireflySyncMapEntry> groupMaps,
  required List<FireflyTransactionSplit> splits,
}) {
  if (fireflySplitSlotCount(groupMaps) != splits.length) return false;

  Set<int> mappedJournalIds = {
    for (FireflySyncMapEntry map in groupMaps)
      if (map.fireflyJournalId != null) map.fireflyJournalId!
  };
  for (FireflySyncMapEntry map in groupMaps) {
    int position = map.fireflySplitIndex;
    if (position < 0 || position >= splits.length) return false;
    int? journalIdAtPosition = splits[position].transactionJournalId;
    if (map.fireflyJournalId != null) {
      if (journalIdAtPosition != map.fireflyJournalId) return false;
    } else {
      if (journalIdAtPosition != null &&
          mappedJournalIds.contains(journalIdAtPosition)) {
        return false;
      }
    }
  }
  return true;
}

FireflySyncMapEntry? matchSplitToSyncMap({
  required List<FireflySyncMapEntry> groupMaps,
  required int? splitJournalId,
  required int splitIndex,
  bool matchByPosition = true,
}) {
  List<FireflySyncMapEntry> matches = matchSplitToSyncMaps(
    groupMaps: groupMaps,
    splitJournalId: splitJournalId,
    splitIndex: splitIndex,
    matchByPosition: matchByPosition,
  );
  return matches.isEmpty ? null : matches.first;
}

// A transfer is two local rows that share one remote split, thus this function
// can return two rows. If one row holds the journal id of this split, the
// function ignores the rows that have no journal id.
List<FireflySyncMapEntry> matchSplitToSyncMaps({
  required List<FireflySyncMapEntry> groupMaps,
  required int? splitJournalId,
  required int splitIndex,
  bool matchByPosition = true,
}) {
  if (splitJournalId != null) {
    List<FireflySyncMapEntry> byJournalId =
        groupMaps.where((m) => m.fireflyJournalId == splitJournalId).toList();
    if (byJournalId.isNotEmpty) return byJournalId;
  }
  if (!matchByPosition) return [];
  return groupMaps
      .where((m) => _matchesSplit(m, splitJournalId, splitIndex))
      .toList();
}
