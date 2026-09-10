// The link between a local account and a Firefly account: it must follow the
// wallet when another wallet takes the place of the primary wallet, it must
// never send a transaction into a deactivated Firefly account, and the user
// must be able to set it by hand.
//
// Before these tests, deleting the primary wallet left the link of the
// removed wallet on the pk "0". Every row of the wallet that took its place
// was then pushed into the Firefly account of the removed wallet.
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/firefly/fireflyModels.dart';
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

  // The map row of a wallet, tombstones included.
  Future<FireflySyncMapEntry?> anyMapFor(String localPk) {
    return (database.select(database.fireflySyncMap)
          ..where(
              (tbl) => tbl.entityType.equalsValue(FireflySyncEntityType.wallet))
          ..where((tbl) => tbl.localPk.equals(localPk)))
        .getSingleOrNull();
  }

  Future<List<FireflySyncMapEntry>> mapsForFireflyId(int fireflyId) {
    return (database.select(database.fireflySyncMap)
          ..where((tbl) => tbl.fireflyId.equals(fireflyId)))
        .get();
  }

  group('the primary wallet changes', () {
    test('the link follows the wallet that becomes the primary wallet',
        () async {
      // "0" is the wallet that the user removes; it holds the Firefly
      // account 9. "Cash" takes its place and holds the account 4.
      env.firefly.addAccount(9, 'Bank', balance: '0');
      env.firefly.addAccount(4, 'Cash', balance: '100');
      env.firefly.addCategory(6, 'Food');
      // The primary wallet of the application has the key "0"; a fresh test
      // database has no wallet at all, thus this makes it.
      await database.into(database.wallets).insert(WalletsCompanion.insert(
          walletPk: const Value('0'),
          name: 'Bank',
          order: 0,
          dateTimeModified: Value(old)));
      TransactionWallet cash = await env.insertWallet('Cash', modified: old);
      TransactionCategory category =
          await env.insertCategory('Food', modified: old);
      await env.mapRow(FireflySyncEntityType.wallet, '0', 9,
          lastSyncedLocalModified: old);
      await env.mapRow(FireflySyncEntityType.wallet, cash.walletPk, 4,
          lastSyncedLocalModified: old);
      await env.mapRow(FireflySyncEntityType.category, category.categoryPk, 6,
          lastSyncedLocalModified: old);
      await env.insertTransaction(
          name: 'Coffee', amount: -4.5, wallet: cash, category: category);

      await database.deleteWallet('0', 0);

      // "0" is the Cash wallet now, and it holds the account of Cash.
      TransactionWallet moved = await database.getWalletInstance('0');
      expect(moved.name, 'Cash');
      expect(
          (await env.mapFor(FireflySyncEntityType.wallet, '0'))?.fireflyId, 4);
      // The key of the removed Cash wallet holds the account of the wallet
      // that the user removed, thus its delete log unlinks that one.
      expect((await anyMapFor(cash.walletPk))?.fireflyId, 9);

      bool ok = await fireflySyncNow();
      expect(ok, isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');

      List<FakeRequest> writes = env.firefly.requests
          .where((r) =>
              (r.method == 'POST' || r.method == 'PUT') &&
              r.path.startsWith('/api/v1/transactions'))
          .toList();
      expect(writes, isNotEmpty, reason: 'the moved row must be pushed');
      for (FakeRequest request in writes) {
        for (dynamic split in request.body!['transactions'] as List<dynamic>) {
          expect(split['source_id'], isNot(9),
              reason: 'nothing may go into the account of the removed wallet');
          expect(split['destination_id'], isNot(9));
        }
      }
      // The account of the removed wallet is unlinked, not deleted.
      expect(env.firefly.requestsTo('DELETE', '/api/v1/accounts/9'), isEmpty);
      List<FireflySyncMapEntry> nine = await mapsForFireflyId(9);
      expect(nine, hasLength(1));
      expect(nine.single.isTombstone, isTrue,
          reason: 'the account of the removed wallet is unlinked');
      expect(nine.single.localPk, cash.walletPk);
    });
  });

  group('an inactive Firefly account', () {
    test('holds the push back instead of writing into it', () async {
      env.firefly.addAccount(5, 'Cash', balance: '100', active: false);
      env.firefly.addCategory(6, 'Food');
      TransactionWallet wallet = await env.insertWallet('Cash', modified: old);
      TransactionCategory category =
          await env.insertCategory('Food', modified: old);
      await env.mapRow(FireflySyncEntityType.wallet, wallet.walletPk, 5,
          lastSyncedLocalModified: old);
      await env.mapRow(FireflySyncEntityType.category, category.categoryPk, 6,
          lastSyncedLocalModified: old);
      await env.insertTransaction(
          name: 'Coffee', amount: -4.5, wallet: wallet, category: category);

      bool ok = await fireflySyncNow();
      expect(ok, isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');

      FireflySyncReport report = fireflySyncReportNotifier.value!;
      expect(env.firefly.requestsTo('POST', '/api/v1/transactions'), isEmpty);
      expect(report.skippedInactiveAccount, 1);
      expect(report.warnings.join('\n'), contains('inactive'));
      // The change is still waiting, thus the next cycle tries again.
      FireflyUnsyncedCounts counts = await fireflyCountUnsyncedChanges();
      expect(counts.transactions, 1);
    });

    test('a second row of the same account warns only once', () async {
      env.firefly.addAccount(5, 'Cash', balance: '100', active: false);
      env.firefly.addCategory(6, 'Food');
      TransactionWallet wallet = await env.insertWallet('Cash', modified: old);
      TransactionCategory category =
          await env.insertCategory('Food', modified: old);
      await env.mapRow(FireflySyncEntityType.wallet, wallet.walletPk, 5,
          lastSyncedLocalModified: old);
      await env.mapRow(FireflySyncEntityType.category, category.categoryPk, 6,
          lastSyncedLocalModified: old);
      await env.insertTransaction(
          name: 'Coffee', amount: -4.5, wallet: wallet, category: category);
      await env.insertTransaction(
          name: 'Tea', amount: -2.5, wallet: wallet, category: category);

      await fireflySyncNow();

      FireflySyncReport report = fireflySyncReportNotifier.value!;
      expect(report.skippedInactiveAccount, 2);
      expect(
          report.warnings.where((w) => w.contains('inactive')).toList().length,
          1);
    });
  });

  group('a rename that Firefly refuses', () {
    test('warns and lets the cycle go on', () async {
      // The account has not changed on Firefly since the last sync, thus the
      // local name wins and the push renames it.
      env.firefly.addAccount(5, 'Cash',
          balance: '100', updatedAt: old.toUtc().toIso8601String());
      env.firefly.addCategory(6, 'Food');
      // Another account holds the new name already.
      env.firefly.addAccount(7, 'Wallet',
          balance: '0', updatedAt: old.toUtc().toIso8601String());
      TransactionWallet wallet =
          await env.insertWallet('Wallet', modified: DateTime.now());
      TransactionCategory category =
          await env.insertCategory('Food', modified: old);
      await env.mapRow(FireflySyncEntityType.wallet, wallet.walletPk, 5,
          lastSyncedLocalModified: old);
      await env.mapRow(FireflySyncEntityType.category, category.categoryPk, 6,
          lastSyncedLocalModified: old);
      await env.insertTransaction(
          name: 'Coffee', amount: -4.5, wallet: wallet, category: category);

      env.firefly.intercept = (FakeRequest request) {
        if (request.method == 'PUT' &&
            request.path == '/api/v1/accounts/5' &&
            request.body?['name'] == 'Wallet') {
          return FakeResponse(422, {
            'message': 'This account name is already in use.',
            'errors': {
              'name': ['This account name is already in use.']
            }
          });
        }
        return null;
      };

      bool ok = await fireflySyncNow();
      expect(ok, isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');

      FireflySyncReport report = fireflySyncReportNotifier.value!;
      expect(report.failedWallets, 1);
      expect(report.warnings.join('\n'), contains('Wallet'));
      expect(report.warnings.join('\n'), contains('Cash'));
      // The link stays, and the transaction of that wallet still went out.
      expect(
          (await env.mapFor(FireflySyncEntityType.wallet, wallet.walletPk))
              ?.fireflyId,
          5);
      expect(
          env.firefly.requestsTo('POST', '/api/v1/transactions'), hasLength(1));
    });
  });

  group('the manual link', () {
    test('moves the wallet to another account and clears the tombstone',
        () async {
      env.firefly.addAccount(9, 'Bank', balance: '0');
      Map<String, dynamic> cashAccount =
          env.firefly.addAccount(4, 'Cash', balance: '100');
      env.firefly.addCategory(6, 'Food');
      TransactionWallet wallet = await env.insertWallet('Bank', modified: old);
      await env.mapRow(FireflySyncEntityType.wallet, wallet.walletPk, 9,
          lastSyncedLocalModified: old);
      // The account 4 was unlinked before, as a wallet delete does.
      await database.into(database.fireflySyncMap).insert(
          FireflySyncMapCompanion.insert(
              entityType: FireflySyncEntityType.wallet,
              localPk: 'gone-wallet',
              fireflyId: 4,
              isTombstone: const Value(true)));

      List<FireflyAccount>? accounts = await fireflyListAssetAccounts();
      expect(accounts, isNotNull);
      List<FireflyWalletLink> links =
          await fireflyWalletLinks(accounts: accounts);
      FireflyWalletLink link =
          links.firstWhere((l) => l.wallet.walletPk == wallet.walletPk);
      expect(link.fireflyId, 9);
      expect(link.account?.name, 'Bank');

      await fireflyLinkWalletToAccount(
          wallet.walletPk, FireflyAccount.fromJson(cashAccount));

      expect(
          (await env.mapFor(FireflySyncEntityType.wallet, wallet.walletPk))
              ?.fireflyId,
          4);
      // No tombstone stands in the way of the new account any more.
      expect(await mapsForFireflyId(4), hasLength(1));
      expect((await mapsForFireflyId(4)).single.isTombstone, isFalse);
      // The account that the wallet had is unlinked, not deleted.
      List<FireflySyncMapEntry> nine = await mapsForFireflyId(9);
      expect(nine, hasLength(1));
      expect(nine.single.isTombstone, isTrue);
      expect(nine.single.localPk, startsWith(kFireflyUnlinkedPkPrefix));

      // The next pull brings the transactions of the new account in.
      env.firefly.addTransaction(200, 201,
          description: 'Lunch',
          amount: '12.00',
          sourceId: 4,
          destinationId: 800,
          date: DateTime.now().subtract(const Duration(hours: 2)));
      bool ok = await fireflySyncNow();
      expect(ok, isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');
      List<Transaction> pulled = await (database.select(database.transactions)
            ..where((t) => t.name.equals('Lunch')))
          .get();
      expect(pulled, hasLength(1));
      expect(pulled.single.walletFk, wallet.walletPk);
    });

    test('unlinking leaves a tombstone and no live link', () async {
      env.firefly.addAccount(9, 'Bank', balance: '0');
      TransactionWallet wallet = await env.insertWallet('Bank', modified: old);
      await env.mapRow(FireflySyncEntityType.wallet, wallet.walletPk, 9,
          lastSyncedLocalModified: old);

      await fireflyLinkWalletToAccount(wallet.walletPk, null);

      expect(await env.mapFor(FireflySyncEntityType.wallet, wallet.walletPk),
          isNull);
      List<FireflySyncMapEntry> nine = await mapsForFireflyId(9);
      expect(nine, hasLength(1));
      expect(nine.single.isTombstone, isTrue);
    });
  });
}
