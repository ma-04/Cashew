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
import 'package:budget/struct/firefly/client/fireflyStore.dart';
import 'package:budget/struct/firefly/fireflyMapper.dart'
    show kFireflyUncategorizedCategoryPk;
import 'package:budget/struct/firefly/fireflySyncEngine.dart';
import 'package:budget/struct/settings.dart';
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
      await sync();
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
      // A new instance has no cash account. The push then names one generic
      // account, never an account per description.
      expect(split["destination_name"], "Cash account");
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
      expect(await database.getWalletInstanceOrNull(wallet.walletPk),
          isNotNull);
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
  }, reset: FireflyLiveReset.eachTest);
}
