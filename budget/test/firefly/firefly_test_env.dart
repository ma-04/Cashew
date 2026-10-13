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

// Firefly III 6.7.9 answers each date in the time zone of the user, to the
// second. The test instance and the fake both use UTC.
String fireflyDateString(DateTime date) {
  DateTime utc = date.toUtc();
  String two(int n) => n.toString().padLeft(2, "0");
  return "${utc.year.toString().padLeft(4, "0")}-${two(utc.month)}-"
      "${two(utc.day)}T${two(utc.hour)}:${two(utc.minute)}:"
      "${two(utc.second)}+00:00";
}

String _isoNow() => fireflyDateString(DateTime.now());

// Firefly reads a date with no offset as UTC, not as the local time of the
// client or of the server. A date with no time is the start of that day.
// DateTime.parse reads both as local time, thus it must not see them.
DateTime? readFireflyDate(Object? raw) {
  if (raw == null) return null;
  String text = raw.toString().trim();
  if (text.isEmpty) return null;
  if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text)) {
    text = "${text}T00:00:00Z";
  } else if (!RegExp(r'(Z|z|[+-]\d{2}:?\d{2})$').hasMatch(text)) {
    text = "${text}Z";
  }
  return DateTime.tryParse(text)?.toUtc();
}

// Firefly keeps 12 decimal places and answers with all of them, for example
// "10.123000000000". The value goes through as text: a double changes the
// digits that the client sent.
String fireflyAmountString(Object raw) {
  String text = raw.toString().trim();
  Match? match = RegExp(r'^(-?)(\d*)(?:\.(\d*))?$').firstMatch(text);
  if (match == null || (match[2]!.isEmpty && (match[3] ?? "").isEmpty)) {
    return text;
  }
  String whole = match[2]!.replaceFirst(RegExp(r'^0+(?=\d)'), "");
  if (whole.isEmpty) whole = "0";
  String fraction = (match[3] ?? "").padRight(12, "0").substring(0, 12);
  return "${match[1]}$whole.$fraction";
}

// The fields of a split that Firefly stores in its own form. A date or an
// amount that it cannot read stays as it is; the fake does not copy the
// validation of those fields.
Map<String, dynamic> _normalizeSplit(Map<String, dynamic> split) {
  if (split.containsKey("date")) {
    DateTime? date = readFireflyDate(split["date"]);
    if (date != null) split["date"] = fireflyDateString(date);
  }
  if (split["amount"] != null) {
    split["amount"] = fireflyAmountString(split["amount"]);
  }
  Object? foreignAmount = split["foreign_amount"];
  if (foreignAmount != null && foreignAmount.toString().trim().isNotEmpty) {
    split["foreign_amount"] = fireflyAmountString(foreignAmount);
  }
  return split;
}

bool _isBlank(Object? value) =>
    value == null || value.toString().trim().isEmpty;

// Laravel puts the first message of a 422 in "message", and the count of the
// other messages after it.
FakeResponse _validationError(Map<String, List<String>> errors) {
  List<String> messages = errors.values.expand((m) => m).toList();
  int more = messages.length - 1;
  String message = messages.first;
  if (more > 0) message += " (and $more more error${more == 1 ? '' : 's'})";
  return FakeResponse(422, {"message": message, "errors": errors});
}

// Firefly checks the request, not the stored account: a PUT that sends
// account_role ccAsset must send the two card fields again, also when the
// account already holds them.
FakeResponse? _creditCardErrors(Map<String, dynamic> body) {
  if (body["account_role"]?.toString() != "ccAsset") return null;
  Map<String, List<String>> errors = {};
  if (_isBlank(body["credit_card_type"])) {
    errors["credit_card_type"] = [
      "The credit card type field is required when account role is ccAsset."
    ];
  }
  if (_isBlank(body["monthly_payment_date"])) {
    errors["monthly_payment_date"] = [
      "The monthly payment date field is required when account role is "
          "ccAsset."
    ];
  }
  return errors.isEmpty ? null : _validationError(errors);
}

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
      String? virtualBalance,
      String? creditCardType,
      String? monthlyPaymentDate,
      String? notes,
      String? updatedAt}) {
    Map<String, dynamic> account = {
      "type": "accounts",
      "id": id.toString(),
      "attributes": {
        "name": name,
        "type": type,
        "currency_code": currencyCode,
        // The fake does not calculate a balance. It answers with the value
        // that the test gives. Firefly calculates virtual_balance plus the
        // sum of the journals, and rounds it to the decimals of the currency.
        if (balance != null) "current_balance": balance,
        "virtual_balance": virtualBalance,
        "active": active,
        "account_role": role,
        "credit_card_type": creditCardType,
        "monthly_payment_date": monthlyPaymentDate,
        "notes": notes,
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
      String? externalId,
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
            "date": fireflyDateString(date ?? DateTime.now()),
            "amount": fireflyAmountString(amount),
            "description": description,
            "source_id": sourceId,
            "destination_id": destinationId,
            "currency_code": currencyCode,
            if (foreignAmount != null)
              "foreign_amount": fireflyAmountString(foreignAmount),
            if (foreignCurrencyCode != null)
              "foreign_currency_code": foreignCurrencyCode,
            if (externalId != null) "external_id": externalId,
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
        return FakeResponse(200, _paginated(list, uri));
      }
      if (r.method == "GET" && id != null && sub == "transactions") {
        List<dynamic> list = transactionGroups.values.where((g) {
          List<dynamic> splits = g["attributes"]["transactions"];
          return splits
              .any((s) => s["source_id"] == id || s["destination_id"] == id);
        }).toList();
        return FakeResponse(200, _paginated(list, uri));
      }
      if (r.method == "GET" && id != null) {
        Map<String, dynamic>? account = accounts[id];
        if (account == null) return FakeResponse(404, {"message": "no"});
        return FakeResponse(200, {"data": account});
      }
      if (r.method == "POST") {
        FakeResponse? cardErrors = _creditCardErrors(r.body!);
        if (cardErrors != null) return cardErrors;
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
            role: r.body!["account_role"]?.toString() ?? "defaultAsset",
            currencyCode: r.body!["currency_code"]?.toString() ?? "USD");
        Map<String, dynamic> attributes = account["attributes"];
        for (String key in const [
          "virtual_balance",
          "credit_card_type",
          "monthly_payment_date",
          "notes",
          "include_net_worth",
          "iban",
          "account_number",
        ]) {
          if (r.body!.containsKey(key)) attributes[key] = r.body![key];
        }
        return FakeResponse(200, {"data": account});
      }
      if (r.method == "PUT" && id != null) {
        Map<String, dynamic>? account = accounts[id];
        if (account == null) return FakeResponse(404, {"message": "no"});
        FakeResponse? cardErrors = _creditCardErrors(r.body!);
        if (cardErrors != null) return cardErrors;
        // An account PUT changes the keys that it sends, and no other key. A
        // PUT with no account_role keeps the role and the card fields.
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
        return FakeResponse(200, _paginated(categories.values.toList(), uri));
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
        if (r.body!.containsKey("name")) {
          category["attributes"]["name"] = r.body!["name"];
        }
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
        // Firefly filters this endpoint by booking date. The engine relies on
        // it: _applyRemoteDeletes reads the answer as "every record of the
        // window", and a fake that answers with the whole ledger hides both
        // the window logic and what a short answer does to the local rows.
        // The end day is part of the window, to its last second.
        DateTime? start = _dateParam(uri, "start");
        DateTime? end = _dateParam(uri, "end")?.add(const Duration(days: 1));
        List<dynamic> list = transactionGroups.values.where((g) {
          List<dynamic> splits = g["attributes"]["transactions"];
          return splits.any((s) {
            DateTime? date = readFireflyDate(s["date"]);
            if (date == null) return true;
            if (start != null && date.isBefore(start)) return false;
            if (end != null && !date.isBefore(end)) return false;
            return true;
          });
        }).toList();
        return FakeResponse(200, _paginated(list, uri));
      }
      if (r.method == "GET" && id != null) {
        Map<String, dynamic>? group = transactionGroups[id];
        if (group == null) return FakeResponse(404, {"message": "no"});
        return FakeResponse(200, {"data": group});
      }
      if (r.method == "POST") {
        int newId = nextId++;
        List<dynamic> splits = List<dynamic>.from(r.body!["transactions"] ?? [])
            .map((s) => _normalizeSplit({
                  ...Map<String, dynamic>.from(s),
                  "transaction_journal_id": nextId++,
                }))
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
        // Firefly validates the request before it looks at the journal ids.
        // An entry that holds the id alone counts as an entry, and the title
        // that the group already holds does not count.
        List<dynamic> entries =
            List<dynamic>.from(r.body!["transactions"] ?? []);
        if (entries.length > 1 && _isBlank(r.body!["group_title"])) {
          return _validationError({
            "group_title": [
              "A group title is mandatory when there is more than one "
                  "transaction."
            ]
          });
        }
        List<dynamic> old = group["attributes"]["transactions"];
        Set<int> knownJournalIds = {
          for (dynamic s in old)
            if (s["transaction_journal_id"] != null)
              int.parse(s["transaction_journal_id"].toString())
        };
        // The contract that both incidents of this branch turned on, and that
        // the fake used to hide by re-attaching an id-less split to the first
        // split of the group:
        //   - a split with no transaction_journal_id is a NEW split;
        //   - a split whose id the group does not hold is refused, and
        //     Firefly answers 401 for it, not 404;
        //   - every split of the group that the request does not name is
        //     DELETED.
        //   - a split that the request names changes the keys that its entry
        //     sends, and keeps every other key (JournalUpdateService).
        List<dynamic> splits = [];
        for (dynamic entry in entries) {
          Map<String, dynamic> split = Map<String, dynamic>.from(entry);
          Object? rawJournalId = split["transaction_journal_id"];
          if (rawJournalId == null) {
            split["transaction_journal_id"] = nextId++;
            splits.add(_normalizeSplit(split));
            continue;
          }
          int journalId = int.parse(rawJournalId.toString());
          if (!knownJournalIds.contains(journalId)) {
            return FakeResponse(401, {
              "message": "Unauthenticated.",
            });
          }
          Map<String, dynamic> before = Map<String, dynamic>.from(
              old.firstWhere((s) =>
                  int.parse(s["transaction_journal_id"].toString()) ==
                  journalId));
          // An entry that holds the id alone keeps the split as it is.
          if (split.keys.length == 1) {
            splits.add(before);
            continue;
          }
          before.addAll(split);
          splits.add(_normalizeSplit(before));
        }
        if (r.body!.containsKey("group_title")) {
          group["attributes"]["group_title"] = r.body!["group_title"];
        }
        group["attributes"]["transactions"] = splits;
        group["attributes"]["updated_at"] = _isoNow();
        return FakeResponse(200, {"data": group});
      }
      if (r.method == "DELETE" && id != null) {
        transactionGroups.remove(id);
        return FakeResponse(204, {});
      }
    }

    if (resource == "search" &&
        parts.length > 3 &&
        parts[3] == "transactions" &&
        r.method == "GET") {
      List<String> words = (uri.queryParameters["query"] ?? "")
          .trim()
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .toList();
      List<dynamic> list = transactionGroups.values
          .where((g) => words.every((w) => _searchMatches(g, w)))
          .toList();
      return FakeResponse(200, _paginated(list, uri));
    }

    if (resource == "transaction-journals" && r.method == "DELETE") {
      // It removes one split of its group, and it answers 404 for an id that
      // no group holds. Answering 204 for everything hid both.
      for (MapEntry<int, Map<String, dynamic>> entry
          in transactionGroups.entries) {
        List<dynamic> splits = entry.value["attributes"]["transactions"];
        int before = splits.length;
        splits.removeWhere((s) =>
            s["transaction_journal_id"] != null &&
            int.parse(s["transaction_journal_id"].toString()) == id);
        if (splits.length == before) continue;
        entry.value["attributes"]["updated_at"] = _isoNow();
        // Firefly removes a group that holds no split.
        if (splits.isEmpty) transactionGroups.remove(entry.key);
        return FakeResponse(204, {});
      }
      return FakeResponse(404, {"message": "no such journal"});
    }

    return FakeResponse(404, {"message": "unexpected ${r.method} ${r.path}"});
  }

  static DateTime? _dateParam(Uri uri, String name) {
    String? raw = uri.queryParameters[name];
    if (raw == null || raw.isEmpty) return null;
    return readFireflyDate(raw);
  }

  // The operators of /search/transactions that the client uses. All words of
  // a query must match. Firefly reads a word with an operator that it does
  // not know as text, thus "updated_after:2020-01-01" finds nothing.
  //   - updated_at_after:D includes the day D (UTC on the test instance).
  //   - external_id_is:V is an exact match on one split.
  //   - other text matches part of a description, in any case.
  static bool _searchMatches(Map<String, dynamic> group, String word) {
    List<dynamic> splits = group["attributes"]["transactions"];
    int colon = word.indexOf(":");
    String operator = colon < 0 ? "" : word.substring(0, colon);
    String value = colon < 0 ? word : word.substring(colon + 1);
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    if (operator == "updated_at_after") {
      DateTime? after = readFireflyDate(value);
      DateTime? updated = readFireflyDate(group["attributes"]["updated_at"]);
      return after != null && updated != null && !updated.isBefore(after);
    }
    if (operator == "external_id_is") {
      return splits.any((s) => s["external_id"]?.toString() == value);
    }
    String needle = word.toLowerCase();
    return splits.any((s) =>
        (s["description"]?.toString() ?? "").toLowerCase().contains(needle));
  }

  // Real pagination. The client asks for a page and a limit and refuses a
  // full page that carries no metadata; a fake that always answers
  // "total_pages": 1 with every record left the paging code untested and let
  // a short answer read as the whole ledger.
  Map<String, dynamic> _paginated(List<dynamic> data, [Uri? uri]) {
    int perPage = int.tryParse(uri?.queryParameters["limit"] ?? "") ?? 50;
    if (perPage < 1) perPage = 50;
    int page = int.tryParse(uri?.queryParameters["page"] ?? "") ?? 1;
    if (page < 1) page = 1;
    int totalPages = data.isEmpty ? 1 : ((data.length - 1) ~/ perPage) + 1;
    int from = (page - 1) * perPage;
    List<dynamic> slice = from >= data.length
        ? const []
        : data.sublist(from, (from + perPage).clamp(0, data.length));
    return {
      "data": slice,
      "meta": {
        "pagination": {
          "total": data.length,
          "count": slice.length,
          "per_page": perPage,
          "current_page": page,
          "total_pages": totalPages,
        }
      },
    };
  }
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
