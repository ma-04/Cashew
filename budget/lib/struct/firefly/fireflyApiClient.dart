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
    while (trimmed.endsWith("/")) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
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

  Future<List<FireflyAccount>> getAccounts({String type = "asset"}) async {
    List<Map<String, dynamic>> pages =
        await _getAllPages("/accounts", {"type": type});
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

  Future<void> deleteTransaction(int id) => _delete("/transactions/$id");

  String _formatDate(DateTime date) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    return "${date.year}-${twoDigits(date.month)}-${twoDigits(date.day)}";
  }

  // Follows Firefly's JSON:API pagination (meta.pagination.total_pages).
  Future<List<Map<String, dynamic>>> _getAllPages(
      String path, Map<String, dynamic> query) async {
    List<Map<String, dynamic>> results = [];
    int page = 1;
    while (true) {
      Map<String, dynamic> pageQuery = Map<String, dynamic>.from(query);
      pageQuery["page"] = page;
      Map<String, dynamic> json = await _get(path, pageQuery);
      List<dynamic> data = List<dynamic>.from(json["data"] ?? []);
      results.addAll(data.map((item) => Map<String, dynamic>.from(item)));

      Map<String, dynamic>? meta = json["meta"] == null
          ? null
          : Map<String, dynamic>.from(json["meta"]);
      Map<String, dynamic>? pagination = meta?["pagination"] == null
          ? null
          : Map<String, dynamic>.from(meta!["pagination"]);
      int totalPages = pagination == null
          ? 1
          : int.tryParse(pagination["total_pages"].toString()) ?? 1;
      if (page >= totalPages || data.isEmpty) break;
      page++;
    }
    return results;
  }

  void close() {
    _client.close();
  }
}
