import 'package:budget/database/tables.dart';
import 'package:budget/struct/firefly/client/fireflyPlanning.dart';
import 'package:budget/struct/firefly/client/fireflyProjection.dart';
import 'package:flutter_test/flutter_test.dart';

Transaction _row({
  double amount = -12.5,
  String name = "Lunch",
  String note = "",
  DateTime? date,
  String? payee = "Shop",
  List<String>? tags = const ["food"],
}) {
  return Transaction(
    payee: payee,
    tags: tags,
    transactionPk: "t1",
    name: name,
    amount: amount,
    note: note,
    categoryFk: "c1",
    walletFk: "w1",
    dateCreated: date ?? DateTime.utc(2024, 5, 1, 21, 30),
    income: amount > 0,
    paid: true,
    skipPaid: true,
  );
}

Map<String, dynamic> _split({
  String type = "withdrawal",
  String date = "2024-05-01T21:30:00+00:00",
  String amount = "12.500000000000",
  String description = "Lunch",
  String? notes,
  String? categoryId = "7",
  String sourceId = "3",
  String destinationId = "9",
}) {
  return {
    "transaction_journal_id": 41,
    "type": type,
    "date": date,
    "amount": amount,
    "description": description,
    "notes": notes,
    "category_id": categoryId,
    "source_id": sourceId,
    "source_name": "Wallet",
    "source_type": "Asset account",
    "destination_id": destinationId,
    "destination_name": "Shop",
    "destination_type": "Expense account",
    "budget_id": null,
    "tags": ["food"],
  };
}

void main() {
  group("A local row that the user did not change sends nothing", () {
    test("same instant in another time zone, same amount, same text", () {
      FireflyProjection base = fireflyProjectRemoteSplit(
          _split(date: "2024-05-01T23:30:00+02:00"));
      FireflyProjection local = fireflyProjectLocalRow(
          _row(date: DateTime.utc(2024, 5, 1, 21, 30).toLocal()),
          assetAccountId: 3,
          categoryId: 7);
      expect(fireflyDiff(local, base), isEmpty);
    });

    test("an amount with 12 decimals read back as a double", () {
      FireflyProjection base =
          fireflyProjectRemoteSplit(_split(amount: "10.123000000000"));
      FireflyProjection local = fireflyProjectLocalRow(_row(amount: -10.123),
          assetAccountId: 3, categoryId: 7);
      expect(fireflyDiff(local, base), isEmpty);
    });

    test("no notes on the server and an empty note here", () {
      FireflyProjection base = fireflyProjectRemoteSplit(_split(notes: null));
      FireflyProjection local = fireflyProjectLocalRow(_row(note: ""),
          assetAccountId: 3, categoryId: 7);
      expect(fireflyDiff(local, base), isEmpty);
    });
  });

  group("An edit sends only the field that changed", () {
    test("a new description", () {
      Map<String, dynamic> remote = _split();
      FireflyProjection base = fireflyProjectRemoteSplit(remote);
      FireflyProjection local = fireflyProjectLocalRow(_row(name: "Dinner"),
          assetAccountId: 3, categoryId: 7);
      FireflyMergeResult merge =
          fireflyMerge(base: base, local: local, live: base);
      expect(merge.send.keys, [kFieldDescription]);
      expect(fireflySplitRequestFields(merge.send, live: remote),
          {"description": "Dinner"});
    });

    test("a cleared category is sent as null, a cleared note as empty", () {
      Map<String, dynamic> remote = _split(notes: "old");
      FireflyProjection base = fireflyProjectRemoteSplit(remote);
      FireflyProjection local = fireflyProjectLocalRow(_row(note: ""),
          assetAccountId: 3, categoryId: null);
      Map<String, dynamic> body = fireflySplitRequestFields(
          fireflyMerge(base: base, local: local, live: base).send,
          live: remote);
      expect(body, {"category_id": null, "notes": ""});
    });

    test("a new date goes out in UTC with Z", () {
      Map<String, dynamic> remote = _split();
      FireflyProjection base = fireflyProjectRemoteSplit(remote);
      FireflyProjection local = fireflyProjectLocalRow(
          _row(date: DateTime.utc(2024, 5, 2, 8, 0, 5)),
          assetAccountId: 3,
          categoryId: 7);
      expect(
          fireflySplitRequestFields(
              fireflyMerge(base: base, local: local, live: base).send,
              live: remote),
          {"date": "2024-05-02T08:00:05Z"});
    });

    test("a new amount keeps its decimals", () {
      Map<String, dynamic> remote = _split();
      FireflyProjection base = fireflyProjectRemoteSplit(remote);
      FireflyProjection local = fireflyProjectLocalRow(_row(amount: -1.125),
          assetAccountId: 3, categoryId: 7);
      expect(
          fireflySplitRequestFields(
              fireflyMerge(base: base, local: local, live: base).send,
              live: remote),
          {"amount": "1.125"});
    });

    test("another wallet moves the source only", () {
      Map<String, dynamic> remote = _split();
      FireflyProjection base = fireflyProjectRemoteSplit(remote);
      FireflyProjection local =
          fireflyProjectLocalRow(_row(), assetAccountId: 4, categoryId: 7);
      expect(
          fireflySplitRequestFields(
              fireflyMerge(base: base, local: local, live: base).send,
              live: remote),
          {"source_id": "4"});
    });

    test("a sign flip makes a deposit and names the other account", () {
      Map<String, dynamic> remote = _split();
      FireflyProjection base = fireflyProjectRemoteSplit(remote);
      FireflyProjection local = fireflyProjectLocalRow(_row(amount: 12.5),
          assetAccountId: 3, categoryId: 7);
      expect(
          fireflySplitRequestFields(
              fireflyMerge(base: base, local: local, live: base).send,
              live: remote),
          {"type": "deposit", "destination_id": "3", "source_name": "Shop"});
    });
  });

  group("The server wins a field that it changed too", () {
    test("both changed the description: nothing is sent, one conflict", () {
      FireflyProjection base = fireflyProjectRemoteSplit(_split());
      FireflyProjection live =
          fireflyProjectRemoteSplit(_split(description: "Web edit"));
      FireflyProjection local = fireflyProjectLocalRow(_row(name: "Phone"),
          assetAccountId: 3, categoryId: 7);
      FireflyMergeResult merge =
          fireflyMerge(base: base, local: local, live: live);
      expect(merge.send, isEmpty);
      expect(merge.conflicts, {kFieldDescription});
    });

    test("different fields: the local one goes, the server one stays", () {
      FireflyProjection base = fireflyProjectRemoteSplit(_split());
      FireflyProjection live =
          fireflyProjectRemoteSplit(_split(amount: "20.000000000000"));
      FireflyProjection local = fireflyProjectLocalRow(_row(name: "Phone"),
          assetAccountId: 3, categoryId: 7);
      FireflyMergeResult merge =
          fireflyMerge(base: base, local: local, live: live);
      expect(merge.send.keys, [kFieldDescription]);
      expect(merge.conflicts, isEmpty);
    });

    test("the same change on both sides is no conflict and is not sent", () {
      FireflyProjection base = fireflyProjectRemoteSplit(_split());
      FireflyProjection live =
          fireflyProjectRemoteSplit(_split(description: "Same"));
      FireflyProjection local = fireflyProjectLocalRow(_row(name: "Same"),
          assetAccountId: 3, categoryId: 7);
      FireflyMergeResult merge =
          fireflyMerge(base: base, local: local, live: live);
      expect(merge.send, isEmpty);
      expect(merge.conflicts, isEmpty);
    });

    test("a type change that the server also changed drops the asset too",
        () {
      FireflyProjection base = fireflyProjectRemoteSplit(_split());
      FireflyProjection live = fireflyProjectRemoteSplit(
          _split(type: "deposit", sourceId: "9", destinationId: "3"));
      FireflyProjection local = fireflyProjectLocalRow(_row(amount: 12.5),
          assetAccountId: 4, categoryId: 7);
      FireflyMergeResult merge =
          fireflyMerge(base: base, local: local, live: live);
      expect(merge.send, isEmpty);
    });
  });

  group("Transfers", () {
    Map<String, dynamic> transfer = {
      "type": "transfer",
      "date": "2024-05-01T10:00:00+00:00",
      "amount": "1200.000000000000",
      "foreign_amount": "9.680000000000",
      "description": "To card",
      "notes": null,
      "source_id": "3",
      "destination_id": "8",
    };
    Transaction source = _row(amount: -1200, name: "To card", tags: null)
        .copyWith(dateCreated: DateTime.utc(2024, 5, 1, 10));
    Transaction destination = _row(amount: 9.68, name: "To card", tags: null)
        .copyWith(dateCreated: DateTime.utc(2024, 5, 1, 10));

    test("an edit of the source amount keeps the foreign amount", () {
      FireflyProjection base = fireflyProjectRemoteTransfer(transfer);
      FireflyProjection local = fireflyProjectLocalTransfer(
        source: source.copyWith(amount: -1300),
        destination: destination,
        sourceAccountId: 3,
        destinationAccountId: 8,
        crossCurrency: true,
        description: "To card",
        notes: "",
      );
      expect(
          fireflySplitRequestFields(
              fireflyMerge(base: base, local: local, live: base).send),
          {"amount": "1300"});
    });

    test("the text of the row that changed wins", () {
      expect(fireflyTransferText("To card", "Card top-up", "To card"),
          "Card top-up");
      expect(fireflyTransferText("Rent", "To card", "To card"), "Rent");
    });
  });

  test("a create sends every field, the asset on the correct side", () {
    FireflyProjection local = fireflyProjectLocalRow(
        _row(amount: 50, payee: null, tags: null),
        assetAccountId: 3,
        categoryId: null);
    expect(fireflyCreateRequestFields(local), {
      "type": "deposit",
      "date": "2024-05-01T21:30:00Z",
      "amount": "50",
      "description": "Lunch",
      "destination_id": "3",
    });
  });

  group("category colour in the notes", () {
    Map<String, dynamic> record(String? notes, [String? color]) => {
          "attributes": {"notes": notes, "color": color}
        };

    test("is read from the color line that the app writes", () {
      expect(fireflyCategoryColour(record("Food\ncolor: #12AB34")),
          "0xff12ab34");
      expect(fireflyCategoryColour(record("Color: #ff8800")), "0xffff8800");
      expect(fireflyCategoryColour(record(null)), isNull);
      expect(fireflyCategoryColour(record("color: #1234567")), isNull);
    });

    test("no other text is a colour (review A8)", () {
      expect(fireflyCategoryColour(record("Invoice #123456")), isNull);
      expect(fireflyCategoryColour(record("#ff8800")), isNull);
      expect(fireflyCategoryColour(record("watercolor: #ff8800")), isNull);
      expect(fireflyCategoryColour(record("colour=ff8800")), isNull);
      expect(fireflyCategoryColour(record("no colour", "00ff00")), isNull);
      expect(fireflyNotesWithColour("Invoice #123456", "0xffff8800"),
          "Invoice #123456\ncolor: #ff8800");
    });

    test("is written in place, and keeps the rest of the text", () {
      expect(fireflyNotesWithColour("Trips\ncolor: #12ab34", "0xffff8800"),
          "Trips\ncolor: #ff8800");
      expect(fireflyNotesWithColour("Trips", "0xffff8800"),
          "Trips\ncolor: #ff8800");
      expect(fireflyNotesWithColour(null, "0xffff8800"), "color: #ff8800");
    });
  });

  group("subcategory tag spelling", () {
    test("the push keeps the spelling of the server (review A9)", () {
      expect(fireflyRemoteSpelling("Food/Lunch", ["food / lunch", "work"]),
          "food / lunch");
      expect(fireflyRemoteSpelling("Food/Lunch", ["work"]), "Food/Lunch");
    });
  });

  group("payee and tags", () {
    test("an unchanged payee and tags in another order send nothing", () {
      FireflyProjection base =
          fireflyProjectRemoteSplit(_split()..["tags"] = ["b", "food", "a"]);
      FireflyProjection local = fireflyProjectLocalRow(
          _row(tags: ["a", "food", "b"]),
          assetAccountId: 3,
          categoryId: 7);
      expect(fireflyDiff(local, base), isEmpty);
    });

    test("a new payee sends the name of the other account only", () {
      Map<String, dynamic> split = _split();
      FireflyProjection base = fireflyProjectRemoteSplit(split);
      FireflyProjection local = fireflyProjectLocalRow(_row(payee: "Bakery"),
          assetAccountId: 3, categoryId: 7);
      FireflyMergeResult merge =
          fireflyMerge(base: base, local: local, live: base);
      expect(fireflySplitRequestFields(merge.send, live: split),
          {"destination_name": "Bakery"});
    });

    test("no payee is the cash account, by an empty name", () {
      Map<String, dynamic> split = _split(type: "deposit");
      split["source_name"] = "Employer";
      split["source_type"] = "Revenue account";
      split["destination_type"] = "Asset account";
      FireflyProjection base = fireflyProjectRemoteSplit(split);
      expect(base[kFieldPayee], "Employer");
      FireflyProjection local = fireflyProjectLocalRow(
          _row(amount: 12.5, payee: null),
          assetAccountId: 9,
          categoryId: 7);
      FireflyMergeResult merge =
          fireflyMerge(base: base, local: local, live: base);
      expect(fireflySplitRequestFields(merge.send, live: split),
          {"source_name": ""});
    });

    test("the cash account reads as no payee", () {
      Map<String, dynamic> split = _split()
        ..["destination_name"] = "Cash account"
        ..["destination_type"] = "Cash account";
      expect(fireflyRemotePayee(split), isNull);
      expect(fireflyPayeeIsEditable(split), isTrue);
      split["destination_type"] = "Loan";
      expect(fireflyPayeeIsEditable(split), isFalse);
    });

    test("a subcategory goes as a tag, and the tags as a full list", () {
      FireflyProjection base = fireflyProjectRemoteSplit(_split());
      FireflyProjection local = fireflyProjectLocalRow(_row(),
          assetAccountId: 3,
          categoryId: 7,
          subcategoryTag: fireflySubcategoryTag("Food", "Snacks"));
      FireflyMergeResult merge =
          fireflyMerge(base: base, local: local, live: base);
      expect(fireflySplitRequestFields(merge.send, live: _split()), {
        "tags": ["Food/Snacks", "food"]
      });
    });

    test("a create names the payee, or no other account", () {
      expect(
          fireflyCreateRequestFields(fireflyProjectLocalRow(
              _row(payee: "Market", tags: ["weekly"]),
              assetAccountId: 3,
              categoryId: null))["destination_name"],
          "Market");
      Map<String, dynamic> body = fireflyCreateRequestFields(
          fireflyProjectLocalRow(_row(payee: null, tags: null),
              assetAccountId: 3, categoryId: null));
      expect(body.containsKey("destination_name"), isFalse);
      expect(body.containsKey("tags"), isFalse);
    });
  });

  test("a new transfer names both accounts", () {
    Transaction out = _row(amount: -75, tags: null);
    Transaction into = _row(amount: 75, tags: null);
    Map<String, dynamic> body =
        fireflyCreateRequestFields(fireflyProjectLocalTransfer(
      source: out,
      destination: into,
      sourceAccountId: 3,
      destinationAccountId: 8,
      crossCurrency: false,
      description: "Pay",
      notes: "",
    ));
    expect(body["type"], "transfer");
    expect(body["source_id"], "3");
    expect(body["destination_id"], "8");
    expect(fireflyPairType(null, "loan"), "withdrawal");
    expect(fireflyPairType("debt", null), "deposit");
    expect(fireflyPairType("loan", "debt"), "transfer");
    expect(fireflyPairType(null, null), "transfer");
  });

  test("the budget of a withdrawal goes by id, a deposit has none", () {
    Map<String, dynamic> split = _split()..["budget_id"] = "5";
    FireflyProjection base = fireflyProjectRemoteSplit(split);
    FireflyProjection local = fireflyProjectLocalRow(_row(),
        assetAccountId: 3, categoryId: 7, budgetId: 6);
    expect(
        fireflySplitRequestFields(
            fireflyMerge(base: base, local: local, live: base).send,
            live: split),
        {"budget_id": "6"});
    FireflyProjection deposit = fireflyProjectLocalRow(_row(amount: 5),
        assetAccountId: 3, categoryId: 7, budgetId: 6);
    expect(deposit.containsKey(kFieldBudget), isFalse);
    expect(fireflyBudgetPeriod("quarterly", null, null),
        (BudgetReoccurence.monthly, 3));
    expect(
        fireflyBudgetPeriod(
            null, DateTime(2026, 10, 5), DateTime(2026, 10, 11, 23, 59)),
        (BudgetReoccurence.weekly, 1));
  });
}
