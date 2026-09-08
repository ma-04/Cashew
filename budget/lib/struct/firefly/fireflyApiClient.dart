// Thin REST client for a self-hosted Firefly III instance
// (https://api-docs.firefly-iii.org/), authenticated with a Personal Access
// Token (Firefly's "local_bearer_auth" scheme).
//
// Pure Dart + package:http - no Flutter imports, so this is unit-testable
// with package:http/testing.dart's MockClient without a widget harness.

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:budget/struct/firefly/fireflyModels.dart';

class FireflyAuthException implements Exception {
  final String message;
  FireflyAuthException([this.message = "Invalid or expired access token"]);
  @override
  String toString() => "FireflyAuthException: $message";
}

class FireflyRateLimitException implements Exception {
  final String message;
  FireflyRateLimitException([this.message = "Rate limited by Firefly server"]);
  @override
  String toString() => "FireflyRateLimitException: $message";
}

class FireflyNetworkException implements Exception {
  final String message;
  FireflyNetworkException(this.message);
  @override
  String toString() => "FireflyNetworkException: $message";
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
  final http.Client _client;

  FireflyApiClient({
    required String baseUrl,
    required this.personalAccessToken,
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
      throw FireflyRateLimitException();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FireflyNetworkException(
          "HTTP ${response.statusCode}: ${response.body}");
    }
    if (response.body.isEmpty) return {};
    return Map<String, dynamic>.from(jsonDecode(response.body));
  }

  Future<Map<String, dynamic>> _get(String path,
      [Map<String, dynamic>? query]) async {
    try {
      http.Response response =
          await _client.get(_uri(path, query), headers: _headers);
      return await _handleResponse(response);
    } on http.ClientException catch (e) {
      throw FireflyNetworkException(e.message);
    }
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    try {
      http.Response response = await _client.post(_uri(path),
          headers: _headers, body: jsonEncode(body));
      return await _handleResponse(response);
    } on http.ClientException catch (e) {
      throw FireflyNetworkException(e.message);
    }
  }

  Future<Map<String, dynamic>> _put(String path, Map<String, dynamic> body) async {
    try {
      http.Response response = await _client.put(_uri(path),
          headers: _headers, body: jsonEncode(body));
      return await _handleResponse(response);
    } on http.ClientException catch (e) {
      throw FireflyNetworkException(e.message);
    }
  }

  Future<void> _delete(String path) async {
    try {
      http.Response response =
          await _client.delete(_uri(path), headers: _headers);
      await _handleResponse(response);
    } on http.ClientException catch (e) {
      throw FireflyNetworkException(e.message);
    }
  }

  // Used for "Test Connection" - hits the lightest authenticated endpoint.
  Future<FireflyAbout> getAbout() async {
    Map<String, dynamic> json = await _get("/about");
    return FireflyAbout.fromJson(json);
  }

  // ---- Accounts ----

  Future<List<FireflyAccount>> getAccounts({String? type}) async {
    Map<String, dynamic> query = {};
    if (type != null) query["type"] = type;
    List<Map<String, dynamic>> pages = await _getAllPages("/accounts", query);
    return pages.map((json) => FireflyAccount.fromJson(json)).toList();
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

  // Single-account read, used to refresh a balance on demand without pulling
  // the whole account list.
  Future<FireflyAccount> getAccount(int id) async {
    Map<String, dynamic> json = await _get("/accounts/$id");
    return FireflyAccount.fromJson(
        Map<String, dynamic>.from(json["data"]));
  }

  // ---- Categories ----

  Future<List<FireflyCategory>> getCategories() async {
    List<Map<String, dynamic>> pages = await _getAllPages("/categories", {});
    return pages.map((json) => FireflyCategory.fromJson(json)).toList();
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

  // ---- Transactions ----

  // Firefly's list endpoint filters by date range (start/end), not by an
  // "updated since" cursor - the sync engine windows this itself.
  Future<List<FireflyTransactionGroup>> getTransactions({
    DateTime? start,
    DateTime? end,
  }) async {
    Map<String, dynamic> query = {};
    if (start != null) query["start"] = _formatDate(start);
    if (end != null) query["end"] = _formatDate(end);
    List<Map<String, dynamic>> pages =
        await _getAllPages("/transactions", query);
    return pages.map((json) => FireflyTransactionGroup.fromJson(json)).toList();
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

  // Transactions belonging to one asset account, optionally date-bounded.
  // Backs "load older transactions for this account" without widening the
  // whole sync window.
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

  // Full-text search across transactions, used to reach records that fall
  // outside the locally cached window.
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

  String _formatDate(DateTime date) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    return "${date.year}-${twoDigits(date.month)}-${twoDigits(date.day)}";
  }

  // Follows Firefly's JSON:API pagination (meta.pagination.total_pages).
  static const int _kPageSize = 50;

  // Hard stop so a server that keeps reporting "there is another page" cannot
  // spin this loop forever. 2000 pages x 50 = 100k records.
  static const int _kMaxPages = 2000;

  // Fetches every page of a list endpoint.
  //
  // This MUST either return the complete result set or throw. Callers
  // (notably the sync engine's delete reconciliation) treat the returned list
  // as the authoritative remote state and delete local rows that are missing
  // from it - so silently returning a truncated list here would destroy user
  // data. Every ambiguous response is therefore an exception, never an early
  // `break`.
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

      Map<String, dynamic>? meta = json["meta"] == null
          ? null
          : Map<String, dynamic>.from(json["meta"]);
      Map<String, dynamic>? pagination = meta?["pagination"] == null
          ? null
          : Map<String, dynamic>.from(meta!["pagination"]);

      if (pagination == null) {
        // Firefly always sends meta.pagination on its list endpoints. Its
        // absence means we are talking to something we do not understand, so
        // we cannot know whether more pages exist. A short page is safe to
        // treat as the end; a full page is not.
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
      // A page that came back empty while the server still claims more pages
      // follow would loop forever; treat it as a broken response.
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
