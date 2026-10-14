// The test environment of the live tests: a real Firefly III test instance.
// These tests run only when FIREFLY_LIVE_URL is set, thus the normal suite
// and CI skip them. tool/firefly_remote_test.sh sets the three variables on
// the build server:
//   FIREFLY_LIVE_URL    the base URL of the instance, with no /api/v1
//   FIREFLY_LIVE_TOKEN  a personal access token of the one user
//   FIREFLY_LIVE_RESET  an absolute path to a script that restores the clean
//                       instance. Process.run does not expand "~".
//
// Do not set these variables for a server that holds real data. A reset
// deletes all of it.
import 'dart:convert';
import 'dart:io';

import 'package:budget/struct/firefly/fireflyApiClient.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

enum FireflyLiveReset {
  // A clean instance for each test. A reset takes approximately 0.4 s.
  eachTest,
  // One clean instance for all tests of the group. The tests share state.
  once,
  // No reset. The caller resets with FireflyLive.reset().
  none,
}

// The decoded answer of one raw request. `json` is empty for an answer with
// no body, for example the 204 of a DELETE.
class LiveResponse {
  final int status;
  final Map<String, dynamic> json;
  LiveResponse(this.status, this.json);

  // The "data" object of a single record.
  Map<String, dynamic> get data => Map<String, dynamic>.from(json["data"]);

  // The "attributes" of a single record.
  Map<String, dynamic> get attributes =>
      Map<String, dynamic>.from(data["attributes"]);

  int get id => int.parse(data["id"].toString());

  @override
  String toString() => "$status ${jsonEncode(json)}";
}

class FireflyLive {
  final String baseUrl;
  final String token;
  final String? resetScript;
  http.Client? _http;

  FireflyLive._(this.baseUrl, this.token, this.resetScript);

  static String? get _url {
    String? url = Platform.environment["FIREFLY_LIVE_URL"]?.trim();
    return url == null || url.isEmpty ? null : url;
  }

  // The live tests reset the server and write to it. Thus they run only
  // against an instance on this computer (the Docker test instance), never
  // against a server that can hold real data.
  static bool _isLoopback(String url) {
    String host = Uri.tryParse(url)?.host ?? "";
    return host == "127.0.0.1" || host == "localhost" || host == "::1";
  }

  // The reason to skip, or null when the instance is configured.
  static String? get skipReason {
    String? url = _url;
    if (url == null) {
      return "FIREFLY_LIVE_URL is not set; no Firefly III test instance";
    }
    if (!_isLoopback(url)) {
      return "FIREFLY_LIVE_URL is not on this computer. The live tests "
          "reset the server, thus they run only against a local test "
          "instance";
    }
    return null;
  }

  // An instance with an empty URL when the tests skip. The test bodies do
  // not run then, thus no request goes out.
  static FireflyLive fromEnvironment() {
    String url = _url ?? "";
    while (url.endsWith("/")) {
      url = url.substring(0, url.length - 1);
    }
    String? reset = Platform.environment["FIREFLY_LIVE_RESET"]?.trim();
    return FireflyLive._(
      url,
      Platform.environment["FIREFLY_LIVE_TOKEN"]?.trim() ?? "",
      reset == null || reset.isEmpty ? null : reset,
    );
  }

  // The test binding answers each HTTP request with an empty 400. An
  // HttpClient reads the override when it is made, thus this must run before
  // each client is made.
  static void _allowRealHttp() {
    HttpOverrides.global = null;
  }

  // A new client of the app for each call, so a test can close it.
  FireflyApiClient client() {
    _allowRealHttp();
    return FireflyApiClient(baseUrl: baseUrl, personalAccessToken: token);
  }

  Future<void> reset() async {
    if (resetScript == null) {
      throw StateError("FIREFLY_LIVE_RESET is not set. A live test needs a "
          "clean instance; set it to the absolute path of the reset script.");
    }
    ProcessResult result = await Process.run(resetScript!, const []);
    if (result.exitCode != 0) {
      throw StateError("The reset script failed (exit ${result.exitCode}): "
          "${result.stderr}${result.stdout}");
    }
  }

  void close() {
    _http?.close();
    _http = null;
  }

  Uri _uri(String path, Map<String, String>? query) {
    String clean = path.startsWith("/") ? path : "/$path";
    return Uri.parse("$baseUrl/api/v1$clean")
        .replace(queryParameters: query == null || query.isEmpty ? null : query);
  }

  // A raw request. It does not throw for a status that is not 2xx: a test
  // that checks a 422 reads the status and the errors itself.
  Future<LiveResponse> send(String method, String path,
      {Map<String, dynamic>? body, Map<String, String>? query}) async {
    _allowRealHttp();
    http.Client client = _http ??= http.Client();
    http.Request request = http.Request(method, _uri(path, query));
    request.headers.addAll({
      "Authorization": "Bearer $token",
      "Accept": "application/vnd.api+json",
      "Content-Type": "application/json",
    });
    if (body != null) request.body = jsonEncode(body);
    http.Response response =
        await http.Response.fromStream(await client.send(request));
    Map<String, dynamic> json = {};
    if (response.body.trim().isNotEmpty) {
      Object? decoded = jsonDecode(response.body);
      json = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{"body": decoded};
    }
    return LiveResponse(response.statusCode, json);
  }

  Future<LiveResponse> get(String path, [Map<String, String>? query]) =>
      send("GET", path, query: query);

  Future<LiveResponse> post(String path, Map<String, dynamic> body) =>
      send("POST", path, body: body);

  Future<LiveResponse> put(String path, Map<String, dynamic> body) =>
      send("PUT", path, body: body);

  Future<LiveResponse> delete(String path) => send("DELETE", path);

  // Setup must not fail in silence: a setup request that Firefly refuses
  // stops the test with the answer of the server.
  static LiveResponse _expectOk(LiveResponse response, String what) {
    if (response.status < 200 || response.status >= 300) {
      throw StateError("Firefly refused $what: $response");
    }
    return response;
  }

  // The instance has EUR as its primary currency. Give a currency to each
  // account that a test compares with a local wallet.
  Future<int> createAssetAccount(String name,
      {String currencyCode = "EUR",
      String role = "defaultAsset",
      Map<String, dynamic> extra = const {}}) async {
    LiveResponse response = await post("/accounts", {
      "name": name,
      "type": "asset",
      "account_role": role,
      "currency_code": currencyCode,
      ...extra,
    });
    return _expectOk(response, "the asset account '$name'").id;
  }

  Future<int> createCategory(String name) async {
    LiveResponse response = await post("/categories", {"name": name});
    return _expectOk(response, "the category '$name'").id;
  }

  // One group with one withdrawal split. `date` goes to Firefly as text, so
  // a test can send an offset, or no offset. Firefly makes the expense
  // account of `destinationName` when it does not exist.
  Future<LiveResponse> createWithdrawal({
    required int sourceId,
    required String amount,
    required String date,
    String description = "Live withdrawal",
    String destinationName = "Live shop",
    int? categoryId,
    String? externalId,
    Map<String, dynamic> extra = const {},
  }) async {
    LiveResponse response = await post("/transactions", {
      "error_if_duplicate_hash": false,
      "transactions": [
        {
          "type": "withdrawal",
          "date": date,
          "amount": amount,
          "description": description,
          "source_id": sourceId.toString(),
          "destination_name": destinationName,
          if (categoryId != null) "category_id": categoryId.toString(),
          if (externalId != null) "external_id": externalId,
          ...extra,
        }
      ],
    });
    return _expectOk(response, "the withdrawal '$description'");
  }
}

// Declares a group of live tests. The group skips when FIREFLY_LIVE_URL is
// not set. `reset` selects when the instance is restored.
void liveGroup(String description, void Function(FireflyLive live) body,
    {FireflyLiveReset reset = FireflyLiveReset.eachTest}) {
  FireflyLive live = FireflyLive.fromEnvironment();
  group(description, () {
    if (reset == FireflyLiveReset.once) setUpAll(live.reset);
    if (reset == FireflyLiveReset.eachTest) setUp(live.reset);
    tearDownAll(live.close);
    body(live);
  }, skip: FireflyLive.skipReason);
}
