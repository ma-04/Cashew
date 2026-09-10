// Regression test: a newly created local transaction must be pushed to
// Firefly on the next sync, exactly once, and never duplicated.
import 'package:budget/database/tables.dart';
import 'package:budget/struct/firefly/fireflySyncEngine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'firefly_test_env.dart';

void main() {
  late FireflyTestEnv env;

  setUp(() async {
    env = await FireflyTestEnv.create(
        lastSyncedAt: DateTime.now().subtract(const Duration(days: 1)));
  });

  tearDown(() => env.dispose());

  test("new local transaction is pushed to Firefly exactly once", () async {
    env.firefly.addAccount(5, 'Cash', balance: '100');
    env.firefly.addCategory(6, 'Food');

    DateTime old = DateTime.now().subtract(const Duration(days: 2));
    TransactionWallet wallet = await env.insertWallet('Cash', modified: old);
    TransactionCategory category =
        await env.insertCategory('Food', modified: old);
    await env.mapRow(FireflySyncEntityType.wallet, wallet.walletPk, 5,
        lastSyncedLocalModified: old);
    await env.mapRow(FireflySyncEntityType.category, category.categoryPk, 6,
        lastSyncedLocalModified: old);

    // A brand-new local transaction, as createOrUpdateTransaction stores it
    // (paid, fresh dateTimeModified).
    Transaction created = await env.insertTransaction(
        name: 'Coffee', amount: -4.5, wallet: wallet, category: category);

    bool ok = await fireflySyncNow();
    expect(ok, isTrue,
        reason: 'sync failed: ${fireflySyncErrorNotifier.value}');

    List<FakeRequest> posts =
        env.firefly.requestsTo('POST', '/api/v1/transactions');
    expect(posts, hasLength(1),
        reason: 'expected exactly one POST /transactions, got $posts');
    expect(posts.single.body!['transactions'][0]['description'], 'Coffee');

    FireflySyncMapEntry? map = await env.mapFor(
        FireflySyncEntityType.transaction, created.transactionPk);
    expect(map, isNot(null), reason: 'no sync map recorded for pushed row');
    expect(map!.fireflyId, isNot(0));
    expect(map.fireflyJournalId, isNot(null));

    // A second sync must not duplicate the push.
    env.firefly.requests.clear();
    expect(await fireflySyncNow(), isTrue,
        reason: 'second sync failed: ${fireflySyncErrorNotifier.value}');
    expect(env.firefly.requestsTo('POST', '/api/v1/transactions'), isEmpty,
        reason: 'second sync re-pushed an unchanged row');
    expect(
        env.firefly.requestsTo('PUT', '/api/v1/transactions/${map.fireflyId}'),
        isEmpty,
        reason: 'second sync re-sent an unchanged row');
  });
}
