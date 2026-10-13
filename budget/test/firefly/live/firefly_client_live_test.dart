// The Firefly client against a real Firefly III. Each test starts with a
// clean server, builds data there the way the web interface would, connects
// a phone with an empty local database, and then checks the rule of the
// client: an action in Cashew changes on the server exactly what it asked
// for, and no other field of any record.
@Tags(['live'])
library;

import 'dart:ffi';
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/firefly/client/fireflyPlanning.dart';
import 'package:budget/struct/firefly/client/fireflyStore.dart';
import 'package:budget/struct/firefly/fireflyMapper.dart'
    show kFireflyUncategorizedCategoryPk;
import 'package:budget/struct/firefly/fireflySyncEngine.dart';
import 'package:budget/struct/settings.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:sqlite3/open.dart' as sqlite_open;

import 'firefly_live_env.dart';

void _useSystemSqlite() {
  if (!Platform.isLinux) return;
  sqlite_open.open.overrideFor(sqlite_open.OperatingSystem.linux, () {
    for (String name in ['libsqlite3.so', 'libsqlite3.so.0']) {
      try {
        return DynamicLibrary.open(name);
      } catch (_) {}
    }
    return DynamicLibrary.open('libsqlite3.so');
  });
}

// A phone with an empty database, connected to the live server.
Future<void> connectPhone(FireflyLive live) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  _useSystemSqlite();
  SharedPreferences.setMockInitialValues({});
  sharedPreferences = await SharedPreferences.getInstance();
  FlutterSecureStorage.setMockInitialValues(
      {'fireflyPersonalAccessToken': live.token});
  database = FinanceDatabase(NativeDatabase.memory());
  appStateSettings = {
    'fireflyEnabled': true,
    'fireflyHostUrl': live.baseUrl,
    'fireflyLastSyncedAt': '',
    'fireflyLinkedAt': '',
    'sharedBudgets': false,
    'outlinedIcons': false,
  };
  fireflyBackupBeforeRebuild = () async => null;
}

Future<FireflySyncReport> sync({bool pushOnly = false}) async {
  bool ok = await fireflySyncNow(pushOnly: pushOnly, allowRebuild: true);
  expect(ok, isTrue, reason: fireflySyncErrorNotifier.value);
  return fireflySyncReportNotifier.value!;
}

Future<Map<String, dynamic>> remoteSplit(FireflyLive live, int groupId,
    [int index = 0]) async {
  LiveResponse group = await live.get("/transactions/$groupId");
  expect(group.status, 200, reason: group.toString());
  return Map<String, dynamic>.from(group.attributes["transactions"][index]);
}

// Each key of the split except the ones that `changed` names, and the keys
// that Firefly computes on each read.
Map<String, dynamic> without(Map<String, dynamic> split, Set<String> changed) {
  const Set<String> computed = {
    "source_balance_after",
    "destination_balance_after",
    "pc_source_balance_after",
    "pc_destination_balance_after",
    "source_balance_dirty",
    "destination_balance_dirty",
  };
  return {
    for (MapEntry<String, dynamic> e in split.entries)
      if (!changed.contains(e.key) && !computed.contains(e.key)) e.key: e.value,
  };
}

Future<Transaction> localRowOfGroup(int groupId, {int? journalId}) async {
  List<FireflySyncMapEntry> maps =
      await fireflyMapsOfRemote(FireflySyncEntityType.transaction, groupId);
  FireflySyncMapEntry map = journalId == null
      ? maps.first
      : maps.firstWhere((m) => m.fireflyJournalId == journalId);
  return (database.select(database.transactions)
        ..where((t) => t.transactionPk.equals(map.localPk)))
      .getSingle();
}

// An edit the way the transaction page saves one.
Future<void> editLocally(Transaction edited) async {
  await database.createOrUpdateTransaction(edited);
}

void main() {
  liveGroup('the Firefly client against Firefly 6.7.9', (live) {
    late int checking;
    late int savings;
    late int food;
    late int lunch;

    Future<void> buildServer() async {
      checking = await live.createAssetAccount('Checking', extra: {
        "opening_balance": "500",
        "opening_balance_date": "2024-01-01",
      });
      savings = await live.createAssetAccount('Savings',
          role: 'savingAsset', extra: {"virtual_balance": "100"});
      food = await live.createCategory('Food');
      LiveResponse created = await live.createWithdrawal(
        sourceId: checking,
        amount: "12.345",
        date: "2024-05-01T23:30:00+02:00",
        description: "Lunch",
        destinationName: "Cafe",
        categoryId: food,
        externalId: "bank-import-77",
        extra: {
          "tags": ["work"],
          "notes": "with team",
          "internal_reference": "ref-1",
        },
      );
      lunch = created.id;
    }

    setUp(() async {
      await buildServer();
      await connectPhone(live);
    });

    tearDown(() async {
      await database.close();
    });

    test('the first sync mirrors the server and the balances agree',
        () async {
      FireflySyncReport report = await sync();
      expect(report.warnings.where((w) => w.contains("balance")), isEmpty,
          reason: report.warnings.join("\n"));
      List<TransactionWallet> wallets = await database.getAllWallets();
      expect(wallets.map((w) => w.name), containsAll(['Checking', 'Savings']));
      TransactionWallet checkingWallet = wallets.firstWhere((w) => w.name == "Checking");
      double sum = (await (database.select(database.transactions)
                ..where((t) => t.walletFk.equals(checkingWallet.walletPk)))
              .get())
          .fold(0.0, (a, t) => a + t.amount);
      expect(sum, closeTo(500 - 12.345, 1e-9),
          reason: "the opening balance and the lunch");
      Transaction row = await localRowOfGroup(lunch);
      expect(row.name, "Lunch");
      expect(row.amount, closeTo(-12.345, 1e-9));
      expect(row.dateCreated.toUtc(), DateTime.utc(2024, 5, 1, 21, 30));
    });

    test('a sync with no local change writes nothing on the server',
        () async {
      await sync();
      Map<String, dynamic> before = await remoteSplit(live, lunch);
      String groupUpdated =
          (await live.get("/transactions/$lunch")).attributes["updated_at"];
      // The records of today come again in the incremental pull. Each one
      // matches its snapshot, thus no local row is written again.
      FireflySyncReport again = await sync();
      expect(again.pulledTransactions, 0, reason: again.toString());
      expect(again.pulledCategories, 0);
      expect(again.pulledWallets, 0);
      await sync(pushOnly: true);
      expect((await live.get("/transactions/$lunch")).attributes["updated_at"],
          groupUpdated);
      expect(without(await remoteSplit(live, lunch), {}), without(before, {}));
    });

    test('a new description changes the description and nothing else',
        () async {
      await sync();
      Map<String, dynamic> before = await remoteSplit(live, lunch);
      Transaction row = await localRowOfGroup(lunch);
      await editLocally(row.copyWith(name: "Team lunch"));
      await sync(pushOnly: true);
      Map<String, dynamic> after = await remoteSplit(live, lunch);
      expect(after["description"], "Team lunch");
      expect(without(after, {"description"}), without(before, {"description"}));
    });

    test('a field changed on the web and here keeps the web value', () async {
      await sync();
      Map<String, dynamic> split = await remoteSplit(live, lunch);
      LiveResponse web = await live.put("/transactions/$lunch", {
        "transactions": [
          {
            "transaction_journal_id": split["transaction_journal_id"],
            "description": "Web lunch",
            "amount": "20",
          }
        ]
      });
      expect(web.status, 200, reason: web.toString());
      Transaction row = await localRowOfGroup(lunch);
      // The same field (the description) and a field the web did not change
      // (the note).
      await editLocally(row.copyWith(name: "Phone lunch", note: "from phone"));
      FireflySyncReport report = await sync();
      Map<String, dynamic> after = await remoteSplit(live, lunch);
      expect(after["description"], "Web lunch");
      expect(after["notes"], "from phone");
      expect(double.parse(after["amount"]), closeTo(20, 1e-9));
      expect(report.conflicts, 1);
      Transaction local = await localRowOfGroup(lunch);
      expect(local.name, "Web lunch");
      expect(local.amount, closeTo(-20, 1e-9));
    });

    test('a new transaction is created once, with the right instant',
        () async {
      await sync();
      TransactionWallet wallet = (await database.getAllWallets())
          .firstWhere((w) => w.name == "Checking");
      DateTime when = DateTime(2024, 6, 2, 8, 15);
      await database.createOrUpdateTransaction(
        Transaction(
          transactionPk: "-1",
          name: "Bus",
          amount: -2.5,
          note: "",
          categoryFk: kFireflyUncategorizedCategoryPk,
          walletFk: wallet.walletPk,
          dateCreated: when,
          income: false,
          paid: true,
          skipPaid: false,
        ),
        insert: true,
      );
      FireflySyncReport report = await sync(pushOnly: true);
      expect(report.pushedCreates, 1, reason: report.warnings.join("\n"));
      await sync();
      LiveResponse found = await live.get("/search/transactions",
          {"query": "description_is:Bus"});
      expect(found.json["meta"]["pagination"]["total"], 1);
      Map<String, dynamic> split =
          Map<String, dynamic>.from(found.json["data"][0]["attributes"]
              ["transactions"][0]);
      expect(DateTime.parse(split["date"]).toUtc(), when.toUtc());
      // No account is named: Firefly books it on its own cash account.
      expect(split["destination_type"], "Cash account");
      expect(split["external_id"], isNotNull);
    });

    test('an edit keeps the external id of the importer', () async {
      await sync();
      Transaction row = await localRowOfGroup(lunch);
      await editLocally(row.copyWith(amount: -13));
      await sync(pushOnly: true);
      Map<String, dynamic> after = await remoteSplit(live, lunch);
      expect(after["external_id"], "bank-import-77");
      expect(double.parse(after["amount"]), closeTo(13, 1e-9));
    });

    test('a payment to a loan keeps the loan when it is edited', () async {
      LiveResponse loan = await live.post("/accounts", {
        "name": "Car loan",
        "type": "liability",
        "liability_type": "loan",
        "liability_direction": "debit",
        "interest": "0",
        "interest_period": "monthly",
        "currency_code": "EUR",
      });
      expect(loan.status, 200, reason: loan.toString());
      LiveResponse payment = await live.post("/transactions", {
        "transactions": [
          {
            "type": "withdrawal",
            "date": "2024-05-03T09:00:00Z",
            "amount": "100",
            "description": "Loan payment",
            "source_id": checking.toString(),
            "destination_id": loan.id.toString(),
          }
        ]
      });
      expect(payment.status, 200, reason: payment.toString());
      await sync();
      Transaction row = await localRowOfGroup(payment.id);
      await editLocally(row.copyWith(name: "Loan payment May"));
      await sync(pushOnly: true);
      Map<String, dynamic> after = await remoteSplit(live, payment.id);
      expect(after["destination_id"], loan.id.toString());
      expect(after["description"], "Loan payment May");
    });

    test('a transfer between two currencies keeps its foreign amount',
        () async {
      await live.post("/currencies/USD/enable", {});
      int usd = await live.createAssetAccount('Dollar card',
          currencyCode: 'USD');
      LiveResponse transfer = await live.post("/transactions", {
        "transactions": [
          {
            "type": "transfer",
            "date": "2024-05-04T10:00:00Z",
            "amount": "1200",
            "foreign_amount": "9.68",
            "foreign_currency_code": "USD",
            "description": "Top up",
            "source_id": checking.toString(),
            "destination_id": usd.toString(),
          }
        ]
      });
      expect(transfer.status, 200, reason: transfer.toString());
      await sync();
      Map<String, dynamic> before = await remoteSplit(live, transfer.id);
      List<FireflySyncMapEntry> maps = await fireflyMapsOfRemote(
          FireflySyncEntityType.transaction, transfer.id);
      expect(maps, hasLength(2));
      Transaction source = (await Future.wait(maps.map((m) =>
              (database.select(database.transactions)
                    ..where((t) => t.transactionPk.equals(m.localPk)))
                  .getSingle())))
          .firstWhere((t) => t.amount < 0);
      await editLocally(source.copyWith(name: "Card top up"));
      await sync(pushOnly: true);
      Map<String, dynamic> after = await remoteSplit(live, transfer.id);
      expect(after["description"], "Card top up");
      expect(without(after, {"description"}), without(before, {"description"}));
    });

    test('one split of a group: an edit and a delete leave the others',
        () async {
      LiveResponse group = await live.post("/transactions", {
        "group_title": "Shopping",
        "transactions": [
          {
            "type": "withdrawal",
            "date": "2024-05-05T10:00:00Z",
            "amount": "5",
            "description": "Bread",
            "source_id": checking.toString(),
            "destination_name": "Shop",
          },
          {
            "type": "withdrawal",
            "date": "2024-05-05T10:00:00Z",
            "amount": "7",
            "description": "Milk",
            "source_id": checking.toString(),
            "destination_name": "Shop",
          },
        ]
      });
      expect(group.status, 200, reason: group.toString());
      int bread = int.parse(
          "${group.attributes["transactions"][0]["transaction_journal_id"]}");
      int milk = int.parse(
          "${group.attributes["transactions"][1]["transaction_journal_id"]}");
      await sync();
      Map<String, dynamic> milkBefore = await remoteSplit(live, group.id, 1);

      Transaction breadRow = await localRowOfGroup(group.id, journalId: bread);
      await editLocally(breadRow.copyWith(name: "Rye bread"));
      FireflySyncReport report = await sync(pushOnly: true);
      expect(report.failed, 0, reason: report.warnings.join("\n"));
      expect((await remoteSplit(live, group.id, 0))["description"],
          "Rye bread");
      expect(without(await remoteSplit(live, group.id, 1), {}),
          without(milkBefore, {}));

      Transaction breadNow = await localRowOfGroup(group.id, journalId: bread);
      await database.deleteTransaction(breadNow.transactionPk);
      await sync(pushOnly: true);
      LiveResponse left = await live.get("/transactions/${group.id}");
      List<dynamic> splits = left.attributes["transactions"];
      expect(splits, hasLength(1));
      expect("${splits.single["transaction_journal_id"]}", "$milk");
    });

    test('a reconciled transaction is not changed from here', () async {
      LiveResponse reconciled = await live.createWithdrawal(
        sourceId: checking,
        amount: "40",
        date: "2024-05-06T10:00:00Z",
        description: "Rent",
        extra: {"reconciled": true},
      );
      await sync();
      Map<String, dynamic> before = await remoteSplit(live, reconciled.id);
      Transaction row = await localRowOfGroup(reconciled.id);
      await editLocally(row.copyWith(amount: -45));
      FireflySyncReport report = await sync(pushOnly: true);
      expect(report.reverted, 1);
      expect(without(await remoteSplit(live, reconciled.id), {}),
          without(before, {}));
      expect((await localRowOfGroup(reconciled.id)).amount,
          closeTo(-40, 1e-9));
    });

    test('a transaction cannot be marked unpaid', () async {
      await sync();
      Map<String, dynamic> before = await remoteSplit(live, lunch);
      Transaction row = await localRowOfGroup(lunch);
      await editLocally(row.copyWith(paid: false));
      await sync(pushOnly: true);
      expect(without(await remoteSplit(live, lunch), {}), without(before, {}));
      expect((await localRowOfGroup(lunch)).paid, isTrue);
    });

    test('a deleted category is gone, its transactions stay uncategorized',
        () async {
      await sync();
      FireflySyncMapEntry map = (await fireflyMapsOfRemote(
              FireflySyncEntityType.category, food))
          .single;
      TransactionCategory category =
          await database.getCategoryInstance(map.localPk);
      await database.deleteCategory(category.categoryPk, category.order);
      await sync(pushOnly: true);
      expect((await live.get("/categories/$food")).status, 404);
      Map<String, dynamic> after = await remoteSplit(live, lunch);
      expect(after["category_id"], isNull);
      expect(after["description"], "Lunch");
      Transaction row = await localRowOfGroup(lunch);
      expect(row.categoryFk, kFireflyUncategorizedCategoryPk);
    });

    test('a deleted wallet deactivates the account and keeps its history',
        () async {
      await sync();
      FireflySyncMapEntry map = (await fireflyMapsOfRemote(
              FireflySyncEntityType.wallet, checking))
          .single;
      TransactionWallet wallet = await database.getWalletInstance(map.localPk);
      await database.deleteWallet(wallet.walletPk, wallet.order);
      await sync(pushOnly: true);
      LiveResponse account = await live.get("/accounts/$checking");
      expect(account.attributes["active"], isFalse);
      expect((await live.get("/transactions/$lunch")).status, 200);
      TransactionWallet? hidden =
          await database.getWalletInstanceOrNull(wallet.walletPk);
      expect(hidden, isNotNull);
      expect(hidden!.archived, isTrue);
    });

    test('a renamed wallet changes the name only', () async {
      await sync();
      LiveResponse before = await live.get("/accounts/$savings");
      FireflySyncMapEntry map = (await fireflyMapsOfRemote(
              FireflySyncEntityType.wallet, savings))
          .single;
      TransactionWallet wallet = await database.getWalletInstance(map.localPk);
      await database.createOrUpdateWallet(wallet.copyWith(name: "Rainy day"));
      await sync(pushOnly: true);
      Map<String, dynamic> after =
          (await live.get("/accounts/$savings")).attributes;
      expect(after["name"], "Rainy day");
      expect(after["account_role"], "savingAsset");
      expect(after["virtual_balance"], before.attributes["virtual_balance"]);
      expect(after["currency_code"], before.attributes["currency_code"]);
    });

    test('a deleted transaction on the server goes here too', () async {
      await sync();
      await live.delete("/transactions/$lunch");
      // The transaction is older than the range that a routine pull tests
      // for deletes; the full pull finds it.
      bool ok = await fireflySyncNow(fullResync: true);
      expect(ok, isTrue, reason: fireflySyncErrorNotifier.value);
      FireflySyncReport report = fireflySyncReportNotifier.value!;
      expect(report.removedTransactions, 1);
      expect(
          await fireflyMapsOfRemote(FireflySyncEntityType.transaction, lunch),
          isEmpty);
    });

    test('a phone from the two-way sync is rebuilt on confirm, and the '
        'server does not change', () async {
      Map<String, dynamic> lunchSplit = await remoteSplit(live, lunch);
      int lunchJournal = int.parse("${lunchSplit["transaction_journal_id"]}");
      String lunchUpdated =
          (await live.get("/transactions/$lunch")).attributes["updated_at"];
      String checkingUpdated =
          (await live.get("/accounts/$checking")).attributes["updated_at"];

      // The local database of a phone that ran the two-way sync: map rows
      // with no snapshot, a tombstone, a balance anchor, a stale row, a
      // local-only paid row and an unpaid planning row.
      DateTime old = DateTime(2024, 6, 1);
      await database.into(database.wallets).insert(WalletsCompanion.insert(
          walletPk: const Value("w-check"),
          name: "Checking",
          order: 0,
          colour: const Value("0xff4caf50"),
          iconName: const Value("bank.png"),
          currency: const Value("eur"),
          dateTimeModified: Value(old)));
      await database.into(database.categories).insert(
          CategoriesCompanion.insert(
              categoryPk: const Value("c-food"),
              name: "Food",
              order: 0,
              colour: const Value("0xffff9800"),
              dateTimeModified: Value(old)));
      await database.into(database.categories).insert(
          CategoriesCompanion.insert(
              categoryPk: const Value("c-sub"),
              name: "Lunches",
              order: 0,
              mainCategoryPk: const Value("c-food"),
              dateTimeModified: Value(old)));
      Future<void> row(String pk, String name, double amount,
          {bool paid = true, String? sub}) async {
        await database.into(database.transactions).insert(
            TransactionsCompanion.insert(
                transactionPk: Value(pk),
                name: name,
                amount: amount,
                note: "",
                categoryFk: "c-food",
                subCategoryFk: Value(sub),
                walletFk: const Value("w-check"),
                dateCreated: Value(DateTime(2024, 5, 2)),
                dateTimeModified: Value(old),
                income: Value(amount > 0),
                paid: Value(paid)));
      }

      await row("t-lunch", "Lunch (stale)", -12.345, sub: "c-sub");
      await row("firefly-balance-anchor-w-check", "Firefly balance", 480);
      await row("t-coffee", "Coffee only here", -3);
      await row("t-rent", "Rent next month", -900, paid: false);
      Future<void> map(FireflySyncEntityType type, String pk, int id,
          {int? journal, bool tombstone = false}) {
        return database.into(database.fireflySyncMap).insert(
            FireflySyncMapCompanion.insert(
                entityType: type,
                localPk: pk,
                fireflyId: id,
                fireflyJournalId: Value(journal),
                isTombstone: Value(tombstone),
                lastSyncedLocalModified: Value(old)));
      }

      await map(FireflySyncEntityType.wallet, "w-check", checking);
      await map(FireflySyncEntityType.category, "c-food", food);
      await map(FireflySyncEntityType.transaction, "t-lunch", lunch,
          journal: lunchJournal);
      await map(FireflySyncEntityType.transaction, "t-gone", 99999,
          tombstone: true);

      // An automatic cycle does not rebuild.
      expect(await fireflySyncNow(), isFalse);
      expect(fireflySyncErrorNotifier.value, contains("rebuild"));
      expect(await database.getWalletInstance("w-check"), isNotNull);

      FireflySyncReport report = await sync();
      expect(report.failed, 0, reason: report.warnings.join("\n"));

      TransactionWallet wallet = await database.getWalletInstance("w-check");
      expect(wallet.colour, "0xff4caf50");
      expect(wallet.iconName, "bank.png");
      Transaction lunchRow = await localRowOfGroup(lunch);
      expect(lunchRow.transactionPk, "t-lunch");
      expect(lunchRow.name, "Lunch");
      expect(lunchRow.subCategoryFk, "c-sub");
      expect(
          (await database.getCategoryInstance("c-food")).colour, "0xffff9800");
      Future<Transaction?> local(String pk) =>
          (database.select(database.transactions)
                ..where((t) => t.transactionPk.equals(pk)))
              .getSingleOrNull();
      expect(await local("firefly-balance-anchor-w-check"), isNull);
      expect(await local("t-coffee"), isNull);
      expect(await local("t-rent"), isNotNull);
      for (FireflySyncMapEntry m
          in await database.select(database.fireflySyncMap).get()) {
        expect(m.remoteSnapshot, isNotNull, reason: m.localPk);
        expect(m.isTombstone, isFalse);
      }
      expect(report.warnings.where((w) => w.contains("balance of")), isEmpty,
          reason: report.warnings.join("\n"));

      expect((await live.get("/transactions/$lunch")).attributes["updated_at"],
          lunchUpdated);
      expect((await live.get("/accounts/$checking")).attributes["updated_at"],
          checkingUpdated);
      LiveResponse all = await live.get("/transactions", {"type": "all"});
      expect(all.json["meta"]["pagination"]["total"], 2,
          reason: "the lunch and the opening balance, nothing uploaded");
    });

    test('a renamed credit card keeps its card fields', () async {
      int card = await live.createAssetAccount('Visa', role: 'ccAsset', extra: {
        "credit_card_type": "monthlyFull",
        "monthly_payment_date": "2024-05-15",
      });
      await sync();
      FireflySyncMapEntry m =
          (await fireflyMapsOfRemote(FireflySyncEntityType.wallet, card)).single;
      TransactionWallet wallet = await database.getWalletInstance(m.localPk);
      await database.createOrUpdateWallet(wallet.copyWith(name: "Visa Gold"));
      FireflySyncReport report = await sync(pushOnly: true);
      expect(report.failed, 0, reason: report.warnings.join("\n"));
      Map<String, dynamic> after = (await live.get("/accounts/$card")).attributes;
      expect(after["name"], "Visa Gold");
      expect(after["account_role"], "ccAsset");
      expect(after["credit_card_type"], "monthlyFull");
    });

    test('an expense turned into income becomes a deposit', () async {
      await sync();
      Transaction row = await localRowOfGroup(lunch);
      await editLocally(row.copyWith(amount: 12.345, income: true));
      FireflySyncReport report = await sync(pushOnly: true);
      expect(report.failed, 0, reason: report.warnings.join("\n"));
      Map<String, dynamic> after = await remoteSplit(live, lunch);
      expect(after["type"], "deposit");
      expect(after["destination_id"], checking.toString());
      expect(after["source_name"], "Cafe");
      expect(double.parse(after["amount"]), closeTo(12.345, 1e-9));
    });

    test('a cleared note and a cleared category are cleared on the server',
        () async {
      await sync();
      Map<String, dynamic> before = await remoteSplit(live, lunch);
      Transaction row = await localRowOfGroup(lunch);
      await editLocally(row.copyWith(
          note: "", categoryFk: kFireflyUncategorizedCategoryPk));
      await sync(pushOnly: true);
      Map<String, dynamic> after = await remoteSplit(live, lunch);
      expect(after["notes"], isNull);
      expect(after["category_id"], isNull);
      expect(without(after, {"notes", "category_id", "category_name"}),
          without(before, {"notes", "category_id", "category_name"}));
    });

    test('a category merge moves every transaction, then deletes it',
        () async {
      int drinks = await live.createCategory('Drinks');
      LiveResponse beer = await live.createWithdrawal(
        sourceId: checking,
        amount: "4",
        date: "2023-02-01T18:00:00Z",
        description: "Beer",
        categoryId: drinks,
      );
      await sync();
      TransactionCategory from = await database.getCategoryInstance(
          (await fireflyMapsOfRemote(FireflySyncEntityType.category, drinks))
              .single
              .localPk);
      TransactionCategory to = await database.getCategoryInstance(
          (await fireflyMapsOfRemote(FireflySyncEntityType.category, food))
              .single
              .localPk);
      await database.mergeAndDeleteCategory(from, to);
      FireflySyncReport report = await sync(pushOnly: true);
      expect(report.failed, 0, reason: report.warnings.join("\n"));
      expect((await live.get("/categories/$drinks")).status, 404);
      expect((await remoteSplit(live, beer.id))["category_id"], "$food");
    });

    test('a category colour comes from the notes, and goes back there',
        () async {
      int travel = (await live.post("/categories", {
        "name": "Travel",
        "notes": "Trips and fares\ncolor: #12ab34",
      }))
          .id;
      await sync();
      TransactionCategory category = await database.getCategoryInstance(
          (await fireflyMapsOfRemote(FireflySyncEntityType.category, travel))
              .single
              .localPk);
      expect(category.colour, "0xff12ab34");

      // A rename does not touch the notes.
      await database.createOrUpdateCategory(category.copyWith(name: "Trips"));
      await sync(pushOnly: true);
      Map<String, dynamic> renamed =
          (await live.get("/categories/$travel")).attributes;
      expect(renamed["name"], "Trips");
      expect(renamed["notes"], "Trips and fares\ncolor: #12ab34");

      // A new colour replaces the hex digits and keeps the rest of the text.
      category = await database.getCategoryInstance(category.categoryPk);
      await database
          .createOrUpdateCategory(category.copyWith(colour: Value("0xffff8800")));
      await sync(pushOnly: true);
      Map<String, dynamic> recoloured =
          (await live.get("/categories/$travel")).attributes;
      expect(recoloured["notes"], "Trips and fares\ncolor: #ff8800");
      expect(recoloured["name"], "Trips");

      // A colour set on the web comes here.
      LiveResponse web =
          await live.put("/categories/$travel", {"notes": "color: #0000ff"});
      expect(web.status, 200, reason: web.toString());
      await sync();
      expect((await database.getCategoryInstance(category.categoryPk)).colour,
          "0xff0000ff");

      // A category with no colour in the notes gets no notes from a sync.
      Map<String, dynamic> foodBefore =
          (await live.get("/categories/$food")).attributes;
      await sync();
      expect((await live.get("/categories/$food")).attributes["updated_at"],
          foodBefore["updated_at"]);
    });

    test('the payee and the tags come here, and a change goes back', () async {
      await sync();
      Transaction row = await localRowOfGroup(lunch);
      expect(row.payee, "Cafe");
      expect(row.tags, ["work"]);
      Map<String, dynamic> before = await remoteSplit(live, lunch);

      await editLocally(row.copyWith(
          payee: const Value("Bakery"), tags: const Value(["home", "work"])));
      FireflySyncReport report = await sync(pushOnly: true);
      expect(report.failed, 0, reason: report.warnings.join("\n"));
      Map<String, dynamic> after = await remoteSplit(live, lunch);
      expect(after["destination_name"], "Bakery");
      expect(after["destination_type"], "Expense account");
      expect(List.from(after["tags"])..sort(), ["home", "work"]);
      expect(
          without(after, {"destination_id", "destination_name", "tags"}),
          without(before, {"destination_id", "destination_name", "tags"}));

      // No payee is the cash account; no tags clears them.
      row = await localRowOfGroup(lunch);
      await editLocally(
          row.copyWith(payee: const Value(null), tags: const Value(null)));
      await sync(pushOnly: true);
      after = await remoteSplit(live, lunch);
      expect(after["destination_type"], "Cash account");
      expect(after["tags"], isEmpty);
    });

    test('a new transaction names its payee and its tags', () async {
      await sync();
      Transaction lunchRow = await localRowOfGroup(lunch);
      String pk = "phone-row-payee";
      await database.into(database.transactions).insert(
            lunchRow
                .copyWith(
                  transactionPk: pk,
                  name: "Groceries",
                  amount: -20,
                  payee: const Value("Market"),
                  tags: const Value(["weekly"]),
                  dateCreated: DateTime.utc(2024, 6, 1, 8),
                  dateTimeModified: Value(DateTime.now()),
                )
                .toCompanion(true),
          );
      await sync(pushOnly: true);
      List<FireflySyncMapEntry> maps = await (database
              .select(database.fireflySyncMap)
            ..where((m) => m.localPk.equals(pk)))
          .get();
      expect(maps, hasLength(1));
      Map<String, dynamic> created = await remoteSplit(live, maps.single.fireflyId);
      expect(created["destination_name"], "Market");
      expect(created["destination_type"], "Expense account");
      expect(created["tags"], ["weekly"]);
    });

    test('a subcategory is the tag "Parent/Child" on Firefly', () async {
      Map<String, dynamic> split = await remoteSplit(live, lunch);
      LiveResponse web = await live.put("/transactions/$lunch", {
        "transactions": [
          {
            "transaction_journal_id": split["transaction_journal_id"],
            "tags": ["work", "Food/Snacks"],
          }
        ]
      });
      expect(web.status, 200, reason: web.toString());
      await sync();
      Transaction row = await localRowOfGroup(lunch);
      expect(row.tags, ["work"]);
      expect(row.subCategoryFk, isNotNull);
      TransactionCategory sub =
          await database.getCategoryInstance(row.subCategoryFk!);
      expect(sub.name, "Snacks");
      expect(sub.mainCategoryPk, row.categoryFk);

      // A second subcategory of Food replaces the tag of the first one.
      TransactionCategory drinks = sub.copyWith(
          categoryPk: "sub-drinks", name: "Drinks", order: sub.order + 1);
      await database.createOrUpdateCategory(drinks, updateSharedEntry: false);
      await editLocally(row.copyWith(subCategoryFk: const Value("sub-drinks")));
      await sync(pushOnly: true);
      expect(List.from((await remoteSplit(live, lunch))["tags"])..sort(),
          ["Food/Drinks", "work"]);
    });

    test('a liability is a wallet, and a payment to it is two rows',
        () async {
      LiveResponse loan = await live.post("/accounts", {
        "name": "Car loan",
        "type": "liability",
        "liability_type": "loan",
        "liability_direction": "credit",
        "interest": "0",
        "interest_period": "monthly",
        "currency_code": "EUR",
      });
      expect(loan.status, 200, reason: loan.toString());
      LiveResponse payment = await live.post("/transactions", {
        "transactions": [
          {
            "type": "withdrawal",
            "date": "2024-05-03T09:00:00Z",
            "amount": "100",
            "description": "Loan payment",
            "source_id": checking.toString(),
            "destination_id": loan.id.toString(),
            "category_id": food.toString(),
          }
        ]
      });
      expect(payment.status, 200, reason: payment.toString());
      FireflySyncReport report = await sync();
      expect(report.warnings, isEmpty, reason: report.warnings.join("\n"));

      FireflySyncMapEntry loanMap =
          (await fireflyMapsOfRemote(FireflySyncEntityType.wallet, loan.id))
              .single;
      TransactionWallet loanWallet =
          await database.getWalletInstance(loanMap.localPk);
      expect(loanWallet.accountKind, "loan");
      List<FireflySyncMapEntry> legs =
          await fireflyMapsOfRemote(FireflySyncEntityType.transaction,
              payment.id);
      expect(legs, hasLength(2));

      // An edit of the amount keeps the type, the loan and the category.
      Map<String, dynamic> before = await remoteSplit(live, payment.id);
      Transaction row = await localRowOfGroup(payment.id);
      Transaction source = row.amount < 0
          ? row
          : await (database.select(database.transactions)
                ..where((t) => t.transactionPk.equals(row.pairedTransactionFk!)))
              .getSingle();
      await editLocally(source.copyWith(amount: -120));
      report = await sync();
      expect(report.failed, 0, reason: report.warnings.join("\n"));
      Map<String, dynamic> after = await remoteSplit(live, payment.id);
      expect(double.parse(after["amount"]), closeTo(120, 1e-9));
      expect(without(after, {"amount", "pc_amount"}),
          without(before, {"amount", "pc_amount"}));
      expect(report.warnings, isEmpty, reason: report.warnings.join("\n"));
    });

    test('a new transfer from an asset to a loan is a withdrawal', () async {
      LiveResponse loan = await live.post("/accounts", {
        "name": "Car loan",
        "type": "liability",
        "liability_type": "loan",
        "liability_direction": "credit",
        "interest": "0",
        "interest_period": "monthly",
        "currency_code": "EUR",
      });
      expect(loan.status, 200, reason: loan.toString());
      await sync();
      String checkingPk = (await fireflyMapsOfRemote(
              FireflySyncEntityType.wallet, checking))
          .single
          .localPk;
      String loanPk =
          (await fireflyMapsOfRemote(FireflySyncEntityType.wallet, loan.id))
              .single
              .localPk;
      Transaction template = await localRowOfGroup(lunch);
      DateTime now = DateTime.now();
      Transaction out = template.copyWith(
        transactionPk: "pay-out",
        pairedTransactionFk: const Value("pay-in"),
        name: "Pay the loan",
        amount: -75,
        walletFk: checkingPk,
        categoryFk: "0",
        subCategoryFk: const Value(null),
        payee: const Value(null),
        tags: const Value(null),
        income: false,
        dateCreated: DateTime.utc(2024, 6, 2, 9),
        dateTimeModified: Value(now),
      );
      Transaction into = out.copyWith(
        transactionPk: "pay-in",
        pairedTransactionFk: const Value("pay-out"),
        amount: 75,
        walletFk: loanPk,
        income: true,
      );
      await database.into(database.transactions).insert(out.toCompanion(true));
      await database.into(database.transactions).insert(into.toCompanion(true));
      FireflySyncReport report = await sync();
      expect(report.failed, 0, reason: report.warnings.join("\n"));
      FireflySyncMapEntry map = (await (database.select(database.fireflySyncMap)
                ..where((m) => m.localPk.equals("pay-out")))
              .get())
          .single;
      Map<String, dynamic> created = await remoteSplit(live, map.fireflyId);
      expect(created["type"], "withdrawal");
      expect(created["source_id"], checking.toString());
      expect(created["destination_id"], loan.id.toString());
      expect(report.warnings, isEmpty, reason: report.warnings.join("\n"));
    });

    test('a phone from client version 1 keeps the payee and the tags on its '
        'first edit', () async {
      LiveResponse loan = await live.post("/accounts", {
        "name": "Car loan",
        "type": "liability",
        "liability_type": "loan",
        "liability_direction": "credit",
        "interest": "0",
        "interest_period": "monthly",
        "currency_code": "EUR",
      });
      LiveResponse payment = await live.post("/transactions", {
        "transactions": [
          {
            "type": "withdrawal",
            "date": "2024-05-03T09:00:00Z",
            "amount": "100",
            "description": "Loan payment",
            "source_id": checking.toString(),
            "destination_id": loan.id.toString(),
          }
        ]
      });
      expect(payment.status, 200, reason: payment.toString());
      await sync();

      // What schema 52 and a build of client version 1 leave: the new
      // columns are empty, the liability is no wallet and its payment is one
      // row.
      await database.customStatement(
          "UPDATE transactions SET payee = NULL, tags = NULL");
      await database.customStatement(
          "UPDATE wallets SET archived = 0, account_kind = NULL");
      String loanWallet =
          (await fireflyMapsOfRemote(FireflySyncEntityType.wallet, loan.id))
              .single
              .localPk;
      List<FireflySyncMapEntry> legs = await fireflyMapsOfRemote(
          FireflySyncEntityType.transaction, payment.id);
      for (FireflySyncMapEntry leg in legs) {
        Transaction row = await (database.select(database.transactions)
              ..where((t) => t.transactionPk.equals(leg.localPk)))
            .getSingle();
        if (row.walletFk == loanWallet) {
          await (database.delete(database.transactions)
                ..where((t) => t.transactionPk.equals(leg.localPk)))
              .go();
          await fireflyDeleteMap(
              FireflySyncEntityType.transaction, leg.localPk);
        } else {
          await database.customStatement(
              "UPDATE transactions SET paired_transaction_fk = NULL, "
              "category_fk = ? WHERE transaction_pk = ?",
              [kFireflyUncategorizedCategoryPk, leg.localPk]);
          await database.customStatement(
              "UPDATE firefly_sync_map SET remote_snapshot = "
              "json_remove(remote_snapshot, '\$.leg') WHERE local_pk = ?",
              [leg.localPk]);
        }
      }
      await (database.delete(database.fireflySyncMap)
            ..where((m) => m.localPk.equals(loanWallet)))
          .go();
      await (database.delete(database.wallets)
            ..where((w) => w.walletPk.equals(loanWallet)))
          .go();
      appStateSettings["fireflyClientVersion"] = 1;
      expect(await fireflyNeedsRebuild(), isFalse);

      // The first edit after the upgrade changes the description only.
      Map<String, dynamic> before = await remoteSplit(live, lunch);
      Transaction row = await localRowOfGroup(lunch);
      await editLocally(row.copyWith(name: "Team lunch"));
      FireflySyncReport report = await sync(pushOnly: true);
      expect(report.failed, 0, reason: report.warnings.join("\n"));
      expect(appStateSettings["fireflyClientVersion"], kFireflyClientVersion);
      Map<String, dynamic> after = await remoteSplit(live, lunch);
      expect(after["description"], "Team lunch");
      expect(after["destination_name"], "Cafe");
      expect(after["tags"], ["work"]);
      expect(without(after, {"description"}), without(before, {"description"}));
      expect((await localRowOfGroup(lunch)).payee, "Cafe");

      // The payment to the loan is two rows again, and the loan a wallet.
      expect(
          await fireflyMapsOfRemote(
              FireflySyncEntityType.transaction, payment.id),
          hasLength(2));
      TransactionWallet loanAgain = await database.getWalletInstance(
          (await fireflyMapsOfRemote(FireflySyncEntityType.wallet, loan.id))
              .single
              .localPk);
      expect(loanAgain.accountKind, "loan");
      expect(report.warnings, isEmpty, reason: report.warnings.join("\n"));
    });

    test('a Firefly budget is an added-only budget, and the budget of a '
        'withdrawal goes both ways', () async {
      LiveResponse groceries = await live.post("/budgets", {"name": "Groceries"});
      expect(groceries.status, 200, reason: groceries.toString());
      DateTime now = DateTime.now();
      String day(DateTime d) =>
          "${d.year}-${d.month.toString().padLeft(2, "0")}-${d.day.toString().padLeft(2, "0")}";
      LiveResponse limit = await live.post("/budgets/${groceries.id}/limits", {
        "start": day(DateTime(now.year, now.month, 1)),
        "end": day(DateTime(now.year, now.month + 1, 0)),
        "amount": "300",
        "currency_code": "EUR",
      });
      expect(limit.status, 200, reason: limit.toString());
      LiveResponse fun = await live.post("/budgets", {
        "name": "Fun",
        "auto_budget_type": "reset",
        "auto_budget_amount": "200",
        "auto_budget_period": "weekly",
        "auto_budget_currency_code": "EUR",
      });
      expect(fun.status, 200, reason: fun.toString());
      Map<String, dynamic> split = await remoteSplit(live, lunch);
      LiveResponse web = await live.put("/transactions/$lunch", {
        "transactions": [
          {
            "transaction_journal_id": split["transaction_journal_id"],
            "budget_id": groceries.id.toString(),
          }
        ]
      });
      expect(web.status, 200, reason: web.toString());
      await live.post("/piggy-banks", {
        "name": "Holiday",
        "accounts": [
          {"account_id": checking.toString()}
        ],
        "target_amount": "1000",
        "start_date": "2026-01-01",
        "transaction_currency_code": "EUR",
      });
      await live.post("/bills", {
        "name": "Rent",
        "amount_min": "900",
        "amount_max": "1000",
        "date": "2026-01-01",
        "repeat_freq": "monthly",
        "currency_code": "EUR",
        "active": true,
      });
      await sync();

      String groceriesPk = (await fireflyMapsOfRemote(
              FireflySyncEntityType.budget, groceries.id))
          .single
          .localPk;
      Budget budget = await database.getBudgetInstance(groceriesPk);
      expect(budget.name, "Groceries");
      expect(budget.addedTransactionsOnly, isTrue);
      expect(budget.amount, closeTo(300, 1e-9));
      expect(budget.reoccurrence, BudgetReoccurence.monthly);
      Budget weekly = await database.getBudgetInstance((await fireflyMapsOfRemote(
              FireflySyncEntityType.budget, fun.id))
          .single
          .localPk);
      expect(weekly.reoccurrence, BudgetReoccurence.weekly);
      expect(weekly.amount, closeTo(200, 1e-9));
      Transaction row = await localRowOfGroup(lunch);
      expect(row.sharedReferenceBudgetPk, groceriesPk);
      expect(await fireflyCachedRecords(FireflySyncEntityType.piggyBank),
          hasLength(1));
      expect(await fireflyCachedRecords(FireflySyncEntityType.bill),
          hasLength(1));

      // A move to the other budget sends the budget only.
      Map<String, dynamic> before = await remoteSplit(live, lunch);
      await editLocally(
          row.copyWith(sharedReferenceBudgetPk: Value(weekly.budgetPk)));
      FireflySyncReport report = await sync(pushOnly: true);
      expect(report.failed, 0, reason: report.warnings.join("\n"));
      Map<String, dynamic> after = await remoteSplit(live, lunch);
      expect(after["budget_id"], fun.id.toString());
      expect(without(after, {"budget_id", "budget_name"}),
          without(before, {"budget_id", "budget_name"}));

      // No budget clears it.
      row = await localRowOfGroup(lunch);
      await editLocally(row.copyWith(sharedReferenceBudgetPk: const Value(null)));
      await sync(pushOnly: true);
      expect((await remoteSplit(live, lunch))["budget_id"], isNull);

      // A sync writes the budget back over a local edit of it.
      await database.into(database.budgets).insertOnConflictUpdate(
          budget.copyWith(amount: 5).toCompanion(true));
      await sync();
      expect((await database.getBudgetInstance(groceriesPk)).amount,
          closeTo(300, 1e-9));
    });
  }, reset: FireflyLiveReset.eachTest);
}
