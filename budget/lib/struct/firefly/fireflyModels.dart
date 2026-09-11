// Data models for the part of the Firefly III REST API that the sync engine
// uses. They keep the shape of Firefly's JSON. fireflyMapper.dart maps them to
// and from the local Drift rows.

// A record of the server that this app cannot read. One such record must
// not stop the cycle: the pull catches this, warns and leaves the record
// alone. Before, a missing field became a made-up value (a withdrawal of 0
// dated today) that the pull then wrote into the local database.
class FireflyMalformedRecordException implements Exception {
  final String message;
  FireflyMalformedRecordException(this.message);
  @override
  String toString() => "FireflyMalformedRecordException: $message";
}

// Firefly sends ids as strings. int.parse throws a FormatException that no
// layer of the app catches, and one unreadable record then ends every cycle.
int _parseId(dynamic value, String what) {
  int? parsed = value == null ? null : int.tryParse(value.toString());
  if (parsed == null) {
    throw FireflyMalformedRecordException("$what has no readable id: $value");
  }
  return parsed;
}

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
  // One of "asset", "expense", "revenue", "cash", "loan", "debt" or
  // "mortgage". The sync engine keeps only "asset" accounts as wallets.
  final String type;
  final String? currencyCode;
  final double? currentBalance;
  // Firefly rejects an asset account with no account_role and sends a 422
  // error. The field is not permitted for the other account types.
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
      id: _parseId(json["id"], "An account"),
      name: attributes["name"]?.toString() ?? "",
      type: attributes["type"]?.toString() ?? "asset",
      currencyCode: attributes["currency_code"]?.toString(),
      currentBalance: _parseDouble(attributes["current_balance"]),
      accountRole: attributes["account_role"]?.toString(),
      active:
          attributes["active"] == null ? true : attributes["active"] == true,
      createdAt: _parseDate(attributes["created_at"]),
      updatedAt: _parseDate(attributes["updated_at"]),
    );
  }

  Map<String, dynamic> toRequestJson() {
    return {
      "name": name,
      "type": type,
      if (currencyCode != null) "currency_code": currencyCode,
      // Keep the role that the remote account has. If you do not, an update
      // can change a savings account into a default account.
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
      id: _parseId(json["id"], "A category"),
      name: attributes["name"]?.toString() ?? "",
      createdAt: _parseDate(attributes["created_at"]),
      updatedAt: _parseDate(attributes["updated_at"]),
    );
  }

  Map<String, dynamic> toRequestJson() {
    return {"name": name};
  }
}

// One split in a Firefly transaction group.
class FireflyTransactionSplit {
  // withdrawal, deposit, transfer, reconciliation or opening balance.
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
  // The amount in the currency of the other account of a transfer between
  // two accounts of different currencies. Firefly counts `amount` in the
  // currency of the source account, and `foreignAmount` in the currency of
  // the destination account. A transfer that does not send them makes
  // Firefly count the source amount on the destination account.
  final double? foreignAmount;
  final String? foreignCurrencyCode;
  final String? notes;
  // The key of the local row that made this record. It is written on every
  // create, so a create whose answer never arrived can be found again: the
  // pull sees a record with an external id, finds the local row of that key
  // with no link, and links the two rather than making a second copy.
  final String? externalId;
  // The identity that Firefly gives to this split. It stays the same when a
  // sibling split is deleted, but the position in group.splits does not. The
  // sync map therefore matches on this value. It is null for a split that the
  // app builds for a create, because that split has no journal yet.
  final int? transactionJournalId;

  // True for a split that this request does not change. Firefly deletes a
  // split that the request does not include, so a request must send the id of
  // each unchanged split.
  final bool unchanged;

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
    this.foreignAmount,
    this.foreignCurrencyCode,
    this.notes,
    this.externalId,
    this.transactionJournalId,
    this.unchanged = false,
  });

  // Makes the entry that holds the id only. A PUT keeps a split that has
  // such an entry, and deletes a split that the request does not name.
  factory FireflyTransactionSplit.unchangedSplit(int transactionJournalId) {
    return FireflyTransactionSplit(
      type: "withdrawal",
      date: DateTime(2000),
      amount: 0,
      description: "",
      transactionJournalId: transactionJournalId,
      unchanged: true,
    );
  }

  factory FireflyTransactionSplit.fromJson(Map<String, dynamic> json) {
    // The three fields that decide what the row is and what it does to a
    // balance. A default for any of them writes a record the server does not
    // hold: "withdrawal" hides the type the pull is meant to skip, DateTime
    // .now() moves the row to today, and 0 empties it.
    String? type = json["type"]?.toString();
    DateTime? date = _parseDate(json["date"]);
    double? amount = _parseDouble(json["amount"]);
    if (type == null || type.isEmpty) {
      throw FireflyMalformedRecordException("A split has no type");
    }
    if (date == null) {
      throw FireflyMalformedRecordException(
          "A split has no readable date: ${json["date"]}");
    }
    if (amount == null) {
      throw FireflyMalformedRecordException(
          "A split has no readable amount: ${json["amount"]}");
    }
    return FireflyTransactionSplit(
      type: type,
      date: date,
      amount: amount,
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
      foreignAmount: _parseDouble(json["foreign_amount"]),
      foreignCurrencyCode: json["foreign_currency_code"]?.toString(),
      notes: json["notes"]?.toString(),
      externalId: json["external_id"]?.toString(),
      transactionJournalId: json["transaction_journal_id"] == null
          ? null
          : int.tryParse(json["transaction_journal_id"].toString()),
    );
  }

  Map<String, dynamic> toRequestJson() {
    if (unchanged) {
      return {"transaction_journal_id": transactionJournalId};
    }
    return {
      if (transactionJournalId != null)
        "transaction_journal_id": transactionJournalId,
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
      if (foreignAmount != null && foreignCurrencyCode != null)
        "foreign_amount": foreignAmount!.abs().toStringAsFixed(2),
      if (foreignAmount != null && foreignCurrencyCode != null)
        "foreign_currency_code": foreignCurrencyCode,
      if (notes != null) "notes": notes,
      if (externalId != null) "external_id": externalId,
    };
  }
}

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
      id: _parseId(json["id"], "A transaction"),
      groupTitle: attributes["group_title"]?.toString(),
      createdAt: _parseDate(attributes["created_at"]),
      updatedAt: _parseDate(attributes["updated_at"]),
      splits: transactionsJson
          .map((split) => FireflyTransactionSplit.fromJson(
              Map<String, dynamic>.from(split)))
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
