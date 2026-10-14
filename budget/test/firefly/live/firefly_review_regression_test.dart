// The findings of the review of 2026-10-14 (FIREFLY_REVIEW_2026-10-14.md)
// against a real Firefly III. Each test names its review item, and first
// failed with the code before the fix.
@Tags(['live'])
library;

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/firefly/client/fireflyStore.dart';
import 'package:budget/struct/firefly/fireflyMapper.dart'
    show kFireflyUncategorizedCategoryPk;
import 'package:budget/struct/firefly/fireflySyncEngine.dart';
import 'package:budget/struct/settings.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'firefly_client_live_test.dart'
    show connectPhone, editLocally, localRowOfGroup, remoteSplit, sync;
import 'firefly_live_env.dart';

String _today() {
  DateTime n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, "0");
  return "${n.year}-${two(n.month)}-${two(n.day)}T10:00:00+00:00";
}

Future<int> _countByDescription(FireflyLive live, String description) async {
  LiveResponse found = await live.get(
      "/search/transactions", {"query": "description_is:$description"});
  return found.json["meta"]["pagination"]["total"] as int;
}

void main() {
  liveGroup('review findings against Firefly 6.7.9', (live) {
    late int checking;
    late int savings;
    late int food;
    late int old;
    late int recent;
    late int uncategorized;

    setUp(() async {
      checking = await live.createAssetAccount('Checking', extra: {
        "opening_balance": "500",
        "opening_balance_date": "2024-01-01",
      });
      savings = await live.createAssetAccount('Savings');
      food = await live.createCategory('Food');
      old = (await live.createWithdrawal(
              sourceId: checking,
              amount: "10",
              date: "2024-05-01T10:00:00+00:00",
              description: "Old",
              categoryId: food))
          .id;
      recent = (await live.createWithdrawal(
              sourceId: checking,
              amount: "11",
              date: _today(),
              description: "Recent",
              categoryId: food))
          .id;
      uncategorized = (await live.createWithdrawal(
              sourceId: checking,
              amount: "12",
              date: "2024-05-02T10:00:00+00:00",
              description: "NoCategory"))
          .id;
      await connectPhone(live);
    });

    tearDown(() async {
      await database.close();
    });

    test('A1: the uncategorized category cannot be deleted', () async {
      await sync();
      TransactionCategory c =
          await database.getCategoryInstance(kFireflyUncategorizedCategoryPk);
      await database.deleteCategory(c.categoryPk, c.order);
      await sync(pushOnly: true);
      await sync();
      expect((await live.get("/transactions/$uncategorized")).status, 200);
      expect(
          await database
              .getCategoryInstanceOrNull(kFireflyUncategorizedCategoryPk),
          isNotNull);
    });

    test('A6: a local category that holds Firefly rows cannot be deleted',
        () async {
      await sync();
      await database.createOrUpdateCategory(
        TransactionCategory(
          categoryPk: "-1",
          name: "Local",
          dateCreated: DateTime.now(),
          order: 50,
          income: false,
        ),
        insert: true,
      );
      TransactionCategory local = (await database.getAllCategories())
          .firstWhere((c) => c.name == "Local");
      Transaction row = await localRowOfGroup(old);
      await editLocally(row.copyWith(categoryFk: local.categoryPk));
      await database.deleteCategory(local.categoryPk, local.order);
      expect(await database.getCategoryInstanceOrNull(local.categoryPk),
          isNotNull);
      await sync();
      expect((await live.get("/transactions/$old")).status, 200);
    });

    test('B1: a local delete reaches Firefly also in a full cycle', () async {
      await sync();
      Transaction row = await localRowOfGroup(recent);
      await database.deleteTransaction(row.transactionPk);
      await sync();
      expect((await live.get("/transactions/$recent")).status, 404);
      expect(
          await (database.select(database.transactions)
                ..where((t) => t.name.equals("Recent")))
              .get(),
          isEmpty);
    });

    test('A2: changes made while the sync was off are counted, and a '
        'discard brings the server state back with no write', () async {
      await sync();
      TransactionWallet w = (await database.getAllWallets())
          .firstWhere((w) => w.name == "Checking");
      appStateSettings["fireflyEnabled"] = false;
      await database.deleteWallet(w.walletPk, w.order);
      appStateSettings["fireflyEnabled"] = true;
      FireflyLocalChanges changes = await fireflyLocalChangesToSend();
      expect(changes.transactionsDeleted, greaterThanOrEqualTo(3));
      // The settings page asks first. "Discard" is a rebuild.
      expect(await fireflyRebuildFromFirefly(), isTrue,
          reason: fireflySyncErrorNotifier.value);
      expect((await live.get("/transactions/$old")).status, 200);
      LiveResponse account = await live.get("/accounts/$checking");
      expect(account.attributes["active"], isTrue);
      expect(
          (await database.getAllWallets()).map((w) => w.name),
          contains("Checking"));
      expect((await localRowOfGroup(old)).name, "Old");
    });

    test('B3: the delete of one leg of a transfer removes the other leg',
        () async {
      LiveResponse transfer = await live.post("/transactions", {
        "transactions": [
          {
            "type": "transfer",
            "date": "2024-06-01T10:00:00+00:00",
            "amount": "20",
            "description": "Move",
            "source_id": checking.toString(),
            "destination_id": savings.toString(),
          }
        ],
      });
      await sync();
      List<FireflySyncMapEntry> legs = await fireflyMapsOfRemote(
          FireflySyncEntityType.transaction, transfer.id);
      expect(legs, hasLength(2));
      await database.deleteTransaction(legs.first.localPk);
      await sync(pushOnly: true);
      expect((await live.get("/transactions/${transfer.id}")).status, 404);
      expect(
          await (database.select(database.transactions)
                ..where((t) => t.name.equals("Move")))
              .get(),
          isEmpty);
    });

    test('A3: a local category from before the link does not go to Firefly',
        () async {
      // A default category of the app with no transaction goes at the link.
      await database.createOrUpdateCategory(
        TransactionCategory(
          categoryPk: "-1",
          name: "Dining",
          dateCreated: DateTime(0),
          order: 10,
          income: false,
        ),
        insert: true,
      );
      await sync();
      expect(
          (await database.getAllCategories()).map((c) => c.name),
          isNot(contains("Dining")));
      // One from before the link that holds a planned (unpaid) row stays,
      // local only.
      await database.createOrUpdateCategory(
        TransactionCategory(
          categoryPk: "beauty",
          name: "Beauty",
          dateCreated: DateTime(0),
          order: 11,
          income: false,
        ),
      );
      TransactionWallet wallet = (await database.getAllWallets())
          .firstWhere((w) => w.name == "Checking");
      await database.createOrUpdateTransaction(
        Transaction(
          transactionPk: "-1",
          name: "Planned",
          amount: -3,
          note: "",
          categoryFk: "beauty",
          walletFk: wallet.walletPk,
          dateCreated: DateTime(2030, 1, 1),
          income: false,
          paid: false,
          skipPaid: false,
        ),
        insert: true,
      );
      // A move in the list changes each category after it.
      TransactionCategory beauty = await database.getCategoryInstance("beauty");
      await database.moveCategory("beauty", 0, beauty.order);
      await sync(pushOnly: true);
      await sync();
      List<Map<String, dynamic>> remote =
          List.from((await live.get("/categories")).json["data"]);
      expect(remote.map((c) => c["attributes"]["name"]),
          isNot(contains("Beauty")));
    });

    test('A3: an installation linked before the link moment cleans up once, '
        'and keeps its wallets as inactive', () async {
      await sync();
      appStateSettings["fireflyLinkedAt"] = "";
      await database.createOrUpdateWallet(TransactionWallet(
        walletPk: "old-wallet",
        name: "Old cash",
        dateCreated: DateTime(2020),
        order: 20,
        currency: "eur",
        decimals: 2,
      ));
      await database.createOrUpdateCategory(TransactionCategory(
        categoryPk: "old-category",
        name: "Old default",
        dateCreated: DateTime(2020),
        order: 30,
        income: false,
      ));
      await sync();
      expect(await database.getCategoryInstanceOrNull("old-category"), isNull);
      TransactionWallet? wallet =
          await database.getWalletInstanceOrNull("old-wallet");
      expect(wallet?.archived, isTrue);
      List<Map<String, dynamic>> remote = List.from(
          (await live.get("/accounts", {"type": "asset"})).json["data"]);
      expect(remote.map((a) => a["attributes"]["name"]),
          isNot(contains("Old cash")));
    });

    test('A4: an account deleted on Firefly is not made again', () async {
      await sync();
      expect((await live.delete("/accounts/$savings")).status, 204);
      expect(await fireflySyncNow(fullResync: true), isTrue,
          reason: fireflySyncErrorNotifier.value);
      TransactionWallet? wallet = (await database.getAllWallets())
          .where((w) => w.name == "Savings")
          .firstOrNull;
      if (wallet != null) {
        await database.createOrUpdateWallet(wallet.copyWith(name: "Savings 2"));
        await sync(pushOnly: true);
        await sync();
      }
      List<Map<String, dynamic>> remote = List.from(
          (await live.get("/accounts", {"type": "asset"})).json["data"]);
      expect(remote.map((a) => a["attributes"]["name"]),
          isNot(anyOf(contains("Savings"), contains("Savings 2"))));
    });

    test('A11: a local budget does not clear the Firefly budget', () async {
      LiveResponse groceries =
          await live.post("/budgets", {"name": "Groceries"});
      await live.put("/transactions/$recent", {
        "transactions": [
          {"budget_id": groceries.id.toString()}
        ],
      });
      await sync();
      await database.createOrUpdateBudget(
        Budget(
          budgetPk: "local-budget",
          name: "Trip",
          amount: 100,
          startDate: DateTime(2024, 1, 1),
          endDate: DateTime(2030, 1, 1),
          income: false,
          archived: false,
          addedTransactionsOnly: true,
          periodLength: 1,
          reoccurrence: BudgetReoccurence.monthly,
          dateCreated: DateTime.now(),
          pinned: false,
          order: 9,
          walletFk: "0",
          isAbsoluteSpendingLimit: false,
        ),
        insert: true,
      );
      Transaction row = await localRowOfGroup(recent);
      await editLocally(row.copyWith(
          sharedReferenceBudgetPk: const Value("local-budget"),
          name: "Recent edited"));
      await sync(pushOnly: true);
      Map<String, dynamic> split = await remoteSplit(live, recent);
      expect(split["description"], "Recent edited");
      expect(split["budget_id"], groceries.id.toString());
    });

    test('A12: a create of a row that the server has does not duplicate it',
        () async {
      await sync();
      TransactionWallet wallet = (await database.getAllWallets())
          .firstWhere((w) => w.name == "Checking");
      await database.createOrUpdateTransaction(
        Transaction(
          transactionPk: "-1",
          name: "Once",
          amount: -4,
          note: "",
          categoryFk: kFireflyUncategorizedCategoryPk,
          walletFk: wallet.walletPk,
          dateCreated: DateTime(2024, 7, 1, 9),
          income: false,
          paid: true,
          skipPaid: false,
        ),
        insert: true,
      );
      await sync(pushOnly: true);
      expect(await _countByDescription(live, "Once"), 1);
      // A restore of a backup from before the answer: no link, and a create
      // that was never tried.
      Transaction row = (await (database.select(database.transactions)
                ..where((t) => t.name.equals("Once")))
              .get())
          .single;
      await fireflyDeleteMap(FireflySyncEntityType.transaction, row.transactionPk);
      await fireflyQueue(FireflySyncEntityType.transaction, row.transactionPk);
      await sync(pushOnly: true);
      expect(await _countByDescription(live, "Once"), 1);
      expect(
          await fireflyMapOf(
              FireflySyncEntityType.transaction, row.transactionPk),
          isNotNull);
    });
  });
}
