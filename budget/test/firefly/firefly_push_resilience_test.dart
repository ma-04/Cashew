// The push must survive a row that Firefly refuses. Before these tests one
// HTTP 422 ("This account name is already in use.") from one wallet stopped
// the whole cycle: no transaction was pushed, the balance anchors were not
// refreshed, and the watermark did not move, thus each later cycle failed
// on the same wallet.
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/firefly/fireflyMapper.dart';
import 'package:budget/struct/firefly/fireflySettings.dart';
import 'package:budget/struct/firefly/fireflySyncEngine.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'firefly_test_env.dart';

void main() {
  late FireflyTestEnv env;
  final DateTime old = DateTime.now().subtract(const Duration(days: 3));

  setUp(() async {
    env = await FireflyTestEnv.create(
        lastSyncedAt: DateTime.now().subtract(const Duration(days: 1)));
  });

  tearDown(() => env.dispose());

  // A mapped wallet and a mapped category, the usual state after a link.
  Future<(TransactionWallet, TransactionCategory)> linkedWalletAndCategory(
      {String walletName = 'Cash', String balance = '100'}) async {
    env.firefly.addAccount(5, walletName, balance: balance);
    env.firefly.addCategory(6, 'Food');
    TransactionWallet wallet =
        await env.insertWallet(walletName, modified: old);
    TransactionCategory category =
        await env.insertCategory('Food', modified: old);
    await env.mapRow(FireflySyncEntityType.wallet, wallet.walletPk, 5,
        lastSyncedLocalModified: old);
    await env.mapRow(FireflySyncEntityType.category, category.categoryPk, 6,
        lastSyncedLocalModified: old);
    return (wallet, category);
  }

  group('name collision', () {
    test('a second wallet with a taken name does not stop the cycle', () async {
      var (wallet, category) = await linkedWalletAndCategory();
      // The user's own second wallet with the same name. Firefly allows one
      // asset account per name.
      TransactionWallet duplicate =
          await env.insertWallet('Cash', modified: DateTime.now());
      Transaction coffee = await env.insertTransaction(
          name: 'Coffee', amount: -4.5, wallet: wallet, category: category);

      bool ok = await fireflySyncNow();
      expect(ok, isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');
      expect(fireflySyncStatusNotifier.value, FireflySyncStatus.idle);

      FireflySyncReport report = fireflySyncReportNotifier.value!;
      expect(env.firefly.requestsTo('POST', '/api/v1/accounts'), hasLength(1),
          reason: 'the create was attempted once');
      expect(report.failedWallets, 1);
      expect(report.warnings.join('\n'), contains('Two accounts'));
      expect(await env.mapFor(FireflySyncEntityType.wallet, duplicate.walletPk),
          isNull,
          reason: 'the duplicate must not take over the link');
      expect(await env.mapFor(FireflySyncEntityType.wallet, wallet.walletPk),
          isNotNull);

      // The transaction after the failed wallet was pushed all the same.
      List<FakeRequest> posts =
          env.firefly.requestsTo('POST', '/api/v1/transactions');
      expect(posts, hasLength(1), reason: 'transactions were not pushed');
      expect(posts.single.body!['transactions'][0]['description'], 'Coffee');
      expect(
          await env.mapFor(
              FireflySyncEntityType.transaction, coffee.transactionPk),
          isNotNull);
      expect(report.pushedTransactions, 1);
    });

    test('a wallet whose name Firefly holds is linked, not created', () async {
      // An account the user deactivated on Firefly. The routine pull links
      // by name too; a push-only cycle has no pull, and the create fails.
      env.firefly.addAccount(9, 'Old savings', balance: '40', active: false);
      TransactionWallet wallet =
          await env.insertWallet('Old savings', modified: DateTime.now());

      bool ok = await fireflySyncNow(pushOnly: true);
      expect(ok, isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');

      FireflySyncReport report = fireflySyncReportNotifier.value!;
      FireflySyncMapEntry? map =
          await env.mapFor(FireflySyncEntityType.wallet, wallet.walletPk);
      expect(map, isNotNull, reason: 'the wallet was not linked');
      expect(map!.fireflyId, 9);
      expect(report.failedWallets, 0);
      expect(report.warnings.join('\n'), contains('linked'));
      expect(env.firefly.requestsTo('PUT', '/api/v1/accounts/9'), isEmpty,
          reason: 'a link must not write to the account');
      expect(env.firefly.accounts[9]!['attributes']['active'], isFalse);
    });

    test('an update keeps a deactivated Firefly account deactivated', () async {
      String updatedAt = "2026-01-01T00:00:00Z";
      env.firefly.addAccount(9, 'Old savings',
          balance: '40', active: false, updatedAt: updatedAt);
      TransactionWallet wallet =
          await env.insertWallet('Old savings', modified: old);
      await env.mapRow(FireflySyncEntityType.wallet, wallet.walletPk, 9,
          lastSyncedLocalModified: old,
          fireflyUpdatedAt: DateTime.parse(updatedAt));

      // A local edit: the wallet gets a new modification time.
      await (database.update(database.wallets)
            ..where((w) => w.walletPk.equals(wallet.walletPk)))
          .write(WalletsCompanion(
              colour: const Value("ff0000"),
              dateTimeModified: Value(DateTime.now())));

      bool ok = await fireflySyncNow(pushOnly: true);
      expect(ok, isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');

      List<FakeRequest> puts =
          env.firefly.requestsTo('PUT', '/api/v1/accounts/9');
      expect(puts, hasLength(1), reason: 'the edit was not pushed');
      expect(puts.single.body!['active'], isFalse,
          reason: 'the push re-enabled the account');
      expect(env.firefly.accounts[9]!['attributes']['active'], isFalse);
    });
  });

  group('per-row failure', () {
    test('one refused transaction does not stop the others', () async {
      var (wallet, category) = await linkedWalletAndCategory();
      Transaction alpha = await env.insertTransaction(
          name: 'Alpha', amount: -1, wallet: wallet, category: category);
      Transaction beta = await env.insertTransaction(
          name: 'Beta', amount: -2, wallet: wallet, category: category);

      bool failAlpha = true;
      env.firefly.intercept = (FakeRequest r) {
        if (failAlpha &&
            r.method == 'POST' &&
            r.path == '/api/v1/transactions' &&
            r.body!['transactions'][0]['description'] == 'Alpha') {
          return FakeResponse(500, {"message": "boom"});
        }
        return null;
      };

      bool ok = await fireflySyncNow();
      expect(ok, isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');
      FireflySyncReport report = fireflySyncReportNotifier.value!;
      expect(report.failedTransactions, 1);
      expect(report.pushedTransactions, 1);
      expect(report.warnings.join('\n'), contains('Alpha'));
      expect(
          await env.mapFor(
              FireflySyncEntityType.transaction, alpha.transactionPk),
          isNull);
      expect(
          await env.mapFor(
              FireflySyncEntityType.transaction, beta.transactionPk),
          isNotNull);
      // The watermark holds at the row that was not pushed.
      expect(fireflyLastSyncedAt, alpha.dateTimeModified);

      // The next cycle sends the failed row only.
      failAlpha = false;
      env.firefly.requests.clear();
      expect(await fireflySyncNow(), isTrue,
          reason: 'second sync failed: ${fireflySyncErrorNotifier.value}');
      List<FakeRequest> posts =
          env.firefly.requestsTo('POST', '/api/v1/transactions');
      expect(posts, hasLength(1));
      expect(posts.single.body!['transactions'][0]['description'], 'Alpha');
      expect(
          await env.mapFor(
              FireflySyncEntityType.transaction, alpha.transactionPk),
          isNotNull);
      expect(fireflyLastSyncedAt!.isAfter(alpha.dateTimeModified!), isTrue);
    });

    // A split group is one Firefly record with several local rows. Firefly
    // can refuse the whole group, for example when one of its splits names
    // an account that the group may not use. Each local row of the group
    // then reached the same PUT, thus one refusal gave as many warnings as
    // the group has rows.
    test('a refused split group is attempted once per cycle', () async {
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
          date: date);
      Transaction second = await env.insertTransaction(
          name: 'Snacks',
          amount: -5,
          wallet: wallet,
          category: category,
          date: date);
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

      env.firefly.intercept = (FakeRequest r) {
        if (r.method == 'PUT' && r.path == '/api/v1/transactions/300') {
          return FakeResponse(422, {
            'message': 'The given data was invalid.',
            'errors': {
              'transactions.0.source_id': ['Invalid account.']
            }
          });
        }
        return null;
      };

      bool ok = await fireflySyncNow();
      expect(ok, isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');
      expect(env.firefly.requestsTo('PUT', '/api/v1/transactions/300'),
          hasLength(1),
          reason: 'the group is attempted once, not once per local row');
      FireflySyncReport report = fireflySyncReportNotifier.value!;
      expect(report.failedTransactions, 1);
    });
  });

  group('balance anchor', () {
    test('counts a local row dated later today, as Firefly does', () async {
      var (wallet, category) = await linkedWalletAndCategory(balance: '100');
      DateTime now = DateTime.now();
      DateTime lateToday = DateTime(now.year, now.month, now.day, 23, 59, 59);
      // From before the watermark: this cycle does not push it, thus the
      // remote balance of 100 already holds it.
      await env.insertTransaction(
          name: 'Dinner',
          amount: -10,
          wallet: wallet,
          category: category,
          date: lateToday,
          modified: old);

      expect(await fireflySyncNow(), isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');

      Transaction? anchor = await database
          .tryGetTransactionFromPk(fireflyBalanceAnchorPk(wallet.walletPk));
      expect(anchor, isNotNull, reason: 'no anchor was written');
      expect(anchor!.amount, closeTo(110, 0.001));
      double? total =
          await database.watchTotalOfWalletNoConversion(wallet.walletPk).first;
      expect(total, closeTo(100, 0.001),
          reason: 'the wallet total differs from the Firefly balance');
    });
  });

  group('push unsynced changes', () {
    test('sends the rows Firefly lacks, and nothing else', () async {
      var (wallet, category) = await linkedWalletAndCategory();
      DateTime linkedAt = DateTime.now().subtract(const Duration(days: 2));
      DateTime lastPush = DateTime.now().subtract(const Duration(hours: 3));
      DateTime edited = DateTime.now().subtract(const Duration(hours: 1));
      await setFireflyLinkedAt(linkedAt);
      // A watermark in the future: a routine push finds nothing.
      await setFireflyLastSyncedAt(DateTime.now().add(const Duration(days: 1)));

      String remoteUpdatedAt = "2026-01-01T00:00:00Z";
      env.firefly.addTransaction(501, 601,
          description: 'Same',
          amount: '3',
          sourceId: 5,
          destinationId: 700,
          updatedAt: remoteUpdatedAt);
      env.firefly.addTransaction(502, 602,
          description: 'Bread',
          amount: '5',
          sourceId: 5,
          destinationId: 700,
          updatedAt: remoteUpdatedAt);

      // Linked and unchanged.
      Transaction same = await env.insertTransaction(
          name: 'Same',
          amount: -3,
          wallet: wallet,
          category: category,
          modified: lastPush);
      await env.mapRow(
          FireflySyncEntityType.transaction, same.transactionPk, 501,
          lastSyncedLocalModified: same.dateTimeModified,
          fireflyUpdatedAt: DateTime.parse(remoteUpdatedAt),
          journalId: 601);
      // Linked and changed since the last push.
      Transaction bread = await env.insertTransaction(
          name: 'Bread and butter',
          amount: -5,
          wallet: wallet,
          category: category,
          modified: edited);
      await env.mapRow(
          FireflySyncEntityType.transaction, bread.transactionPk, 502,
          lastSyncedLocalModified: lastPush,
          fireflyUpdatedAt: DateTime.parse(remoteUpdatedAt),
          journalId: 602);
      // Never pushed.
      Transaction milk = await env.insertTransaction(
          name: 'Milk',
          amount: -2,
          wallet: wallet,
          category: category,
          modified: edited);

      FireflyUnsyncedCounts counts = await fireflyCountUnsyncedChanges();
      expect(counts.transactions, 2);
      expect(counts.wallets, 0);
      expect(counts.categories, 0);
      expect(counts.deletes, 0);
      expect(counts.describe(), '2 transactions');

      // The routine push does nothing: the rows are behind the watermark.
      expect(await fireflySyncNow(pushOnly: true), isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');
      expect(env.firefly.requestsTo('POST', '/api/v1/transactions'), isEmpty);
      expect(
          env.firefly.requestsTo('PUT', '/api/v1/transactions/502'), isEmpty);

      expect(await fireflyPushUnsyncedChanges(), isTrue,
          reason: 'push failed: ${fireflySyncErrorNotifier.value}');
      List<FakeRequest> posts =
          env.firefly.requestsTo('POST', '/api/v1/transactions');
      expect(posts, hasLength(1));
      expect(posts.single.body!['transactions'][0]['description'], 'Milk');
      List<FakeRequest> puts =
          env.firefly.requestsTo('PUT', '/api/v1/transactions/502');
      expect(puts, hasLength(1));
      expect(puts.single.body!['transactions'][0]['description'],
          'Bread and butter');
      expect(env.firefly.requestsTo('GET', '/api/v1/transactions/501'), isEmpty,
          reason: 'the unchanged row was read');
      expect(env.firefly.requestsTo('PUT', '/api/v1/transactions/501'), isEmpty,
          reason: 'the unchanged row was sent');
      expect(
          await env.mapFor(
              FireflySyncEntityType.transaction, milk.transactionPk),
          isNotNull);

      FireflyUnsyncedCounts after = await fireflyCountUnsyncedChanges();
      expect(after.isEmpty, isTrue, reason: after.describe());
    });
  });

  // Last: it waits for the five second debouncer.
  group('auto push', () {
    test('an edit during an on-demand fetch is pushed afterwards', () async {
      var (wallet, category) = await linkedWalletAndCategory();
      env.firefly.delayFor = (String method, String path) =>
          method == 'GET' && path == '/api/v1/transactions'
              ? const Duration(milliseconds: 1500)
              : null;

      Future<FireflySyncReport?> fetch = fireflyFetchTransactionRange(
          start: DateTime.now().subtract(const Duration(days: 90)));
      await Future.delayed(const Duration(milliseconds: 400));
      // The user adds a transaction while the fetch runs.
      await env.insertTransaction(
          name: 'Late edit', amount: -7, wallet: wallet, category: category);
      scheduleFireflyPush();
      await fetch;
      expect(fireflySyncErrorNotifier.value, isNull);
      expect(env.firefly.requestsTo('POST', '/api/v1/transactions'), isEmpty,
          reason: 'the push runs after the debouncer, not at once');

      await Future.delayed(const Duration(milliseconds: 6500));
      List<FakeRequest> posts =
          env.firefly.requestsTo('POST', '/api/v1/transactions');
      expect(posts, hasLength(1), reason: 'the edit was not pushed');
      expect(posts.single.body!['transactions'][0]['description'], 'Late edit');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
