// The test environment of the sync engine: an in-memory database, mocked
// settings and secure storage, and a small Firefly III server on the loopback
// interface. The engine talks to it over real HTTP, thus a test covers the
// API client, the mapper and the engine together.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:sqlite3/open.dart' as sqlite_open;

// A Linux box without the sqlite development package has libsqlite3.so.0
// only, not the libsqlite3.so link that the sqlite3 package opens.
bool _sqliteOverrideSet = false;
void _useSystemSqlite() {
  if (_sqliteOverrideSet || !Platform.isLinux) return;
  _sqliteOverrideSet = true;
  sqlite_open.open.overrideFor(sqlite_open.OperatingSystem.linux, () {
    for (String name in ['libsqlite3.so', 'libsqlite3.so.0']) {
      try {
        return DynamicLibrary.open(name);
      } catch (_) {}
    }
    return DynamicLibrary.open('libsqlite3.so');
  });
}

class FakeRequest {
  final String method;
  final String path;
  final Map<String, dynamic>? body;
  FakeRequest(this.method, this.path, this.body);

  @override
  String toString() => "$method $path ${body == null ? '' : jsonEncode(body)}";
}

class FakeResponse {
  final int status;
  final Map<String, dynamic> json;
  FakeResponse(this.status, this.json);
}

String _isoNow() => DateTime.now().toUtc().toIso8601String();

// A small Firefly III. It holds asset accounts, categories and transaction
// groups, and answers the requests that the engine makes. `intercept` gives
// a test a way to answer one request itself, for example with an error, and
// `delayFor` a way to make one request slow.
class FakeFirefly {
  late HttpServer _server;
  final Map<int, Map<String, dynamic>> accounts = {};
  final Map<int, Map<String, dynamic>> categories = {};
  final Map<int, Map<String, dynamic>> transactionGroups = {};
  final List<FakeRequest> requests = [];
  int nextId = 1000;

  FutureOr<FakeResponse?> Function(FakeRequest request)? intercept;
  Duration? Function(String method, String path)? delayFor;

  String get baseUrl => "http://${_server.address.address}:${_server.port}";

  List<FakeRequest> requestsTo(String method, String path) => requests
      .where((r) => r.method == method && r.path == path)
      .toList(growable: false);

  Map<String, dynamic> addAccount(int id, String name,
      {String type = "asset",
      String? balance,
      bool active = true,
      String role = "defaultAsset",
      String currencyCode = "USD",
      String? updatedAt}) {
    Map<String, dynamic> account = {
      "type": "accounts",
      "id": id.toString(),
      "attributes": {
        "name": name,
        "type": type,
        "currency_code": currencyCode,
        if (balance != null) "current_balance": balance,
        "active": active,
        "account_role": role,
        "created_at": updatedAt ?? _isoNow(),
        "updated_at": updatedAt ?? _isoNow(),
      },
    };
    accounts[id] = account;
    return account;
  }

  Map<String, dynamic> addCategory(int id, String name) {
    Map<String, dynamic> category = {
      "type": "categories",
      "id": id.toString(),
      "attributes": {
        "name": name,
        "created_at": _isoNow(),
        "updated_at": _isoNow(),
      },
    };
    categories[id] = category;
    return category;
  }

  // One group with one split. `journalId` is the id of that split.
  Map<String, dynamic> addTransaction(int id, int journalId,
      {required String description,
      required String amount,
      required int sourceId,
      required int destinationId,
      String type = "withdrawal",
      DateTime? date,
      String? categoryId,
      String currencyCode = "USD",
      String? foreignAmount,
      String? foreignCurrencyCode,
      String? updatedAt}) {
    Map<String, dynamic> group = {
      "type": "transactions",
      "id": id.toString(),
      "attributes": {
        "group_title": null,
        "created_at": updatedAt ?? _isoNow(),
        "updated_at": updatedAt ?? _isoNow(),
        "transactions": [
          {
            "transaction_journal_id": journalId,
            "type": type,
            "date": (date ?? DateTime.now()).toUtc().toIso8601String(),
            "amount": amount,
            "description": description,
            "source_id": sourceId,
            "destination_id": destinationId,
            "currency_code": currencyCode,
            if (foreignAmount != null) "foreign_amount": foreignAmount,
            if (foreignCurrencyCode != null)
              "foreign_currency_code": foreignCurrencyCode,
            if (categoryId != null) "category_id": categoryId,
          }
        ],
      },
    };
    transactionGroups[id] = group;
    return group;
  }

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    String path = request.uri.path;
    String method = request.method;
    Map<String, dynamic>? body;
    if (method == 'POST' || method == 'PUT') {
      String raw = await utf8.decoder.bind(request).join();
      body = raw.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(raw));
    }
    FakeRequest record = FakeRequest(method, path, body);
    requests.add(record);

    Duration? delay = delayFor?.call(method, path);
    if (delay != null) await Future.delayed(delay);

    FakeResponse response =
        (await intercept?.call(record)) ?? _route(record, request.uri);
    request.response.statusCode = response.status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(response.json));
    await request.response.close();
  }

  FakeResponse _route(FakeRequest r, Uri uri) {
    List<String> parts = r.path.split("/").where((p) => p.isNotEmpty).toList();
    // parts: [api, v1, resource, id?, sub?]
    if (parts.length < 3 || parts[0] != "api" || parts[1] != "v1") {
      return FakeResponse(404, {"message": "unexpected ${r.method} ${r.path}"});
    }
    String resource = parts[2];
    int? id = parts.length > 3 ? int.tryParse(parts[3]) : null;
    String? sub = parts.length > 4 ? parts[4] : null;

    if (resource == "about") {
      return FakeResponse(200, {
        "data": {"version": "6.1.0", "api_version": "2.0.0", "os": "test"}
      });
    }

    if (resource == "accounts") {
      if (r.method == "GET" && id == null) {
        String? type = uri.queryParameters["type"];
        List<dynamic> list = accounts.values
            .where((a) => type == null || a["attributes"]["type"] == type)
            .toList();
        return FakeResponse(200, _paginated(list));
      }
      if (r.method == "GET" && id != null && sub == "transactions") {
        List<dynamic> list = transactionGroups.values.where((g) {
          List<dynamic> splits = g["attributes"]["transactions"];
          return splits
              .any((s) => s["source_id"] == id || s["destination_id"] == id);
        }).toList();
        return FakeResponse(200, _paginated(list));
      }
      if (r.method == "GET" && id != null) {
        Map<String, dynamic>? account = accounts[id];
        if (account == null) return FakeResponse(404, {"message": "no"});
        return FakeResponse(200, {"data": account});
      }
      if (r.method == "POST") {
        String name = r.body!["name"].toString();
        bool taken = accounts.values.any((a) =>
            a["attributes"]["name"].toString().trim().toLowerCase() ==
            name.trim().toLowerCase());
        if (taken) {
          return FakeResponse(422, {
            "message": "This account name is already in use.",
            "errors": {
              "name": ["This account name is already in use."]
            }
          });
        }
        int newId = nextId++;
        Map<String, dynamic> account = addAccount(newId, name,
            type: r.body!["type"]?.toString() ?? "asset",
            active: r.body!["active"] != false,
            role: r.body!["account_role"]?.toString() ?? "defaultAsset");
        return FakeResponse(200, {"data": account});
      }
      if (r.method == "PUT" && id != null) {
        Map<String, dynamic>? account = accounts[id];
        if (account == null) return FakeResponse(404, {"message": "no"});
        Map<String, dynamic> attributes =
            Map<String, dynamic>.from(account["attributes"]);
        r.body!.forEach((key, value) => attributes[key] = value);
        attributes["updated_at"] = _isoNow();
        account["attributes"] = attributes;
        return FakeResponse(200, {"data": account});
      }
      if (r.method == "DELETE" && id != null) {
        accounts.remove(id);
        return FakeResponse(204, {});
      }
    }

    if (resource == "categories") {
      if (r.method == "GET" && id == null) {
        return FakeResponse(200, _paginated(categories.values.toList()));
      }
      if (r.method == "GET" && id != null) {
        Map<String, dynamic>? category = categories[id];
        if (category == null) return FakeResponse(404, {"message": "no"});
        return FakeResponse(200, {"data": category});
      }
      if (r.method == "POST") {
        String name = r.body!["name"].toString();
        bool taken = categories.values.any((c) =>
            c["attributes"]["name"].toString().trim().toLowerCase() ==
            name.trim().toLowerCase());
        if (taken) {
          return FakeResponse(422, {
            "message": "The name is already in use.",
            "errors": {
              "name": ["The name is already in use."]
            }
          });
        }
        return FakeResponse(200, {"data": addCategory(nextId++, name)});
      }
      if (r.method == "PUT" && id != null) {
        Map<String, dynamic>? category = categories[id];
        if (category == null) return FakeResponse(404, {"message": "no"});
        category["attributes"]["name"] = r.body!["name"];
        category["attributes"]["updated_at"] = _isoNow();
        return FakeResponse(200, {"data": category});
      }
      if (r.method == "DELETE" && id != null) {
        categories.remove(id);
        return FakeResponse(204, {});
      }
    }

    if (resource == "transactions") {
      if (r.method == "GET" && id == null) {
        return FakeResponse(200, _paginated(transactionGroups.values.toList()));
      }
      if (r.method == "GET" && id != null) {
        Map<String, dynamic>? group = transactionGroups[id];
        if (group == null) return FakeResponse(404, {"message": "no"});
        return FakeResponse(200, {"data": group});
      }
      if (r.method == "POST") {
        int newId = nextId++;
        List<dynamic> splits = List<dynamic>.from(r.body!["transactions"] ?? [])
            .map((s) => {
                  ...Map<String, dynamic>.from(s),
                  "transaction_journal_id": nextId++,
                })
            .toList();
        Map<String, dynamic> group = {
          "type": "transactions",
          "id": newId.toString(),
          "attributes": {
            "group_title": r.body!["group_title"],
            "created_at": _isoNow(),
            "updated_at": _isoNow(),
            "transactions": splits,
          },
        };
        transactionGroups[newId] = group;
        return FakeResponse(200, {"data": group});
      }
      if (r.method == "PUT" && id != null) {
        Map<String, dynamic>? group = transactionGroups[id];
        if (group == null) return FakeResponse(404, {"message": "no"});
        List<dynamic> old = group["attributes"]["transactions"];
        List<dynamic> splits =
            List<dynamic>.from(r.body!["transactions"] ?? []).map((s) {
          Map<String, dynamic> split = Map<String, dynamic>.from(s);
          split["transaction_journal_id"] ??=
              old.isEmpty ? nextId++ : old.first["transaction_journal_id"];
          return split;
        }).toList();
        group["attributes"]["transactions"] = splits;
        group["attributes"]["updated_at"] = _isoNow();
        return FakeResponse(200, {"data": group});
      }
      if (r.method == "DELETE" && id != null) {
        transactionGroups.remove(id);
        return FakeResponse(204, {});
      }
    }

    if (resource == "transaction-journals" && r.method == "DELETE") {
      return FakeResponse(204, {});
    }

    return FakeResponse(404, {"message": "unexpected ${r.method} ${r.path}"});
  }

  Map<String, dynamic> _paginated(List<dynamic> data) => {
        "data": data,
        "meta": {
          "pagination": {
            "total": data.length,
            "count": data.length,
            "per_page": 50,
            "current_page": 1,
            "total_pages": 1,
          }
        },
      };
}

// The database, the settings and the server of one test.
class FireflyTestEnv {
  final FakeFirefly firefly;
  FireflyTestEnv._(this.firefly);

  static Future<FireflyTestEnv> create({DateTime? lastSyncedAt}) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // The test binding answers each HTTP request with an empty 400. The
    // engine must reach the fake server.
    HttpOverrides.global = null;
    _useSystemSqlite();

    SharedPreferences.setMockInitialValues({});
    sharedPreferences = await SharedPreferences.getInstance();
    FlutterSecureStorage.setMockInitialValues(
        {'fireflyPersonalAccessToken': 'test-token'});
    database = FinanceDatabase(NativeDatabase.memory());

    FakeFirefly firefly = FakeFirefly();
    await firefly.start();

    appStateSettings = {
      'fireflyEnabled': true,
      'fireflyHostUrl': firefly.baseUrl,
      'fireflyLastSyncedAt': lastSyncedAt?.toIso8601String() ?? '',
      'fireflyLinkedAt': '',
      'fireflySyncWindowDays': 30,
      'sharedBudgets': false,
      'outlinedIcons': false,
    };
    return FireflyTestEnv._(firefly);
  }

  Future<void> dispose() async {
    await firefly.stop();
    await database.close();
  }

  Future<TransactionWallet> insertWallet(String name,
      {DateTime? modified, String? currency}) async {
    int rowId = await database.into(database.wallets).insert(
        WalletsCompanion.insert(
            name: name,
            order: 0,
            currency: Value(currency),
            dateTimeModified: Value(modified)));
    return (database.select(database.wallets)
          ..where((w) => w.rowId.equals(rowId)))
        .getSingle();
  }

  Future<TransactionCategory> insertCategory(String name,
      {DateTime? modified}) async {
    int rowId = await database.into(database.categories).insert(
        CategoriesCompanion.insert(
            name: name, order: 0, dateTimeModified: Value(modified)));
    return (database.select(database.categories)
          ..where((c) => c.rowId.equals(rowId)))
        .getSingle();
  }

  Future<Transaction> insertTransaction({
    required String name,
    required double amount,
    required TransactionWallet wallet,
    required TransactionCategory category,
    DateTime? date,
    DateTime? modified,
    bool paid = true,
  }) async {
    int rowId = await database.into(database.transactions).insert(
        TransactionsCompanion.insert(
            name: name,
            amount: amount,
            note: '',
            categoryFk: category.categoryPk,
            walletFk: Value(wallet.walletPk),
            dateCreated: Value(date ?? DateTime.now()),
            dateTimeModified: Value(modified ?? DateTime.now()),
            income: Value(amount > 0),
            paid: Value(paid)));
    return (database.select(database.transactions)
          ..where((t) => t.rowId.equals(rowId)))
        .getSingle();
  }

  Future<Transaction> reloadTransaction(String transactionPk) {
    return (database.select(database.transactions)
          ..where((t) => t.transactionPk.equals(transactionPk)))
        .getSingle();
  }

  Future<void> mapRow(
    FireflySyncEntityType type,
    String localPk,
    int fireflyId, {
    DateTime? lastSyncedLocalModified,
    DateTime? fireflyUpdatedAt,
    int? journalId,
    int splitIndex = 0,
  }) async {
    await database.into(database.fireflySyncMap).insert(
        FireflySyncMapCompanion.insert(
            entityType: type,
            localPk: localPk,
            fireflyId: fireflyId,
            fireflyUpdatedAt: Value(fireflyUpdatedAt),
            lastSyncedLocalModified: Value(lastSyncedLocalModified),
            fireflySplitIndex: Value(splitIndex),
            fireflyJournalId: Value(journalId)));
  }

  Future<FireflySyncMapEntry?> mapFor(
      FireflySyncEntityType type, String localPk) {
    return (database.select(database.fireflySyncMap)
          ..where((tbl) =>
              tbl.entityType.equalsValue(type) &
              tbl.localPk.equals(localPk) &
              tbl.isTombstone.equals(false)))
        .getSingleOrNull();
  }
}
