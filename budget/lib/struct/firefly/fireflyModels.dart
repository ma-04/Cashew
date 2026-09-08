// Plain Dart data models for the subset of the Firefly III REST API
// (https://api-docs.firefly-iii.org/) used by the sync engine.
//
// These intentionally mirror Firefly's JSON:API response shape rather than
// Cashew's local Drift tables - the mapping between the two lives in
// fireflyMapper.dart. No Flutter/DB imports here so this stays unit-testable.

double? _parseDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

DateTime? _parseDate(dynamic value) {
  if (value == null) return null;
  return DateTime.tryParse(value.toString());
}

class FireflyAccount {
  final int id;
  final String name;
  // Firefly account "type" e.g. "asset", "expense", "revenue", "cash",
  // "loan", "debt", "mortgage". Only "asset" accounts are synced as Wallets.
  final String type;
  final String? currencyCode;
  final double? currentBalance;
  // Firefly rejects an asset-account create/update that has no account_role
  // (422). It is meaningless for every other account type and must be omitted
  // there, so it is nullable and only emitted for assets.
  final String? accountRole;
  final bool active;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  FireflyAccount({
    required this.id,
    required this.name,
    required this.type,
    this.currencyCode,
    this.currentBalance,
    this.accountRole,
    this.active = true,
    this.createdAt,
    this.updatedAt,
  });

  factory FireflyAccount.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic> attributes =
        Map<String, dynamic>.from(json["attributes"] ?? {});
    return FireflyAccount(
      id: int.parse(json["id"].toString()),
      name: attributes["name"]?.toString() ?? "",
      type: attributes["type"]?.toString() ?? "asset",
      currencyCode: attributes["currency_code"]?.toString(),
      currentBalance: _parseDouble(attributes["current_balance"]),
      accountRole: attributes["account_role"]?.toString(),
      active: attributes["active"] == null ? true : attributes["active"] == true,
      createdAt: _parseDate(attributes["created_at"]),
      updatedAt: _parseDate(attributes["updated_at"]),
    );
  }

  Map<String, dynamic> toRequestJson() {
    return {
      "name": name,
      "type": type,
      if (currencyCode != null) "currency_code": currencyCode,
      // Required by Firefly for asset accounts, rejected for other types.
      // Preserve whatever role the remote account already had so a round-trip
      // update does not silently demote e.g. a savings account.
      if (type == "asset") "account_role": accountRole ?? "defaultAsset",
      "active": active,
    };
  }
}

class FireflyCategory {
  final int id;
  final String name;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  FireflyCategory({
    required this.id,
    required this.name,
    this.createdAt,
    this.updatedAt,
  });

  factory FireflyCategory.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic> attributes =
        Map<String, dynamic>.from(json["attributes"] ?? {});
    return FireflyCategory(
      id: int.parse(json["id"].toString()),
      name: attributes["name"]?.toString() ?? "",
      createdAt: _parseDate(attributes["created_at"]),
      updatedAt: _parseDate(attributes["updated_at"]),
    );
  }

  Map<String, dynamic> toRequestJson() {
    return {"name": name};
  }
}

// A single split within a Firefly transaction journal group.
// Firefly supports multi-split journals - Cashew does not, so the mapper
// only ever produces/consumes groups with exactly one split.
class FireflyTransactionSplit {
  // withdrawal | deposit | transfer | reconciliation | opening balance
  final String type;
  final DateTime date;
  final double amount;
  final String description;
  final int? sourceId;
  final String? sourceName;
  final int? destinationId;
  final String? destinationName;
  final int? categoryId;
  final String? categoryName;
  final String? currencyCode;
  final String? notes;
  // Firefly's stable identity for this split. Unlike the split's position in
  // group.splits it survives a sibling being deleted, so it - not the position
  // - is what the sync map matches on. Null for splits built locally for a
  // create, which have no journal yet.
  final int? transactionJournalId;

  FireflyTransactionSplit({
    required this.type,
    required this.date,
    required this.amount,
    required this.description,
    this.sourceId,
    this.sourceName,
    this.destinationId,
    this.destinationName,
    this.categoryId,
    this.categoryName,
    this.currencyCode,
    this.notes,
    this.transactionJournalId,
  });

  factory FireflyTransactionSplit.fromJson(Map<String, dynamic> json) {
    return FireflyTransactionSplit(
      type: json["type"]?.toString() ?? "withdrawal",
      date: _parseDate(json["date"]) ?? DateTime.now(),
      amount: _parseDouble(json["amount"]) ?? 0,
      description: json["description"]?.toString() ?? "",
      sourceId: json["source_id"] == null
          ? null
          : int.tryParse(json["source_id"].toString()),
      sourceName: json["source_name"]?.toString(),
      destinationId: json["destination_id"] == null
          ? null
          : int.tryParse(json["destination_id"].toString()),
      destinationName: json["destination_name"]?.toString(),
      categoryId: json["category_id"] == null
          ? null
          : int.tryParse(json["category_id"].toString()),
      categoryName: json["category_name"]?.toString(),
      currencyCode: json["currency_code"]?.toString(),
      notes: json["notes"]?.toString(),
      transactionJournalId: json["transaction_journal_id"] == null
          ? null
          : int.tryParse(json["transaction_journal_id"].toString()),
    );
  }

  Map<String, dynamic> toRequestJson() {
    return {
      "type": type,
      "date": date.toIso8601String(),
      "amount": amount.abs().toStringAsFixed(2),
      "description": description.isEmpty ? "(no description)" : description,
      if (sourceId != null) "source_id": sourceId.toString(),
      if (sourceId == null && sourceName != null) "source_name": sourceName,
      if (destinationId != null) "destination_id": destinationId.toString(),
      if (destinationId == null && destinationName != null)
        "destination_name": destinationName,
      if (categoryId != null) "category_id": categoryId.toString(),
      if (categoryId == null && categoryName != null)
        "category_name": categoryName,
      if (currencyCode != null) "currency_code": currencyCode,
      if (notes != null) "notes": notes,
      // transaction_journal_id is deliberately not sent. Whether Firefly's PUT
      // uses it to decide which existing journal each submitted split updates
      // is unverified; if it does, sending it would also stop PUTs destroying
      // and recreating journal rows, which is worth having but is a separate
      // change. Nothing here depends on it being sent - it is read-only state
      // used purely to identify splits on the way in.
    };
  }
}

// A transaction journal group - Firefly's top level transaction resource.
class FireflyTransactionGroup {
  final int id;
  final String? groupTitle;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final List<FireflyTransactionSplit> splits;

  FireflyTransactionGroup({
    required this.id,
    this.groupTitle,
    this.createdAt,
    this.updatedAt,
    required this.splits,
  });

  factory FireflyTransactionGroup.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic> attributes =
        Map<String, dynamic>.from(json["attributes"] ?? {});
    List<dynamic> transactionsJson =
        List<dynamic>.from(attributes["transactions"] ?? []);
    return FireflyTransactionGroup(
      id: int.parse(json["id"].toString()),
      groupTitle: attributes["group_title"]?.toString(),
      createdAt: _parseDate(attributes["created_at"]),
      updatedAt: _parseDate(attributes["updated_at"]),
      splits: transactionsJson
          .map((split) =>
              FireflyTransactionSplit.fromJson(Map<String, dynamic>.from(split)))
          .toList(),
    );
  }

  Map<String, dynamic> toRequestJson() {
    return {
      if (groupTitle != null) "group_title": groupTitle,
      "transactions": splits.map((split) => split.toRequestJson()).toList(),
    };
  }
}

class FireflyAbout {
  final String version;
  final String apiVersion;

  FireflyAbout({required this.version, required this.apiVersion});

  factory FireflyAbout.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic> data = Map<String, dynamic>.from(json["data"] ?? {});
    return FireflyAbout(
      version: data["version"]?.toString() ?? "",
      apiVersion: data["api_version"]?.toString() ?? "",
    );
  }
}
