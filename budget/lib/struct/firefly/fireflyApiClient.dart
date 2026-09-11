// REST client for a self-hosted Firefly III instance. It uses a Personal
// Access Token, which is Firefly's "local_bearer_auth" scheme.
//
// This file has no Flutter imports. A test can therefore drive it with the
// MockClient from package:http/testing.dart and no widget harness.

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:budget/struct/firefly/fireflyModels.dart';

// The name that this client sends in the User-Agent header. Without it the
// Firefly log shows only "Dart/3.3 (dart:io)", which does not tell the user
// which application made the request.
const String kFireflyUserAgent = "Cashew-FireflySync";

// Every request gets this deadline. package:http has none of its own: a
// connection that the server accepts and then never answers leaves the await
// pending for ever. The sync engine holds a lock for the length of a cycle,
// so one such request stops every later sync until the app restarts.
const Duration kFireflyRequestTimeout = Duration(seconds: 30);

// A 429 answer with a Retry-After no longer than this is waited out inside
// the client. A longer one ends the cycle, which the user can start again.
const Duration kFireflyMaxRetryAfterWait = Duration(seconds: 5);

class FireflyAuthException implements Exception {
  final String message;
  FireflyAuthException([this.message = "Invalid or expired access token"]);
  @override
  String toString() => "FireflyAuthException: $message";
}

class FireflyRateLimitException implements Exception {
  final String message;
  // The Retry-After header of the answer, in seconds, when the server sent
  // one. The client waits for it itself if it is short; a longer wait ends
  // the cycle and this value tells the user when to try again.
  final int? retryAfterSeconds;
  FireflyRateLimitException(
      [this.message = "Rate limited by Firefly server",
      this.retryAfterSeconds]);
  @override
  String toString() => retryAfterSeconds == null
      ? "FireflyRateLimitException: $message"
      : "FireflyRateLimitException: $message (retry after "
          "${retryAfterSeconds}s)";
}

class FireflyNetworkException implements Exception {
  final String message;
  FireflyNetworkException(this.message);
  @override
  String toString() => "FireflyNetworkException: $message";
}

// A 422 answer: Firefly refused the record. The body names the field, for
// example a name that another record of the same type holds.
class FireflyValidationException extends FireflyNetworkException {
  FireflyValidationException(String message) : super(message);

  bool get isNameInUse => message.contains("already in use");

  @override
  String toString() => "FireflyValidationException: $message";
}

class FireflyNotFoundException implements Exception {
  final String message;
  FireflyNotFoundException([this.message = "Resource not found on Firefly"]);
  @override
  String toString() => "FireflyNotFoundException: $message";
}

class FireflyApiClient {
  final String baseUrl;
  final String personalAccessToken;
  final String userAgent;
  final http.Client _client;

  FireflyApiClient({
    required String baseUrl,
    required this.personalAccessToken,
    this.userAgent = kFireflyUserAgent,
    http.Client? client,
  })  : baseUrl = _normalizeBaseUrl(baseUrl),
        _client = client ?? http.Client();

  static String _normalizeBaseUrl(String url) {
    String trimmed = url.trim();
    if (trimmed.isNotEmpty && !trimmed.contains("://")) {
      trimmed = "https://$trimmed";
    }
    while (trimmed.endsWith("/")) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    if (trimmed.toLowerCase().endsWith("/api/v1")) {
      trimmed = trimmed.substring(0, trimmed.length - 7);
    }
    return trimmed;
  }

  Map<String, String> get _headers => {
        "Authorization": "Bearer $personalAccessToken",
        "Accept": "application/vnd.api+json",
        "Content-Type": "application/json",
        "User-Agent": userAgent,
      };

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    Map<String, String> stringQuery = {};
    query?.forEach((key, value) {
      if (value != null) stringQuery[key] = value.toString();
    });
    return Uri.parse("$baseUrl/api/v1$path")
        .replace(queryParameters: stringQuery.isEmpty ? null : stringQuery);
  }

  Future<Map<String, dynamic>> _handleResponse(http.Response response) async {
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw FireflyAuthException();
    }
    if (response.statusCode == 404) {
      throw FireflyNotFoundException();
    }
    if (response.statusCode == 429) {
      throw FireflyRateLimitException(
          "Rate limited by Firefly server", _retryAfterSeconds(response));
    }
    if (response.statusCode == 422) {
      throw FireflyValidationException(
          "HTTP ${response.statusCode}: ${response.body}");
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FireflyNetworkException(
          "HTTP ${response.statusCode}: ${response.body}");
    }
    if (response.body.isEmpty) return {};
    return Map<String, dynamic>.from(jsonDecode(response.body));
  }

  // Reads Retry-After. Firefly sends whole seconds; the HTTP date form is
  // permitted by the specification, thus it is read too.
  static int? _retryAfterSeconds(http.Response response) {
    String? header = response.headers["retry-after"];
    if (header == null) return null;
    int? seconds = int.tryParse(header.trim());
    if (seconds != null) return seconds < 0 ? 0 : seconds;
    DateTime? until = DateTime.tryParse(header.trim());
    if (until == null) return null;
    int delta = until.difference(DateTime.now()).inSeconds;
    return delta < 0 ? 0 : delta;
  }

  // The one place that makes a request. Every verb goes through it, so the
  // deadline and the answer to a 429 hold for all of them.
  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Map<String, dynamic>? body,
  }) async {
    Uri uri = _uri(path, query);
    String? payload = body == null ? null : jsonEncode(body);
    Future<http.Response> attempt() {
      switch (method) {
        case "GET":
          return _client.get(uri, headers: _headers);
        case "POST":
          return _client.post(uri, headers: _headers, body: payload);
        case "PUT":
          return _client.put(uri, headers: _headers, body: payload);
        case "DELETE":
          return _client.delete(uri, headers: _headers);
      }
      throw ArgumentError("Unknown method $method");
    }

    try {
      try {
        return await _handleResponse(
            await attempt().timeout(kFireflyRequestTimeout));
      } on FireflyRateLimitException catch (e) {
        // One wait, and only for a limit that lifts soon. Anything longer is
        // the caller's decision: the cycle ends and keeps its watermark.
        int? after = e.retryAfterSeconds;
        if (after == null || after > kFireflyMaxRetryAfterWait.inSeconds) {
          rethrow;
        }
        await Future.delayed(Duration(seconds: after));
        return await _handleResponse(
            await attempt().timeout(kFireflyRequestTimeout));
      }
    } on TimeoutException {
      // As a network failure, not as its own kind. The engine already ends
      // the cycle on one of those and keeps the changes in front of the
      // watermark, which is what a request with no answer needs.
      throw FireflyNetworkException("The Firefly server did not answer within "
          "${kFireflyRequestTimeout.inSeconds}s ($method $path)");
    } on http.ClientException catch (e) {
      throw FireflyNetworkException(e.message);
    }
  }

  Future<Map<String, dynamic>> _get(String path,
          [Map<String, dynamic>? query]) =>
      _send("GET", path, query: query);

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) =>
      _send("POST", path, body: body);

  Future<Map<String, dynamic>> _put(String path, Map<String, dynamic> body) =>
      _send("PUT", path, body: body);

  Future<void> _delete(String path) => _send("DELETE", path);

  // The "Test Connection" button uses this. It is the smallest request
  // that needs the token.
  Future<FireflyAbout> getAbout() async {
    Map<String, dynamic> json = await _get("/about");
    return FireflyAbout.fromJson(json);
  }

  // Records of a list that this app cannot read. One of them must not end
  // the cycle, and it must not pass silently either: the engine drains this
  // after a pull and reports each one as a warning.
  final List<String> _malformedRecords = [];

  List<String> takeMalformedRecordWarnings() {
    List<String> warnings = List<String>.from(_malformedRecords);
    _malformedRecords.clear();
    return warnings;
  }

  List<T> _readRecords<T>(
      List<Map<String, dynamic>> pages, T Function(Map<String, dynamic>) read) {
    List<T> records = [];
    for (Map<String, dynamic> json in pages) {
      try {
        records.add(read(json));
      } on FireflyMalformedRecordException catch (e) {
        _malformedRecords.add(e.message);
      }
    }
    return records;
  }

  Future<List<FireflyAccount>> getAccounts({String? type}) async {
    Map<String, dynamic> query = {};
    if (type != null) query["type"] = type;
    List<Map<String, dynamic>> pages = await _getAllPages("/accounts", query);
    return _readRecords(pages, FireflyAccount.fromJson);
  }

  Future<FireflyAccount> createAccount(FireflyAccount account) async {
    Map<String, dynamic> json =
        await _post("/accounts", account.toRequestJson());
    return FireflyAccount.fromJson(Map<String, dynamic>.from(json["data"]));
  }

  Future<FireflyAccount> updateAccount(int id, FireflyAccount account) async {
    Map<String, dynamic> json =
        await _put("/accounts/$id", account.toRequestJson());
    return FireflyAccount.fromJson(Map<String, dynamic>.from(json["data"]));
  }

  Future<void> deleteAccount(int id) => _delete("/accounts/$id");

  Future<FireflyAccount> getAccount(int id) async {
    Map<String, dynamic> json = await _get("/accounts/$id");
    return FireflyAccount.fromJson(Map<String, dynamic>.from(json["data"]));
  }

  Future<List<FireflyCategory>> getCategories() async {
    List<Map<String, dynamic>> pages = await _getAllPages("/categories", {});
    return _readRecords(pages, FireflyCategory.fromJson);
  }

  Future<FireflyCategory> createCategory(FireflyCategory category) async {
    Map<String, dynamic> json =
        await _post("/categories", category.toRequestJson());
    return FireflyCategory.fromJson(Map<String, dynamic>.from(json["data"]));
  }

  Future<FireflyCategory> updateCategory(
      int id, FireflyCategory category) async {
    Map<String, dynamic> json =
        await _put("/categories/$id", category.toRequestJson());
    return FireflyCategory.fromJson(Map<String, dynamic>.from(json["data"]));
  }

  Future<void> deleteCategory(int id) => _delete("/categories/$id");

  Future<FireflyCategory> getCategory(int id) async {
    Map<String, dynamic> json = await _get("/categories/$id");
    return FireflyCategory.fromJson(Map<String, dynamic>.from(json["data"]));
  }

  // Firefly filters this endpoint by booking date, not by an "updated since"
  // cursor. The sync engine applies its own window.
  Future<List<FireflyTransactionGroup>> getTransactions({
    DateTime? start,
    DateTime? end,
  }) async {
    Map<String, dynamic> query = {};
    if (start != null) query["start"] = _formatDate(start);
    if (end != null) query["end"] = _formatDate(end);
    List<Map<String, dynamic>> pages =
        await _getAllPages("/transactions", query);
    return _readRecords(pages, FireflyTransactionGroup.fromJson);
  }

  Future<FireflyTransactionGroup> createTransaction(
      FireflyTransactionGroup group) async {
    Map<String, dynamic> json =
        await _post("/transactions", group.toRequestJson());
    return FireflyTransactionGroup.fromJson(
        Map<String, dynamic>.from(json["data"]));
  }

  Future<FireflyTransactionGroup> updateTransaction(
      int id, FireflyTransactionGroup group) async {
    Map<String, dynamic> json =
        await _put("/transactions/$id", group.toRequestJson());
    return FireflyTransactionGroup.fromJson(
        Map<String, dynamic>.from(json["data"]));
  }

  Future<List<FireflyTransactionGroup>> getTransactionsForAccount(
    int accountId, {
    DateTime? start,
    DateTime? end,
  }) async {
    Map<String, dynamic> query = {};
    if (start != null) query["start"] = _formatDate(start);
    if (end != null) query["end"] = _formatDate(end);
    List<Map<String, dynamic>> pages =
        await _getAllPages("/accounts/$accountId/transactions", query);
    return pages.map((json) => FireflyTransactionGroup.fromJson(json)).toList();
  }

  Future<List<FireflyTransactionGroup>> searchTransactions(String query) async {
    List<Map<String, dynamic>> pages =
        await _getAllPages("/search/transactions", {"query": query});
    return pages.map((json) => FireflyTransactionGroup.fromJson(json)).toList();
  }

  Future<FireflyTransactionGroup> getTransaction(int id) async {
    Map<String, dynamic> json = await _get("/transactions/$id");
    return FireflyTransactionGroup.fromJson(
        Map<String, dynamic>.from(json["data"]));
  }

  Future<void> deleteTransaction(int id) => _delete("/transactions/$id");

  // Deletes one split and keeps the other splits of its group. A PUT that
  // rewrites the group would give the other splits new journal ids.
  Future<void> deleteTransactionJournal(int journalId) =>
      _delete("/transaction-journals/$journalId");

  String _formatDate(DateTime date) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    return "${date.year}-${twoDigits(date.month)}-${twoDigits(date.day)}";
  }

  static const int _kPageSize = 50;

  // A stop limit. A server that always reports one more page cannot make this
  // loop run forever. 2000 pages of 50 records is 100000 records.
  static const int _kMaxPages = 2000;

  // Returns the complete result set, or throws.
  //
  // The delete reconciliation in the sync engine reads this list as the full
  // remote state and deletes local rows that are absent from it. A short list
  // therefore destroys user data. Each unclear response throws.
  Future<List<Map<String, dynamic>>> _getAllPages(
      String path, Map<String, dynamic> query) async {
    List<Map<String, dynamic>> results = [];
    int page = 1;
    while (true) {
      Map<String, dynamic> pageQuery = Map<String, dynamic>.from(query);
      pageQuery["page"] = page;
      pageQuery["limit"] = _kPageSize;
      Map<String, dynamic> json = await _get(path, pageQuery);
      List<dynamic> data = List<dynamic>.from(json["data"] ?? []);
      results.addAll(data.map((item) => Map<String, dynamic>.from(item)));

      Map<String, dynamic>? meta =
          json["meta"] == null ? null : Map<String, dynamic>.from(json["meta"]);
      Map<String, dynamic>? pagination = meta?["pagination"] == null
          ? null
          : Map<String, dynamic>.from(meta!["pagination"]);

      if (pagination == null) {
        // Firefly sends meta.pagination on each list endpoint. If it is
        // absent, this is not a server we know, and the number of pages is
        // unknown. A short page is the end. A full page is not.
        if (data.length >= _kPageSize) {
          throw FireflyNetworkException(
              "Firefly returned a full page for $path with no pagination "
              "metadata, so the result set may be incomplete. Refusing to "
              "continue rather than risk acting on partial data.");
        }
        break;
      }

      String rawTotalPages = pagination["total_pages"].toString();
      int? totalPages = int.tryParse(rawTotalPages);
      if (totalPages == null) {
        throw FireflyNetworkException(
            "Firefly returned unparseable pagination metadata for $path "
            "(total_pages=$rawTotalPages). Refusing to continue rather than "
            "risk acting on partial data.");
      }

      if (page >= totalPages) break;
      // An empty page with more pages to come makes this loop run forever.
      if (data.isEmpty) {
        throw FireflyNetworkException(
            "Firefly returned an empty page $page of $totalPages for $path.");
      }
      page++;
      if (page > _kMaxPages) {
        throw FireflyNetworkException(
            "Firefly reported more than $_kMaxPages pages for $path.");
      }
    }
    return results;
  }

  void close() {
    _client.close();
  }
}
