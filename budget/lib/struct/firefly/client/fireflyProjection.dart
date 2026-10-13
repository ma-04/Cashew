// The fields of a Firefly split that the local database can hold, read from
// a local row and from a Firefly record into one shape. A push compares the
// two and sends only the fields that differ. This is the rule that keeps the
// server data correct: a field that the user did not change is not sent, thus
// the push cannot change it.
//
// This file keeps no state and touches no database, no network and no global.

import 'package:budget/database/tables.dart';

// Keys of a projection. The names are the Firefly split keys where one exists.
const String kFieldType = "type";
const String kFieldDate = "date";
const String kFieldAmount = "amount";
const String kFieldDescription = "description";
const String kFieldNotes = "notes";
const String kFieldCategory = "category_id";
// The asset account of a withdrawal (its source) or of a deposit (its
// destination). A withdrawal and a deposit have one asset side and one other
// side; the local row knows the asset side only.
const String kFieldAsset = "asset";
const String kFieldSource = "source_id";
const String kFieldDestination = "destination_id";
const String kFieldForeignAmount = "foreign_amount";

// Fields that go to the server together or not at all. A change of type moves
// the asset account to the other side of the split, thus the type and the
// asset side are one decision.
const List<Set<String>> kFireflyCoupledFields = [
  {kFieldType, kFieldAsset},
];

// Firefly keeps amounts with 12 decimals. A double that came from such a
// string and goes back unchanged differs from it by much less than this.
const double kFireflyAmountTolerance = 1e-9;

typedef FireflyProjection = Map<String, Object?>;

bool fireflyFieldEquals(String key, Object? a, Object? b) {
  if (a == null || b == null) return a == b;
  if (key == kFieldDate) {
    // Firefly holds whole seconds and the local database holds whole seconds.
    return (a as DateTime).toUtc().millisecondsSinceEpoch ~/ 1000 ==
        (b as DateTime).toUtc().millisecondsSinceEpoch ~/ 1000;
  }
  if (key == kFieldAmount || key == kFieldForeignAmount) {
    return ((a as double) - (b as double)).abs() < kFireflyAmountTolerance;
  }
  return a == b;
}

// The keys whose values differ.
Set<String> fireflyDiff(FireflyProjection a, FireflyProjection b) {
  Set<String> keys = {...a.keys, ...b.keys};
  return keys.where((k) => !fireflyFieldEquals(k, a[k], b[k])).toSet();
}

class FireflyMergeResult {
  // The fields to send, with the local values.
  final FireflyProjection send;
  // Fields that the user changed and that the server changed too, to a
  // different value. The server value wins; the caller tells the user.
  final Set<String> conflicts;
  FireflyMergeResult(this.send, this.conflicts);
}

// The three-way merge of a push. `base` is the record as this app last read
// it, `local` the local row, `live` the record as the server holds it now.
// A field goes out only if the user changed it and the server did not.
FireflyMergeResult fireflyMerge({
  required FireflyProjection base,
  required FireflyProjection local,
  required FireflyProjection live,
}) {
  Set<String> changedHere = fireflyDiff(local, base);
  Set<String> changedThere = fireflyDiff(live, base);
  Set<String> drop = {};
  Set<String> conflicts = {};
  for (String key in changedHere) {
    if (!changedThere.contains(key)) continue;
    drop.add(key);
    if (!fireflyFieldEquals(key, live[key], local[key])) conflicts.add(key);
  }
  for (Set<String> group in kFireflyCoupledFields) {
    if (group.any(drop.contains)) drop.addAll(group);
  }
  FireflyProjection send = {
    for (String key in changedHere)
      if (!drop.contains(key)) key: local[key],
  };
  return FireflyMergeResult(send, conflicts);
}

// --- Reading a Firefly split ------------------------------------------------

int? fireflyParseInt(Object? value) =>
    value == null ? null : int.tryParse(value.toString());

double? fireflyParseAmount(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble().abs();
  return double.tryParse(value.toString())?.abs();
}

DateTime? fireflyParseDate(Object? value) =>
    value == null ? null : DateTime.tryParse(value.toString())?.toUtc();

String fireflySplitType(Map<String, dynamic> split) =>
    (split["type"] ?? "").toString().toLowerCase();

bool fireflySplitIsTransfer(Map<String, dynamic> split) =>
    fireflySplitType(split) == "transfer";

// The projection of a withdrawal or a deposit as the server holds it.
FireflyProjection fireflyProjectRemoteSplit(Map<String, dynamic> split) {
  String type = fireflySplitType(split);
  return {
    kFieldType: type,
    kFieldDate: fireflyParseDate(split["date"]),
    kFieldAmount: fireflyParseAmount(split["amount"]),
    kFieldDescription: (split["description"] ?? "").toString(),
    kFieldNotes: (split["notes"] ?? "").toString(),
    kFieldCategory: fireflyParseInt(split["category_id"]),
    kFieldAsset: type == "deposit"
        ? fireflyParseInt(split["destination_id"])
        : fireflyParseInt(split["source_id"]),
  };
}

// The projection of a transfer as the server holds it. A transfer has no
// category in the local database (both rows are in the balance-correction
// category), thus the category is not part of it.
FireflyProjection fireflyProjectRemoteTransfer(Map<String, dynamic> split) {
  return {
    kFieldType: "transfer",
    kFieldDate: fireflyParseDate(split["date"]),
    kFieldAmount: fireflyParseAmount(split["amount"]),
    kFieldDescription: (split["description"] ?? "").toString(),
    kFieldNotes: (split["notes"] ?? "").toString(),
    kFieldSource: fireflyParseInt(split["source_id"]),
    kFieldDestination: fireflyParseInt(split["destination_id"]),
    kFieldForeignAmount: fireflyParseAmount(split["foreign_amount"]),
  };
}

// --- Reading a local row ----------------------------------------------------

// Firefly needs a description; the local database permits an empty name.
const String kFireflyNoDescription = "(no description)";

// The projection of a local withdrawal or deposit. `assetAccountId` is the
// Firefly id of the account of the wallet of the row, `categoryId` the Firefly
// id of its category, or null for no category.
FireflyProjection fireflyProjectLocalRow(
  Transaction row, {
  required int assetAccountId,
  required int? categoryId,
}) {
  return {
    kFieldType: row.amount > 0 ? "deposit" : "withdrawal",
    kFieldDate: row.dateCreated.toUtc(),
    kFieldAmount: row.amount.abs(),
    kFieldDescription: row.name,
    kFieldNotes: row.note,
    kFieldCategory: categoryId,
    kFieldAsset: assetAccountId,
  };
}

// The projection of the two local rows of a transfer. `foreignAmount` is the
// amount of the destination row when the two wallets have different
// currencies, else null.
FireflyProjection fireflyProjectLocalTransfer({
  required Transaction source,
  required Transaction destination,
  required int sourceAccountId,
  required int destinationAccountId,
  required bool crossCurrency,
  // The text of a transfer lives on both rows. The caller gives the text of
  // the row that the user changed, see fireflyTransferText.
  required String description,
  required String notes,
}) {
  return {
    kFieldType: "transfer",
    kFieldDate: source.dateCreated.toUtc(),
    kFieldAmount: source.amount.abs(),
    kFieldDescription: description,
    kFieldNotes: notes,
    kFieldSource: sourceAccountId,
    kFieldDestination: destinationAccountId,
    kFieldForeignAmount: crossCurrency ? destination.amount.abs() : null,
  };
}

// The text of a transfer: the value of the row that differs from the server,
// or the source row when both or neither differ.
String fireflyTransferText(String source, String destination, String remote) {
  if (source != remote) return source;
  if (destination != remote) return destination;
  return source;
}

// --- Writing a request ------------------------------------------------------

// A date in UTC with a "Z". Firefly reads a date with no offset in the
// timezone of the server, thus a local time with no offset moves the record
// by the offset of the phone.
String fireflyFormatDate(DateTime date) {
  DateTime utc = date.toUtc();
  String two(int n) => n.toString().padLeft(2, "0");
  return "${utc.year.toString().padLeft(4, "0")}-${two(utc.month)}-"
      "${two(utc.day)}T${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}Z";
}

// An amount with as many decimals as it has, up to the 12 that Firefly keeps.
// A fixed 2 rounds a currency with 3 decimals and each amount that Firefly
// holds with more precision.
String fireflyFormatAmount(double amount) {
  String text = amount.abs().toStringAsFixed(12);
  text = text.replaceFirst(RegExp(r"0+$"), "");
  if (text.endsWith(".")) text = text.substring(0, text.length - 1);
  return text;
}

// The keys of a split request for the fields in `send`. `live` is the split
// as the server holds it now; a change of type takes the other side of the
// split from it.
Map<String, dynamic> fireflySplitRequestFields(
  FireflyProjection send, {
  Map<String, dynamic>? live,
}) {
  Map<String, dynamic> body = {};
  send.forEach((key, value) {
    switch (key) {
      case kFieldDate:
        body["date"] = fireflyFormatDate(value as DateTime);
        break;
      case kFieldAmount:
        body["amount"] = fireflyFormatAmount(value as double);
        break;
      case kFieldForeignAmount:
        // A transfer between two currencies only. Clearing it is not a case
        // the local rows can make, thus a null is not sent.
        if (value != null) {
          body["foreign_amount"] = fireflyFormatAmount(value as double);
        }
        break;
      case kFieldDescription:
        String text = (value as String).trim();
        body["description"] = text.isEmpty ? kFireflyNoDescription : value;
        break;
      case kFieldNotes:
        body["notes"] = value ?? "";
        break;
      case kFieldCategory:
        body["category_id"] = value?.toString();
        break;
      case kFieldSource:
        body["source_id"] = value.toString();
        break;
      case kFieldDestination:
        body["destination_id"] = value.toString();
        break;
      case kFieldType:
      case kFieldAsset:
        break;
    }
  });
  if (send.containsKey(kFieldType) || send.containsKey(kFieldAsset)) {
    _writeAccountSides(body, send, live);
  }
  return body;
}

void _writeAccountSides(Map<String, dynamic> body, FireflyProjection send,
    Map<String, dynamic>? live) {
  String liveType = live == null ? "" : fireflySplitType(live);
  String type = (send[kFieldType] ?? liveType) as String;
  int? asset = (send[kFieldAsset] ??
      (live == null
          ? null
          : fireflyProjectRemoteSplit(live)[kFieldAsset])) as int?;
  if (!send.containsKey(kFieldType) || type == liveType) {
    // The type stays: only the asset side changes.
    body[type == "deposit" ? "destination_id" : "source_id"] =
        asset.toString();
    return;
  }
  // The type changes. The asset account goes to the other side, and so does
  // the other account. That account is named, not given by id: an expense
  // account cannot be the source of a deposit, and Firefly finds or makes the
  // revenue account of that name. The cash account is the same on both sides.
  body["type"] = type;
  String otherSide = liveType == "deposit" ? "source" : "destination";
  String? otherType = live?["${otherSide}_type"]?.toString();
  String? otherName = live?["${otherSide}_name"]?.toString();
  int? otherId = fireflyParseInt(live?["${otherSide}_id"]);
  String newOtherSide = type == "deposit" ? "source" : "destination";
  String assetSide = type == "deposit" ? "destination" : "source";
  body["${assetSide}_id"] = asset.toString();
  if (otherType == "Cash account" && otherId != null) {
    body["${newOtherSide}_id"] = otherId.toString();
  } else if (otherName != null && otherName.isNotEmpty) {
    body["${newOtherSide}_name"] = otherName;
  }
}

// The fields of a create. A create has no record to compare with, thus each
// field that the projection holds is sent.
Map<String, dynamic> fireflyCreateRequestFields(FireflyProjection local) {
  FireflyProjection send = Map.of(local)..remove(kFieldAsset);
  Map<String, dynamic> body = fireflySplitRequestFields(send);
  if (local.containsKey(kFieldAsset)) {
    String type = local[kFieldType] as String;
    body["type"] = type;
    body[type == "deposit" ? "destination_id" : "source_id"] =
        local[kFieldAsset].toString();
  } else {
    body["type"] = local[kFieldType];
  }
  if (body["category_id"] == null) body.remove("category_id");
  if ((body["notes"] ?? "") == "") body.remove("notes");
  return body;
}
