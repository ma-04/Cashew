// The rules that the second review of this branch turned on. Each test here
// stands for one way in which a cycle used to lose data or stop:
//
//   - a PUT that names only the changed split deletes every other split of
//     its Firefly group;
//   - the answer to a create can be lost after Firefly stored the record,
//     and the next cycle then imported it a second time;
//   - a wallet in one currency linked to a Firefly account in another gets
//     its amounts booked in the account's currency, because Firefly reads
//     the currency of the account and not the currency_code of the request;
//   - one record that the app cannot read ended the whole cycle;
//   - a second page of records was never asked for.
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/firefly/fireflySyncEngine.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'firefly_test_env.dart';

void main() {
  late FireflyTestEnv env;
  // Whole seconds: the sync map keeps a date as unix seconds, thus a stamp
  // with milliseconds comes back smaller than the one the fake reports and
  // every record looks changed on the server.
  final DateTime old = DateTime.fromMillisecondsSinceEpoch(
          (DateTime.now().millisecondsSinceEpoch ~/ 1000) * 1000)
      .subtract(const Duration(days: 3));

  setUp(() async {
    env = await FireflyTestEnv.create(
        lastSyncedAt: DateTime.now().subtract(const Duration(days: 1)));
  });

  tearDown(() => env.dispose());

  // A mapped wallet and a mapped category, the usual state after a link.
  Future<(TransactionWallet, TransactionCategory)> linkedWalletAndCategory({
    String walletName = 'Cash',
    String balance = '100',
    String remoteCurrency = 'USD',
    String? localCurrency,
  }) async {
    env.firefly.addAccount(5, walletName,
        balance: balance,
        currencyCode: remoteCurrency,
        updatedAt: old.toUtc().toIso8601String());
    env.firefly.addCategory(6, 'Food');
    TransactionWallet wallet = await env.insertWallet(walletName,
        modified: old, currency: localCurrency);
    TransactionCategory category =
        await env.insertCategory('Food', modified: old);
    await env.mapRow(FireflySyncEntityType.wallet, wallet.walletPk, 5,
        lastSyncedLocalModified: old, fireflyUpdatedAt: old);
    await env.mapRow(FireflySyncEntityType.category, category.categoryPk, 6,
        lastSyncedLocalModified: old, fireflyUpdatedAt: old);
    return (wallet, category);
  }

  List<dynamic> splitsOfGroup(int id) =>
      env.firefly.transactionGroups[id]!['attributes']['transactions']
          as List<dynamic>;

  group('a split transaction', () {
    // A Firefly PUT rewrites the whole group: every split that the request
    // does not name is deleted. A request that carried the changed split
    // alone thus destroyed the other splits of the group.
    test('a change to one of its records keeps the other records', () async {
      var (wallet, category) = await linkedWalletAndCategory();
      DateTime date = DateTime.now().subtract(const Duration(days: 2));
      Map<String, dynamic> group = env.firefly.addTransaction(300, 301,
          description: 'Groceries',
          amount: '10.00',
          sourceId: 5,
          destinationId: 800,
          date: date,
          categoryId: '6',
          updatedAt: old.toUtc().toIso8601String());
      for (var (int journalId, String description, String amount) in [
        (302, 'Snacks', '5.00'),
        (303, 'Drinks', '2.50'),
      ]) {
        (group['attributes']['transactions'] as List<dynamic>).add({
          'transaction_journal_id': journalId,
          'type': 'withdrawal',
          'date': date.toUtc().toIso8601String(),
          'amount': amount,
          'description': description,
          'source_id': 5,
          'destination_id': 800,
          'currency_code': 'USD',
          'category_id': '6',
        });
      }

      // Two of the three splits have a local row. The third one is a record
      // that this app never imported, and it must survive the push all the
      // same.
      Transaction first = await env.insertTransaction(
          name: 'Groceries',
          amount: -10,
          wallet: wallet,
          category: category,
          date: date,
          modified: old);
      Transaction second = await env.insertTransaction(
          name: 'Snacks',
          amount: -5,
          wallet: wallet,
          category: category,
          date: date,
          modified: old);
      await env.mapRow(
          FireflySyncEntityType.transaction, first.transactionPk, 300,
          lastSyncedLocalModified: old,
          fireflyUpdatedAt: old,
          journalId: 301,
          splitIndex: 0);
      await env.mapRow(
          FireflySyncEntityType.transaction, second.transactionPk, 300,
          lastSyncedLocalModified: old,
          fireflyUpdatedAt: old,
          journalId: 302,
          splitIndex: 1);

      await database.createOrUpdateTransaction(
          first.copyWith(
              name: 'Groceries and bread',
              dateTimeModified: Value(DateTime.now())),
          updateSharedEntry: false);

      bool ok = await fireflySyncNow(pushOnly: true);
      expect(ok, isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');
      expect(env.firefly.requestsTo('PUT', '/api/v1/transactions/300'),
          hasLength(1));

      List<dynamic> splits = splitsOfGroup(300);
      expect(splits, hasLength(3),
          reason: 'the push deleted the splits it did not change');
      expect(
          splits
              .map((s) => int.parse(s['transaction_journal_id'].toString()))
              .toList(),
          [301, 302, 303],
          reason: 'a split lost its journal id and became a new record');
      expect(splits[0]['description'], 'Groceries and bread');
      expect(splits[1]['description'], 'Snacks');
      expect(splits[2]['description'], 'Drinks');
      expect(splits[2]['amount'], '2.50');
    });
  });

  group('a create whose answer was lost', () {
    // Firefly stored the record and the app never saw the id. The record
    // carries the local key as its external id, thus the next pull finds it
    // and links it instead of importing a second copy.
    test('is linked on the next cycle, not imported again', () async {
      var (wallet, category) = await linkedWalletAndCategory();
      Transaction coffee = await env.insertTransaction(
          name: 'Coffee', amount: -4.5, wallet: wallet, category: category);

      env.firefly.intercept = (FakeRequest r) {
        if (r.method != 'POST' || r.path != '/api/v1/transactions') return null;
        // The server writes the record and the answer never arrives.
        Map<String, dynamic> split =
            Map<String, dynamic>.from(r.body!['transactions'][0]);
        env.firefly.addTransaction(700, 701,
            description: split['description'].toString(),
            amount: split['amount'].toString(),
            sourceId: 5,
            destinationId: 800,
            date: DateTime.parse(split['date'].toString()),
            categoryId: '6',
            externalId: split['external_id']?.toString());
        return FakeResponse(500, {'message': 'the answer was lost'});
      };

      expect(await fireflySyncNow(), isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');
      expect(fireflySyncReportNotifier.value!.failedTransactions, 1);
      expect(
          await env.mapFor(
              FireflySyncEntityType.transaction, coffee.transactionPk),
          isNull,
          reason: 'the app cannot know the id that it never received');

      env.firefly.intercept = null;
      expect(await fireflySyncNow(), isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');

      FireflySyncReport report = fireflySyncReportNotifier.value!;
      expect(report.recoveredCreates, 1);
      expect(env.firefly.transactionGroups, hasLength(1),
          reason: 'the lost create was written a second time');
      expect(
          env.firefly.requestsTo('POST', '/api/v1/transactions'), hasLength(1),
          reason: 'a second create went out');
      expect(
          (await env.mapFor(
                  FireflySyncEntityType.transaction, coffee.transactionPk))
              ?.fireflyId,
          700);
      // One local row, plus the balance anchor of the wallet.
      List<Transaction> local = await (database.select(database.transactions)
            ..where((t) => t.name.equals('Coffee')))
          .get();
      expect(local, hasLength(1));
    });
  });

  group('a wallet in another currency', () {
    // Firefly reads the currency of the asset account first
    // (TransactionJournalFactory::getCurrency). A push of 1,200 BDT into a
    // USD account therefore books 1,200 USD, and no field of the request can
    // stop it. The only safe answer is to hold the row back and say so.
    test('holds the push back and warns once', () async {
      var (wallet, category) = await linkedWalletAndCategory(
          remoteCurrency: 'USD', localCurrency: 'bdt');
      await env.insertTransaction(
          name: 'Lunch', amount: -1200, wallet: wallet, category: category);
      await env.insertTransaction(
          name: 'Tea', amount: -50, wallet: wallet, category: category);

      expect(await fireflySyncNow(), isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');

      FireflySyncReport report = fireflySyncReportNotifier.value!;
      expect(env.firefly.requestsTo('POST', '/api/v1/transactions'), isEmpty);
      expect(report.skippedCurrencyMismatch, 2);
      expect(
          report.warnings.where((w) => w.contains('currency')).toList().length,
          1,
          reason: 'one warning per account, not per row');
      // The rows still wait, thus the user sees them as unsynced.
      FireflyUnsyncedCounts counts = await fireflyCountUnsyncedChanges();
      expect(counts.transactions, 2);
    });

    test('lets the push through when the two agree', () async {
      var (wallet, category) = await linkedWalletAndCategory(
          remoteCurrency: 'BDT', localCurrency: 'bdt');
      await env.insertTransaction(
          name: 'Lunch', amount: -1200, wallet: wallet, category: category);

      expect(await fireflySyncNow(), isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');
      expect(fireflySyncReportNotifier.value!.skippedCurrencyMismatch, 0);
      expect(
          env.firefly.requestsTo('POST', '/api/v1/transactions'), hasLength(1));
    });
  });

  group('a record that the app cannot read', () {
    test('is left alone and the cycle goes on', () async {
      await linkedWalletAndCategory();
      env.firefly.addTransaction(300, 301,
          description: 'Groceries',
          amount: 'not a number',
          sourceId: 5,
          destinationId: 800,
          categoryId: '6');
      env.firefly.addTransaction(310, 311,
          description: 'Bread',
          amount: '3.00',
          sourceId: 5,
          destinationId: 800,
          categoryId: '6');

      expect(await fireflySyncNow(), isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');

      FireflySyncReport report = fireflySyncReportNotifier.value!;
      List<Transaction> local =
          await database.select(database.transactions).get();
      expect(local.where((t) => t.name == 'Bread').toList(), hasLength(1),
          reason: 'the record that reads fine was not imported');
      expect(local.where((t) => t.name == 'Groceries'), isEmpty);
      expect(report.warnings.join('\n'), contains('was not read'));
      // The unreadable record is not a delete: it keeps no local row and it
      // takes none away.
      expect(env.firefly.requestsTo('DELETE', '/api/v1/transactions/300'),
          isEmpty);
    });
  });

  group('more records than one page holds', () {
    test('every page is read', () async {
      env.firefly.addAccount(5, 'Cash', balance: '0');
      for (int i = 0; i < 60; i++) {
        env.firefly.addCategory(100 + i, 'Category $i');
      }

      expect(await fireflySyncNow(), isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');

      expect(env.firefly.requestsTo('GET', '/api/v1/categories'), hasLength(2),
          reason: 'the second page was never asked for');
      List<TransactionCategory> categories =
          await database.select(database.categories).get();
      expect(categories.where((c) => c.name.startsWith('Category ')).toList(),
          hasLength(60));
    });
  });

  group('a delete', () {
    test('a record removed on Firefly is removed here', () async {
      var (wallet, category) = await linkedWalletAndCategory();
      Transaction coffee = await env.insertTransaction(
          name: 'Coffee',
          amount: -4.5,
          wallet: wallet,
          category: category,
          modified: old);
      // The link points at a group that Firefly no longer holds.
      await env.mapRow(
          FireflySyncEntityType.transaction, coffee.transactionPk, 300,
          lastSyncedLocalModified: old, fireflyUpdatedAt: old, journalId: 301);

      expect(await fireflySyncNow(), isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');

      FireflySyncReport report = fireflySyncReportNotifier.value!;
      expect(report.deletedLocal, 1);
      expect(
          await database.tryGetTransactionFromPk(coffee.transactionPk), isNull);
      expect(
          await env.mapFor(
              FireflySyncEntityType.transaction, coffee.transactionPk),
          isNull,
          reason: 'the link stays open after the row went');
    });

    test('a record of a split group takes only its own split', () async {
      var (wallet, category) = await linkedWalletAndCategory();
      DateTime date = DateTime.now().subtract(const Duration(days: 2));
      Map<String, dynamic> group = env.firefly.addTransaction(300, 301,
          description: 'Groceries',
          amount: '10.00',
          sourceId: 5,
          destinationId: 800,
          date: date,
          categoryId: '6',
          updatedAt: old.toUtc().toIso8601String());
      (group['attributes']['transactions'] as List<dynamic>).add({
        'transaction_journal_id': 302,
        'type': 'withdrawal',
        'date': date.toUtc().toIso8601String(),
        'amount': '5.00',
        'description': 'Snacks',
        'source_id': 5,
        'destination_id': 800,
        'currency_code': 'USD',
        'category_id': '6',
      });
      Transaction first = await env.insertTransaction(
          name: 'Groceries',
          amount: -10,
          wallet: wallet,
          category: category,
          date: date,
          modified: old);
      Transaction second = await env.insertTransaction(
          name: 'Snacks',
          amount: -5,
          wallet: wallet,
          category: category,
          date: date,
          modified: old);
      await env.mapRow(
          FireflySyncEntityType.transaction, first.transactionPk, 300,
          lastSyncedLocalModified: old,
          fireflyUpdatedAt: old,
          journalId: 301,
          splitIndex: 0);
      await env.mapRow(
          FireflySyncEntityType.transaction, second.transactionPk, 300,
          lastSyncedLocalModified: old,
          fireflyUpdatedAt: old,
          journalId: 302,
          splitIndex: 1);

      await database.deleteTransaction(second.transactionPk,
          updateSharedEntry: false);

      expect(await fireflySyncNow(pushOnly: true), isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');

      expect(fireflySyncReportNotifier.value!.deletedRemote, 1);
      expect(
          env.firefly.requestsTo('DELETE', '/api/v1/transaction-journals/302'),
          hasLength(1));
      expect(
          env.firefly.requestsTo('DELETE', '/api/v1/transactions/300'), isEmpty,
          reason: 'the whole group went for one record');
      expect(splitsOfGroup(300), hasLength(1));
      expect(splitsOfGroup(300).single['description'], 'Groceries');
    });
  });

  group('an update of a record that Firefly no longer holds', () {
    test('closes the link and keeps the local record', () async {
      var (wallet, category) = await linkedWalletAndCategory();
      Transaction coffee = await env.insertTransaction(
          name: 'Coffee',
          amount: -4.5,
          wallet: wallet,
          category: category,
          modified: old);
      await env.mapRow(
          FireflySyncEntityType.transaction, coffee.transactionPk, 300,
          lastSyncedLocalModified: old, fireflyUpdatedAt: old, journalId: 301);
      await database.createOrUpdateTransaction(
          coffee.copyWith(
              name: 'Coffee and cake', dateTimeModified: Value(DateTime.now())),
          updateSharedEntry: false);

      expect(await fireflySyncNow(pushOnly: true), isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');

      expect(await database.tryGetTransactionFromPk(coffee.transactionPk),
          isNotNull,
          reason: 'a push must never delete a local record');
      expect(
          await env.mapFor(
              FireflySyncEntityType.transaction, coffee.transactionPk),
          isNull,
          reason: 'the link to the record that went must be closed');
    });
  });
}
