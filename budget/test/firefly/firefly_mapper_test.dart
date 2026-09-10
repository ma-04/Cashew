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

FireflySyncMapEntry _syncMap({
  required String localPk,
  required int splitIndex,
  int? journalId,
  int fireflyId = 42,
  bool isTombstone = false,
}) {
  return FireflySyncMapEntry(
    syncMapPk: "map-$localPk",
    entityType: FireflySyncEntityType.transaction,
    localPk: localPk,
    fireflyId: fireflyId,
    isTombstone: isTombstone,
    fireflySplitIndex: splitIndex,
    fireflyJournalId: journalId,
    dateCreated: DateTime(2024, 1, 1),
  );
}

List<FireflyTransactionSplit> _splits(List<int?> journalIds) {
  return [
    for (int? journalId in journalIds)
      FireflyTransactionSplit(
        type: "withdrawal",
        date: DateTime(2024, 3, 15),
        amount: -10,
        description: "Split",
        transactionJournalId: journalId,
      )
  ];
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

    test('fireflyAccountToWallet generates a pk when none given', () {
      FireflyAccount account = FireflyAccount(
        id: 42,
        name: "Savings",
        type: kFireflyAssetAccountType,
      );
      TransactionWallet wallet = fireflyAccountToWallet(account, order: 0);
      expect(wallet.walletPk, isNotEmpty);
      expect(wallet.walletPk, isNot("-1"));
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
      expect(
          classifySplitType("withdrawal"), FireflyPulledSplitKind.withdrawal);
      expect(classifySplitType("deposit"), FireflyPulledSplitKind.deposit);
      expect(classifySplitType("transfer"), FireflyPulledSplitKind.transfer);
    });

    test('maps opening-balance and reconciliation, skips unknown', () {
      expect(classifySplitType("opening balance"),
          FireflyPulledSplitKind.openingBalance);
      expect(classifySplitType("opening-balance"),
          FireflyPulledSplitKind.openingBalance);
      expect(classifySplitType("reconciliation"),
          FireflyPulledSplitKind.reconciliation);
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
        isIncome: false,
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
        isIncome: true,
      );
      expect(rebuiltIncome.amount, 200.0);
      expect(rebuiltIncome.income, isTrue);
    });
  });

  group('transfer pairing', () {
    test('transferPairToFireflySplit sets source/destination from the pair',
        () {
      Transaction from =
          _transaction(transactionPk: "from-1", amount: -100.0, income: false);
      Transaction to =
          _transaction(transactionPk: "to-1", amount: 100.0, income: true);
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

    test('description/notes overrides let the destination leg win', () {
      Transaction from = _transaction(
          transactionPk: "from-1",
          amount: -100.0,
          income: false,
          name: "old name",
          note: "old note");
      Transaction to = _transaction(
          transactionPk: "to-1",
          amount: 100.0,
          income: true,
          name: "edited name",
          note: "edited note");
      FireflyTransactionSplit split = transferPairToFireflySplit(
        fromTransaction: from,
        toTransaction: to,
        fromWalletFireflyId: 1,
        toWalletFireflyId: 2,
        descriptionOverride: to.name,
        notesOverride: to.note,
      );
      expect(split.description, "edited name");
      expect(split.notes, "edited note");
    });

    test('blank overrides fall back to the source leg', () {
      Transaction from = _transaction(
          transactionPk: "from-1",
          amount: -100.0,
          income: false,
          name: "source name",
          note: "source note");
      Transaction to = _transaction(
          transactionPk: "to-1",
          amount: 100.0,
          income: true,
          name: "",
          note: "");
      FireflyTransactionSplit split = transferPairToFireflySplit(
        fromTransaction: from,
        toTransaction: to,
        fromWalletFireflyId: 1,
        toWalletFireflyId: 2,
        descriptionOverride: to.name,
        notesOverride: to.note,
      );
      expect(split.description, "source name");
      expect(split.notes, "source note");
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

  group('account active flag', () {
    test('a new account is active', () {
      TransactionWallet wallet = _wallet(name: "Cash");
      expect(walletToFireflyAccount(wallet).active, isTrue);
    });

    test('an update keeps a deactivated Firefly account deactivated', () {
      TransactionWallet wallet = _wallet(name: "Cash");
      expect(
          walletToFireflyAccount(wallet, existingActive: false).active, isFalse);
    });
  });

  group('account role', () {
    test('a new account gets the default role', () {
      expect(walletToFireflyAccount(_wallet()).accountRole, "defaultAsset");
    });

    test('an update carries the role the remote account already has', () {
      expect(
        walletToFireflyAccount(_wallet(), existingAccountRole: "savingAsset")
            .accountRole,
        "savingAsset",
      );
    });
  });

  group('balance anchors', () {
    test('anchor pks are recognisable and wallet-specific', () {
      String pk = fireflyBalanceAnchorPk("wallet-1");
      expect(isFireflyBalanceAnchorPk(pk), isTrue);
      expect(isFireflyBalanceAnchorPk("wallet-1"), isFalse);
      expect(pk == fireflyBalanceAnchorPk("wallet-2"), isFalse);
    });

    test('an anchor lands in the balance-correction category', () {
      Transaction anchor = buildFireflyBalanceAnchor(
        walletPk: "wallet-1",
        amount: -420.5,
        date: DateTime(2024, 1, 1),
        name: "Firefly balance",
      );
      // Category "0" is what keeps the anchor inside net totals and net worth
      // while keeping it out of income/expense breakdowns.
      expect(anchor.categoryFk, kBalanceCorrectionCategoryPk);
      expect(anchor.walletFk, "wallet-1");
      expect(anchor.amount, -420.5);
      expect(anchor.income, isFalse);
      expect(anchor.paid, isTrue);
    });

    test('a positive anchor is marked as income', () {
      expect(
        buildFireflyBalanceAnchor(
          walletPk: "wallet-1",
          amount: 1200.0,
          date: DateTime(2024, 1, 1),
          name: "Firefly balance",
        ).income,
        isTrue,
      );
    });
  });

  group('counterparty helpers', () {
    test('assetFireflyIdForSplit prefers a synced source, then dest', () {
      FireflyTransactionSplit split = FireflyTransactionSplit(
        type: "withdrawal",
        date: DateTime(2024, 3, 15),
        amount: 10,
        description: "Coffee",
        sourceId: 7,
        destinationId: 99,
      );
      expect(assetFireflyIdForSplit(split, {7, 8}), 7);
      expect(assetFireflyIdForSplit(split, {99}), 99);
      expect(assetFireflyIdForSplit(split, {1}), isNull);
    });

    test('resolvePushCounterparty uses stored id, then name, then category',
        () {
      FireflyAccount aldi = FireflyAccount(
        id: 10,
        name: "Aldi",
        type: kFireflyExpenseAccountType,
      );
      FireflyAccount groceries = FireflyAccount(
        id: 11,
        name: "Groceries",
        type: kFireflyExpenseAccountType,
      );
      expect(
        resolvePushCounterparty(
          isIncome: false,
          transactionName: "Coffee",
          categoryName: "Groceries",
          storedCounterpartyId: 10,
          counterpartiesById: {10: aldi, 11: groceries},
          expenseByName: {"aldi": aldi, "groceries": groceries},
          revenueByName: {},
        )?.id,
        10,
      );
      expect(
        resolvePushCounterparty(
          isIncome: false,
          transactionName: "Aldi",
          categoryName: "Groceries",
          storedCounterpartyId: null,
          counterpartiesById: {10: aldi, 11: groceries},
          expenseByName: {"aldi": aldi, "groceries": groceries},
          revenueByName: {},
        )?.id,
        10,
      );
      expect(
        resolvePushCounterparty(
          isIncome: false,
          transactionName: "Unknown shop",
          categoryName: "Groceries",
          storedCounterpartyId: null,
          counterpartiesById: {10: aldi, 11: groceries},
          expenseByName: {"aldi": aldi, "groceries": groceries},
          revenueByName: {},
        )?.id,
        11,
      );
    });

    test(
        'transactionToFireflySplit sends destination_name when no counterparty id',
        () {
      Transaction expense = _transaction(amount: -50.0, name: "Coffee");
      FireflyTransactionSplit split = transactionToFireflySplit(
        expense,
        walletFireflyId: 7,
        counterpartyName: "Coffee",
      );
      expect(split.sourceId, 7);
      expect(split.destinationId, isNull);
      expect(split.destinationName, "Coffee");
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

  // Regression cover for splits being matched by their array position. A
  // Firefly journal renumbers its splits when one is deleted from the middle,
  // so a stored position silently starts pointing at a neighbour. See
  // matchSplitToSyncMap in fireflyMapper.dart.
  group("matchSplitToSyncMap", () {
    // Group 42 held three splits: 0=Groceries(LA), 1=Fuel(LB), 2=Rent(LC).
    // Fuel is deleted in the Firefly web UI, so Firefly now returns two
    // splits reindexed as 0=Groceries, 1=Rent.
    List<FireflySyncMapEntry> threeMapped() => [
          _syncMap(localPk: "LA", splitIndex: 0, journalId: 1001),
          _syncMap(localPk: "LB", splitIndex: 1, journalId: 1002),
          _syncMap(localPk: "LC", splitIndex: 2, journalId: 1003),
        ];

    test("a middle split deleted remotely does not shift rows onto neighbours",
        () {
      List<FireflySyncMapEntry> maps = threeMapped();

      // Position 0 - Groceries, journal 1001. Unambiguous either way.
      expect(
        matchSplitToSyncMap(
                groupMaps: maps, splitJournalId: 1001, splitIndex: 0)
            ?.localPk,
        "LA",
      );
      // Position 1 is now Rent (journal 1003). Matching by position would
      // return LB, which is Fuel - the row that would get overwritten.
      expect(
        matchSplitToSyncMap(
                groupMaps: maps, splitJournalId: 1003, splitIndex: 1)
            ?.localPk,
        "LC",
      );
      // And LC is not left orphaned to be re-imported as a duplicate.
      expect(
        matchSplitToSyncMap(
                groupMaps: maps, splitJournalId: 1003, splitIndex: 1)
            ?.localPk,
        isNot("LB"),
      );
    });

    test("a journal id with no mapped row matches nothing", () {
      expect(
        matchSplitToSyncMap(
            groupMaps: threeMapped(), splitJournalId: 9999, splitIndex: 0),
        isNull,
      );
    });

    test("rows written before the column existed still match by position", () {
      List<FireflySyncMapEntry> maps = [
        _syncMap(localPk: "LA", splitIndex: 0),
        _syncMap(localPk: "LB", splitIndex: 1),
      ];
      expect(
        matchSplitToSyncMap(
                groupMaps: maps, splitJournalId: 1002, splitIndex: 1)
            ?.localPk,
        "LB",
      );
    });

    test("a split with no journal id at all falls back to position", () {
      List<FireflySyncMapEntry> maps = [
        _syncMap(localPk: "LA", splitIndex: 0),
        _syncMap(localPk: "LB", splitIndex: 1),
      ];
      expect(
        matchSplitToSyncMap(
                groupMaps: maps, splitJournalId: null, splitIndex: 1)
            ?.localPk,
        "LB",
      );
    });

    test("a backfilled row is never matched by position again", () {
      // LA carries journal 1001. A split at position 0 belonging to a
      // different journal must not claim it - that is the corruption.
      List<FireflySyncMapEntry> maps = [
        _syncMap(localPk: "LA", splitIndex: 0, journalId: 1001),
      ];
      expect(
        matchSplitToSyncMap(
            groupMaps: maps, splitJournalId: 2002, splitIndex: 0),
        isNull,
      );
    });

    test("mixed group: identified rows match by id, the rest by position", () {
      List<FireflySyncMapEntry> maps = [
        _syncMap(localPk: "LA", splitIndex: 0, journalId: 1001),
        _syncMap(localPk: "LB", splitIndex: 1),
      ];
      expect(
        matchSplitToSyncMap(
                groupMaps: maps, splitJournalId: 1001, splitIndex: 0)
            ?.localPk,
        "LA",
      );
      expect(
        matchSplitToSyncMap(
                groupMaps: maps, splitJournalId: 1002, splitIndex: 1)
            ?.localPk,
        "LB",
      );
    });
  });

  group("matchSplitToSyncMaps", () {
    test("both legs of a transfer share one split and both come back", () {
      List<FireflySyncMapEntry> maps = [
        _syncMap(localPk: "from", splitIndex: 0, journalId: 1001),
        _syncMap(localPk: "to", splitIndex: 0, journalId: 1001),
      ];
      List<FireflySyncMapEntry> matched = matchSplitToSyncMaps(
          groupMaps: maps, splitJournalId: 1001, splitIndex: 0);
      expect(matched.map((m) => m.localPk).toList(), ["from", "to"]);
    });

    test("an un-backfilled transfer pair still matches by position", () {
      List<FireflySyncMapEntry> maps = [
        _syncMap(localPk: "from", splitIndex: 0),
        _syncMap(localPk: "to", splitIndex: 0),
      ];
      expect(
        matchSplitToSyncMaps(
                groupMaps: maps, splitJournalId: 1001, splitIndex: 0)
            .length,
        2,
      );
    });

    test("a journal-id match excludes rows still awaiting backfill", () {
      // Otherwise an identified split would drag an unrelated, un-backfilled
      // row at the same position in with it.
      List<FireflySyncMapEntry> maps = [
        _syncMap(localPk: "identified", splitIndex: 0, journalId: 1001),
        _syncMap(localPk: "stale", splitIndex: 0),
      ];
      expect(
        matchSplitToSyncMaps(
                groupMaps: maps, splitJournalId: 1001, splitIndex: 0)
            .map((m) => m.localPk)
            .toList(),
        ["identified"],
      );
    });
  });

  group("FireflyTransactionSplit.transactionJournalId", () {
    test("is parsed from the API payload", () {
      FireflyTransactionSplit split = FireflyTransactionSplit.fromJson({
        "type": "withdrawal",
        "date": "2024-03-01T00:00:00+00:00",
        "amount": "40.00",
        "description": "Groceries",
        "transaction_journal_id": "1001",
      });
      expect(split.transactionJournalId, 1001);
    });

    test("is null when the payload omits it", () {
      FireflyTransactionSplit split = FireflyTransactionSplit.fromJson({
        "type": "withdrawal",
        "date": "2024-03-01T00:00:00+00:00",
        "amount": "40.00",
        "description": "Groceries",
      });
      expect(split.transactionJournalId, isNull);
    });

    test("goes back to Firefly on a write", () {
      // Firefly deletes a split that a PUT does not name, and it makes a new
      // split from a changed split that has no id.
      FireflyTransactionSplit split = FireflyTransactionSplit(
        type: "withdrawal",
        date: DateTime(2024, 3, 1),
        amount: 40,
        description: "Groceries",
        transactionJournalId: 1001,
      );
      expect(split.toRequestJson()["transaction_journal_id"], 1001);
    });

    test("is absent from a write when the split has no id", () {
      FireflyTransactionSplit split = FireflyTransactionSplit(
        type: "withdrawal",
        date: DateTime(2024, 3, 1),
        amount: 40,
        description: "Groceries",
      );
      expect(
          split.toRequestJson().containsKey("transaction_journal_id"), isFalse);
    });

    test("transactionToFireflySplit carries the id that the caller gives", () {
      FireflyTransactionSplit split = transactionToFireflySplit(
        _transaction(amount: -50.0, income: false),
        walletFireflyId: 7,
        transactionJournalId: 1001,
      );
      expect(split.transactionJournalId, 1001);
      expect(split.toRequestJson()["transaction_journal_id"], 1001);
    });
  });

  group("FireflyTransactionSplit.unchangedSplit", () {
    test("writes the id and nothing more", () {
      // A split that keeps its content needs the id only. More fields make
      // Firefly change the split.
      Map<String, dynamic> json =
          FireflyTransactionSplit.unchangedSplit(1001).toRequestJson();
      expect(json, {"transaction_journal_id": 1001});
    });
  });

  group("fireflyLocalRowChanged", () {
    test("a row with no last sync time counts as changed", () {
      expect(
        fireflyLocalRowChanged(
          localModified: DateTime(2024, 3, 1),
          lastSyncedLocalModified: null,
        ),
        isTrue,
      );
    });

    test("a row that changed after the last push counts as changed", () {
      expect(
        fireflyLocalRowChanged(
          localModified: DateTime(2024, 3, 2),
          lastSyncedLocalModified: DateTime(2024, 3, 1),
        ),
        isTrue,
      );
    });

    test("a row that did not change since the last push counts as unchanged",
        () {
      expect(
        fireflyLocalRowChanged(
          localModified: DateTime(2024, 3, 1),
          lastSyncedLocalModified: DateTime(2024, 3, 1),
        ),
        isFalse,
      );
    });

    test("a row with no modification time counts as unchanged", () {
      expect(
        fireflyLocalRowChanged(
          localModified: null,
          lastSyncedLocalModified: DateTime(2024, 3, 1),
        ),
        isFalse,
      );
    });
  });

  group('fireflyPositionMatchIsSafe', () {
    test('one row for each split is safe', () {
      expect(
        fireflyPositionMatchIsSafe(
          groupMaps: [
            _syncMap(localPk: "a", splitIndex: 0),
            _syncMap(localPk: "b", splitIndex: 1),
          ],
          splits: _splits([900, 901]),
        ),
        isTrue,
      );
    });

    test('a group that lost a split remotely is not safe', () {
      expect(
        fireflyPositionMatchIsSafe(
          groupMaps: [
            _syncMap(localPk: "a", splitIndex: 0),
            _syncMap(localPk: "b", splitIndex: 1),
            _syncMap(localPk: "c", splitIndex: 2),
          ],
          splits: _splits([900, 901]),
        ),
        isFalse,
      );
    });

    test('the two rows of a transfer count as one split', () {
      expect(
        fireflyPositionMatchIsSafe(
          groupMaps: [
            _syncMap(localPk: "from", splitIndex: 0, journalId: 900),
            _syncMap(localPk: "to", splitIndex: 0, journalId: 900),
          ],
          splits: _splits([900]),
        ),
        isTrue,
      );
    });

    test('a row with an id and a row without count as two splits', () {
      expect(
        fireflyPositionMatchIsSafe(
          groupMaps: [
            _syncMap(localPk: "a", splitIndex: 0, journalId: 900),
            _syncMap(localPk: "b", splitIndex: 1),
          ],
          splits: _splits([900, 901]),
        ),
        isTrue,
      );
    });

    test('a split that a row names by id and that the group lost is not safe',
        () {
      expect(
        fireflyPositionMatchIsSafe(
          groupMaps: [
            _syncMap(localPk: "a", splitIndex: 0, journalId: 900),
            _syncMap(localPk: "b", splitIndex: 1),
          ],
          splits: _splits([902, 901]),
        ),
        isFalse,
      );
    });

    test('a split that a row names by id and that moved is not safe', () {
      expect(
        fireflyPositionMatchIsSafe(
          groupMaps: [
            _syncMap(localPk: "a", splitIndex: 0, journalId: 900),
            _syncMap(localPk: "b", splitIndex: 1),
          ],
          splits: _splits([901, 900]),
        ),
        isFalse,
      );
    });

    test('a row with no id that points at a split of another row is not safe',
        () {
      expect(
        fireflyPositionMatchIsSafe(
          groupMaps: [
            _syncMap(localPk: "a", splitIndex: 1, journalId: 901),
            _syncMap(localPk: "b", splitIndex: 1),
          ],
          splits: _splits([900, 901]),
        ),
        isFalse,
      );
    });

    test('a position that the group does not hold is not safe', () {
      expect(
        fireflyPositionMatchIsSafe(
          groupMaps: [
            _syncMap(localPk: "a", splitIndex: 0),
            _syncMap(localPk: "b", splitIndex: 5),
          ],
          splits: _splits([900, 901]),
        ),
        isFalse,
      );
    });
  });

  group('matchSplitToSyncMaps with matchByPosition false', () {
    test('a row that only the position matches is not returned', () {
      List<FireflySyncMapEntry> groupMaps = [
        _syncMap(localPk: "a", splitIndex: 0),
      ];
      expect(
        matchSplitToSyncMaps(
          groupMaps: groupMaps,
          splitJournalId: 900,
          splitIndex: 0,
          matchByPosition: false,
        ),
        isEmpty,
      );
      expect(
        matchSplitToSyncMaps(
          groupMaps: groupMaps,
          splitJournalId: 900,
          splitIndex: 0,
        ),
        hasLength(1),
      );
    });

    test('a row that the id matches is still returned', () {
      expect(
        matchSplitToSyncMaps(
          groupMaps: [
            _syncMap(localPk: "a", splitIndex: 7, journalId: 900),
          ],
          splitJournalId: 900,
          splitIndex: 0,
          matchByPosition: false,
        ),
        hasLength(1),
      );
    });
  });
}
