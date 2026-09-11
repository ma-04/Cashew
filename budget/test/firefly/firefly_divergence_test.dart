// The second data divergence, 2026-09-10/11.
//
// Three separate faults made the app and Firefly disagree:
//
//   - A push of a cross-currency transfer sent the local destination leg on
//     top of a correct foreign amount. One edit to the source leg replaced
//     22.98 USD with 2,850, the amount of the source row.
//   - A bulk operation of this app stamps the current time onto every row it
//     touches. Rows from before the link then read as new, and the push
//     created a second Firefly record for each of them.
//   - Each of those records named its Firefly expense account after the
//     description of the row, which made one account per description.
//
// And the repair of the first: a local row that is wrong and unchanged is
// never read again, because "nothing changed" ends the comparison.
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/firefly/fireflySettings.dart';
import 'package:budget/struct/firefly/fireflySyncEngine.dart';
import 'package:budget/struct/settings.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'firefly_test_env.dart';

void main() {
  late FireflyTestEnv env;
  final DateTime old = DateTime.now().subtract(const Duration(days: 3));
  final DateTime linkedAt = DateTime.now().subtract(const Duration(days: 2));

  setUp(() async {
    env = await FireflyTestEnv.create(
        lastSyncedAt: DateTime.now().subtract(const Duration(days: 1)));
    appStateSettings['fireflyLinkedAt'] = linkedAt.toIso8601String();
  });

  tearDown(() => env.dispose());

  Future<(TransactionWallet, TransactionCategory)> linkedWalletAndCategory(
      {String walletName = 'Cash'}) async {
    env.firefly.addAccount(5, walletName, balance: '100');
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

  group('a row booked before the link', () {
    test('is not uploaded, even after a bulk operation touched it', () async {
      var (wallet, category) = await linkedWalletAndCategory();
      // deleteWallet -> convertToPrimaryWallet -> transferTransactionsOnly
      // writes the current time onto the modified column of every row it
      // moves. On that column this row reads as new.
      await env.insertTransaction(
          name: 'Lunch',
          amount: -12,
          wallet: wallet,
          category: category,
          date: DateTime.now().subtract(const Duration(days: 20)),
          modified: DateTime.now());

      bool ok = await fireflySyncNow(pushOnly: true);
      expect(ok, isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');

      expect(env.firefly.requestsTo('POST', '/api/v1/transactions'), isEmpty,
          reason: 'local history was uploaded a second time');
      FireflySyncReport report = fireflySyncReportNotifier.value!;
      expect(report.skippedPreLinkHistory, 1);
      expect(report.warnings, hasLength(1));
      expect(report.warnings.single, contains('Push local history'));
    });

    test('holds one warning however many rows there are', () async {
      var (wallet, category) = await linkedWalletAndCategory();
      for (int i = 0; i < 3; i++) {
        await env.insertTransaction(
            name: 'Old $i',
            amount: -12,
            wallet: wallet,
            category: category,
            date: DateTime.now().subtract(Duration(days: 20 + i)),
            modified: DateTime.now());
      }

      await fireflySyncNow(pushOnly: true);

      FireflySyncReport report = fireflySyncReportNotifier.value!;
      expect(report.skippedPreLinkHistory, 3);
      expect(report.warnings, hasLength(1));
      // No backlog hold: the watermark must move past them, or every cycle
      // from here on reads the whole of the local history again.
      expect(fireflyLastSyncedAt!.isAfter(linkedAt), isTrue);
    });

    test('goes up when the user asks for the local history', () async {
      var (wallet, category) = await linkedWalletAndCategory();
      await env.insertTransaction(
          name: 'Lunch',
          amount: -12,
          wallet: wallet,
          category: category,
          date: DateTime.now().subtract(const Duration(days: 20)),
          modified: DateTime.now());

      await fireflySyncNow(pushExistingLocalHistory: true, pushOnly: true);

      expect(
          env.firefly.requestsTo('POST', '/api/v1/transactions'), hasLength(1));
      expect(fireflySyncReportNotifier.value!.skippedPreLinkHistory, 0);
    });

    test('a row entered today is still uploaded', () async {
      var (wallet, category) = await linkedWalletAndCategory();
      await env.insertTransaction(
          name: 'Lunch', amount: -12, wallet: wallet, category: category);

      await fireflySyncNow(pushOnly: true);

      expect(
          env.firefly.requestsTo('POST', '/api/v1/transactions'), hasLength(1));
      expect(fireflySyncReportNotifier.value!.skippedPreLinkHistory, 0);
    });
  });

  group('the other side of a withdrawal', () {
    Future<List<FakeRequest>> pushOneWithdrawal() async {
      var (wallet, category) = await linkedWalletAndCategory();
      await env.insertTransaction(
          name: 'Chocolate for Jannatul Mawa',
          amount: -12,
          wallet: wallet,
          category: category);
      bool ok = await fireflySyncNow(pushOnly: true);
      expect(ok, isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');
      return env.firefly.requestsTo('POST', '/api/v1/transactions');
    }

    test('is the cash account of the instance by default', () async {
      env.firefly.addAccount(9, 'Cash account', type: 'cash');

      List<FakeRequest> posts = await pushOneWithdrawal();

      expect(posts, hasLength(1));
      Map<String, dynamic> split =
          Map<String, dynamic>.from(posts.single.body!['transactions'][0]);
      expect(split['destination_id'], '9');
      // This is the account that made 359 "Lunch", 360 "3500" and 363
      // "Chocolate for Jannatul Mawa" on the user's instance.
      expect(split.containsKey('destination_name'), isFalse);
    });

    test('is named "Cash account" when the instance has none yet', () async {
      List<FakeRequest> posts = await pushOneWithdrawal();

      Map<String, dynamic> split =
          Map<String, dynamic>.from(posts.single.body!['transactions'][0]);
      expect(split.containsKey('destination_id'), isFalse);
      expect(split['destination_name'], 'Cash account');
    });

    test('carries the category when the user asks for that', () async {
      env.firefly.addAccount(9, 'Cash account', type: 'cash');
      appStateSettings['fireflyCounterpartyNaming'] =
          kFireflyCounterpartyNamingCategory;

      List<FakeRequest> posts = await pushOneWithdrawal();

      Map<String, dynamic> split =
          Map<String, dynamic>.from(posts.single.body!['transactions'][0]);
      expect(split.containsKey('destination_id'), isFalse);
      expect(split['destination_name'], 'Food');
    });
  });

  group('a cross-currency transfer that Firefly already holds', () {
    // Account 5 is BDT, account 7 is USD. Firefly holds 2,850 BDT with a
    // foreign amount of 22.98 USD. The local destination leg is stale: it
    // carries 2,850, which is what a build before the foreign amount wrote.
    Future<(Transaction, Transaction)> divergedTransfer(
        {required bool sourceChanged,
        required bool destinationChanged,
        DateTime? remoteUpdatedAt}) async {
      // The database holds a time to the second. A stamp with a millisecond
      // in it would read as "Firefly is newer" on every cycle.
      DateTime remoteStamp = DateTime.fromMillisecondsSinceEpoch(
          ((remoteUpdatedAt ?? old).millisecondsSinceEpoch ~/ 1000) * 1000);
      String updatedAt = remoteStamp.toUtc().toIso8601String();
      env.firefly.addAccount(5, 'Cash BDT', balance: '0', currencyCode: 'BDT');
      env.firefly.addAccount(7, 'Card USD', balance: '0', currencyCode: 'USD');
      env.firefly.addTransaction(300, 3000,
          description: 'Card bill',
          amount: '2850.00',
          sourceId: 5,
          destinationId: 7,
          type: 'transfer',
          currencyCode: 'BDT',
          foreignAmount: '22.98',
          foreignCurrencyCode: 'USD',
          updatedAt: updatedAt);
      TransactionWallet fromWallet =
          await env.insertWallet('Cash BDT', modified: old, currency: 'BDT');
      TransactionWallet toWallet =
          await env.insertWallet('Card USD', modified: old, currency: 'USD');
      TransactionCategory category =
          await env.insertCategory('Food', modified: old);
      await env.mapRow(FireflySyncEntityType.wallet, fromWallet.walletPk, 5,
          lastSyncedLocalModified: old);
      await env.mapRow(FireflySyncEntityType.wallet, toWallet.walletPk, 7,
          lastSyncedLocalModified: old);
      Transaction from = await env.insertTransaction(
          name: 'Card bill',
          amount: -2850,
          wallet: fromWallet,
          category: category);
      Transaction to = await env.insertTransaction(
          name: 'Card bill',
          amount: 2850,
          wallet: toWallet,
          category: category);
      await database.createOrUpdateTransaction(
          from.copyWith(pairedTransactionFk: Value(to.transactionPk)),
          updateSharedEntry: false);
      await database.createOrUpdateTransaction(
          to.copyWith(pairedTransactionFk: Value(from.transactionPk)),
          updateSharedEntry: false);
      // Pairing writes the rows, thus their modification stamps are from
      // now. A side counts as unchanged when its link carries that stamp.
      from = await env.reloadTransaction(from.transactionPk);
      to = await env.reloadTransaction(to.transactionPk);
      await env.mapRow(
          FireflySyncEntityType.transaction, from.transactionPk, 300,
          lastSyncedLocalModified: sourceChanged ? old : from.dateTimeModified,
          fireflyUpdatedAt: remoteStamp,
          journalId: 3000);
      await env.mapRow(FireflySyncEntityType.transaction, to.transactionPk, 300,
          lastSyncedLocalModified:
              destinationChanged ? old : to.dateTimeModified,
          fireflyUpdatedAt: remoteStamp,
          journalId: 3000);
      return (from, to);
    }

    test('an edit to one side does not overwrite the other', () async {
      var (from, to) = await divergedTransfer(
          sourceChanged: true, destinationChanged: false);

      bool ok = await fireflySyncNow(pushOnly: true);
      expect(ok, isTrue,
          reason: 'sync failed: ${fireflySyncErrorNotifier.value}');

      List<FakeRequest> puts =
          env.firefly.requestsTo('PUT', '/api/v1/transactions/300');
      expect(puts, hasLength(1), reason: 'the transfer was not pushed');
      Map<String, dynamic> split =
          Map<String, dynamic>.from(puts.single.body!['transactions'][0]);
      // The failure of 2026-09-10: this went out as 2850.00.
      expect(split['foreign_amount'], '22.98');
      expect(split['amount'], '2850.00');

      // And the stale local row is repaired with what Firefly holds.
      expect((await env.reloadTransaction(to.transactionPk)).amount, 22.98);
      expect((await env.reloadTransaction(from.transactionPk)).amount, -2850);
    });

    test('the repaired row is not pushed again on the next cycle', () async {
      var (_, to) = await divergedTransfer(
          sourceChanged: true, destinationChanged: false);
      await fireflySyncNow(pushOnly: true);
      expect((await env.reloadTransaction(to.transactionPk)).amount, 22.98);

      await fireflySyncNow(pushOnly: true);

      expect(env.firefly.requestsTo('PUT', '/api/v1/transactions/300'),
          hasLength(1),
          reason: 'the repair made the row look changed');
    });

    test('a full resync repairs a row that neither side changed', () async {
      var (_, to) = await divergedTransfer(
          sourceChanged: false, destinationChanged: false);

      // A routine cycle answers "nothing changed" and leaves it wrong.
      await fireflySyncNow();
      expect((await env.reloadTransaction(to.transactionPk)).amount, 2850);

      await fireflySyncNow(fullResync: true);

      expect((await env.reloadTransaction(to.transactionPk)).amount, 22.98);
    });
  });
}
