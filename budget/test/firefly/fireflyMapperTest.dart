import 'package:budget/database/tables.dart';
import 'package:budget/struct/firefly/fireflyMapper.dart';
import 'package:budget/struct/firefly/fireflyModels.dart';
import 'package:flutter_test/flutter_test.dart';

TransactionWallet _wallet({
  String walletPk = "wallet-1",
  String name = "Checking",
  String? currency = "usd",
}) {
  return TransactionWallet(
    walletPk: walletPk,
    name: name,
    dateCreated: DateTime(2024, 1, 1),
    dateTimeModified: DateTime(2024, 1, 1),
    order: 0,
    currency: currency,
    decimals: 2,
  );
}

TransactionCategory _category({
  String categoryPk = "category-1",
  String name = "Groceries",
  String? mainCategoryPk,
}) {
  return TransactionCategory(
    categoryPk: categoryPk,
    name: name,
    dateCreated: DateTime(2024, 1, 1),
    dateTimeModified: DateTime(2024, 1, 1),
    order: 0,
    income: false,
    mainCategoryPk: mainCategoryPk,
  );
}

Transaction _transaction({
  String transactionPk = "txn-1",
  double amount = -50.0,
  bool income = false,
  String walletFk = "wallet-1",
  String categoryFk = "category-1",
  String? pairedTransactionFk,
  String name = "Coffee",
  String note = "",
}) {
  return Transaction(
    transactionPk: transactionPk,
    name: name,
    amount: amount,
    note: note,
    categoryFk: categoryFk,
    walletFk: walletFk,
    dateCreated: DateTime(2024, 3, 15),
    dateTimeModified: DateTime(2024, 3, 15),
    income: income,
    paid: true,
    skipPaid: true,
    methodAdded: MethodAdded.firefly,
    pairedTransactionFk: pairedTransactionFk,
  );
}

void main() {
  group('walletToFireflyAccount / fireflyAccountToWallet', () {
    test('round-trips name and currency', () {
      TransactionWallet wallet = _wallet(name: "Checking", currency: "usd");
      FireflyAccount account = walletToFireflyAccount(wallet);
      expect(account.name, "Checking");
      expect(account.type, kFireflyAssetAccountType);
      expect(account.currencyCode, "USD");

      TransactionWallet roundTripped = fireflyAccountToWallet(
        account,
        order: 5,
        existingWalletPk: "wallet-1",
      );
      expect(roundTripped.walletPk, "wallet-1");
      expect(roundTripped.name, "Checking");
      expect(roundTripped.currency, "usd");
      expect(roundTripped.order, 5);
    });

    test('fireflyAccountToWallet uses placeholder pk when none given', () {
      FireflyAccount account = FireflyAccount(
        id: 42,
        name: "Savings",
        type: kFireflyAssetAccountType,
      );
      TransactionWallet wallet = fireflyAccountToWallet(account, order: 0);
      expect(wallet.walletPk, "-1");
    });
  });

  group('categoryToFireflyCategory / fireflyCategoryToCategory', () {
    test('round-trips a main category', () {
      TransactionCategory category = _category(name: "Groceries");
      FireflyCategory? remote = categoryToFireflyCategory(category);
      expect(remote, isNotNull);
      expect(remote!.name, "Groceries");

      TransactionCategory roundTripped = fireflyCategoryToCategory(
        remote,
        order: 1,
        existingCategoryPk: "category-1",
      );
      expect(roundTripped.categoryPk, "category-1");
      expect(roundTripped.name, "Groceries");
    });

    test('returns null for a subcategory', () {
      TransactionCategory sub =
          _category(categoryPk: "sub-1", mainCategoryPk: "category-1");
      expect(categoryToFireflyCategory(sub), isNull);
    });
  });

  group('classifySplitType', () {
    test('maps known Firefly types', () {
      expect(classifySplitType("withdrawal"), FireflyPulledSplitKind.withdrawal);
      expect(classifySplitType("deposit"), FireflyPulledSplitKind.deposit);
      expect(classifySplitType("transfer"), FireflyPulledSplitKind.transfer);
    });

    test('skips opening-balance and reconciliation types', () {
      expect(classifySplitType("opening balance"), FireflyPulledSplitKind.skip);
      expect(classifySplitType("reconciliation"), FireflyPulledSplitKind.skip);
      expect(classifySplitType("unknown"), FireflyPulledSplitKind.skip);
    });
  });

  group('transactionToFireflySplit / fireflySplitToTransaction', () {
    test('an expense becomes a withdrawal with source set', () {
      Transaction expense = _transaction(amount: -50.0, income: false);
      FireflyTransactionSplit split = transactionToFireflySplit(
        expense,
        walletFireflyId: 7,
      );
      expect(split.type, "withdrawal");
      expect(split.amount, 50.0);
      expect(split.sourceId, 7);
      expect(split.destinationId, isNull);
    });

    test('income becomes a deposit with destination set', () {
      Transaction income = _transaction(amount: 200.0, income: true);
      FireflyTransactionSplit split = transactionToFireflySplit(
        income,
        walletFireflyId: 7,
      );
      expect(split.type, "deposit");
      expect(split.amount, 200.0);
      expect(split.destinationId, 7);
      expect(split.sourceId, isNull);
    });

    test('fireflySplitToTransaction reconstructs signed amount', () {
      FireflyTransactionSplit withdrawalSplit = FireflyTransactionSplit(
        type: "withdrawal",
        date: DateTime(2024, 3, 15),
        amount: 50.0,
        description: "Coffee",
      );
      Transaction rebuilt = fireflySplitToTransaction(
        withdrawalSplit,
        walletPk: "wallet-1",
        categoryPk: "category-1",
      );
      expect(rebuilt.amount, -50.0);
      expect(rebuilt.income, isFalse);

      FireflyTransactionSplit depositSplit = FireflyTransactionSplit(
        type: "deposit",
        date: DateTime(2024, 3, 15),
        amount: 200.0,
        description: "Paycheck",
      );
      Transaction rebuiltIncome = fireflySplitToTransaction(
        depositSplit,
        walletPk: "wallet-1",
        categoryPk: "category-1",
      );
      expect(rebuiltIncome.amount, 200.0);
      expect(rebuiltIncome.income, isTrue);
    });
  });

  group('transfer pairing', () {
    test('transferPairToFireflySplit sets source/destination from the pair', () {
      Transaction from = _transaction(
          transactionPk: "from-1", amount: -100.0, income: false);
      Transaction to = _transaction(
          transactionPk: "to-1", amount: 100.0, income: true);
      FireflyTransactionSplit split = transferPairToFireflySplit(
        fromTransaction: from,
        toTransaction: to,
        fromWalletFireflyId: 1,
        toWalletFireflyId: 2,
      );
      expect(split.type, "transfer");
      expect(split.amount, 100.0);
      expect(split.sourceId, 1);
      expect(split.destinationId, 2);
    });

    test('fireflySplitToTransferPair produces two linked transactions', () {
      FireflyTransactionSplit split = FireflyTransactionSplit(
        type: "transfer",
        date: DateTime(2024, 3, 15),
        amount: 75.0,
        description: "Move to savings",
      );
      (Transaction, Transaction) pair = fireflySplitToTransferPair(
        split,
        sourceWalletPk: "wallet-source",
        destWalletPk: "wallet-dest",
      );
      Transaction source = pair.$1;
      Transaction dest = pair.$2;

      expect(source.amount, -75.0);
      expect(source.income, isFalse);
      expect(source.walletFk, "wallet-source");
      expect(dest.amount, 75.0);
      expect(dest.income, isTrue);
      expect(dest.walletFk, "wallet-dest");

      expect(source.pairedTransactionFk, dest.transactionPk);
      expect(dest.pairedTransactionFk, source.transactionPk);
      expect(source.transactionPk, isNot(equals(dest.transactionPk)));
    });
  });

  group('decideSyncDirection', () {
    DateTime t1 = DateTime(2024, 1, 1);
    DateTime t2 = DateTime(2024, 1, 2);
    DateTime t3 = DateTime(2024, 1, 3);

    test('neither side changed since last sync -> none', () {
      expect(
        decideSyncDirection(
          localModified: t1,
          remoteUpdatedAt: t1,
          lastSyncedLocalModified: t1,
          lastSyncedRemoteUpdatedAt: t1,
        ),
        FireflySyncDirection.none,
      );
    });

    test('only local changed -> push', () {
      expect(
        decideSyncDirection(
          localModified: t2,
          remoteUpdatedAt: t1,
          lastSyncedLocalModified: t1,
          lastSyncedRemoteUpdatedAt: t1,
        ),
        FireflySyncDirection.push,
      );
    });

    test('only remote changed -> pull', () {
      expect(
        decideSyncDirection(
          localModified: t1,
          remoteUpdatedAt: t2,
          lastSyncedLocalModified: t1,
          lastSyncedRemoteUpdatedAt: t1,
        ),
        FireflySyncDirection.pull,
      );
    });

    test('both changed -> most recent timestamp wins (local newer)', () {
      expect(
        decideSyncDirection(
          localModified: t3,
          remoteUpdatedAt: t2,
          lastSyncedLocalModified: t1,
          lastSyncedRemoteUpdatedAt: t1,
        ),
        FireflySyncDirection.push,
      );
    });

    test('both changed -> most recent timestamp wins (remote newer)', () {
      expect(
        decideSyncDirection(
          localModified: t2,
          remoteUpdatedAt: t3,
          lastSyncedLocalModified: t1,
          lastSyncedRemoteUpdatedAt: t1,
        ),
        FireflySyncDirection.pull,
      );
    });
  });
}
