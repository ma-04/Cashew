// The planning records of Firefly: budgets, piggy banks and bills.
//
// A Firefly budget is a Cashew budget of the type "added transactions only".
// The budget of a withdrawal (`budget_id`) is the budget that the local row is
// added to (Transaction.sharedReferenceBudgetPk), and the push sends a change
// of it (see fireflyProjection.dart). The name, the amount and the period of
// a budget are read-only here: Firefly keeps an amount for each period (a
// budget limit), and a write of one period from this app could change a
// period that the user did not see. Each pull writes them again.
//
// Piggy banks and bills are read-only. The pull keeps each record as the
// snapshot of a map row with no local row, and the Firefly pages show them.

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/firefly/client/fireflyProjection.dart';
import 'package:budget/struct/firefly/client/fireflyPull.dart';
import 'package:budget/struct/firefly/client/fireflyStore.dart';
import 'package:drift/drift.dart';

const FireflySyncEntityType _budget = FireflySyncEntityType.budget;

// The local key of a cached record that has no local row.
String fireflyCacheKey(FireflySyncEntityType type, int id) => "${type.name}:$id";

Map<String, dynamic> _attributes(Map<String, dynamic> record) =>
    Map<String, dynamic>.from(record["attributes"] ?? {});

String _date(DateTime day) =>
    "${day.year.toString().padLeft(4, "0")}-"
    "${day.month.toString().padLeft(2, "0")}-"
    "${day.day.toString().padLeft(2, "0")}";

// --- Budgets ----------------------------------------------------------------

// The Cashew period of a Firefly budget: from its auto-budget period, else
// from the length of its budget limit of this month.
(BudgetReoccurence, int) fireflyBudgetPeriod(
    String? autoPeriod, DateTime? limitStart, DateTime? limitEnd) {
  switch (autoPeriod) {
    case "daily":
      return (BudgetReoccurence.daily, 1);
    case "weekly":
      return (BudgetReoccurence.weekly, 1);
    case "monthly":
      return (BudgetReoccurence.monthly, 1);
    case "quarterly":
      return (BudgetReoccurence.monthly, 3);
    case "half_year":
      return (BudgetReoccurence.monthly, 6);
    case "yearly":
      return (BudgetReoccurence.yearly, 1);
  }
  if (limitStart != null && limitEnd != null) {
    int days = limitEnd.difference(limitStart).inDays + 1;
    if (days <= 1) return (BudgetReoccurence.daily, 1);
    if (days <= 7) return (BudgetReoccurence.weekly, 1);
    if (days >= 360) return (BudgetReoccurence.yearly, 1);
    if (days > 31 && days <= 92) return (BudgetReoccurence.monthly, 3);
    if (days > 92 && days <= 184) return (BudgetReoccurence.monthly, 6);
  }
  return (BudgetReoccurence.monthly, 1);
}

Future<void> fireflyPullBudgets(FireflyPullContext ctx, DateTime now) async {
  List<Map<String, dynamic>> remote = await ctx.client.getAllRaw("/budgets");
  DateTime monthStart = DateTime(now.year, now.month, 1);
  DateTime monthEnd = DateTime(now.year, now.month + 1, 0);
  List<Budget> locals = await database.getAllBudgets();
  int nextOrder = locals.isEmpty
      ? 0
      : locals.map((b) => b.order).reduce((a, b) => a > b ? a : b) + 1;
  Set<int> remoteIds = {};

  for (Map<String, dynamic> record in remote) {
    int? id = fireflyParseInt(record["id"]);
    if (id == null) continue;
    remoteIds.add(id);
    Map<String, dynamic> attributes = _attributes(record);
    List<Map<String, dynamic>> limits = await ctx.client.getAllRaw(
        "/budgets/$id/limits",
        {"start": _date(monthStart), "end": _date(monthEnd)});
    Map<String, dynamic>? limit =
        limits.isEmpty ? null : _attributes(limits.first);
    DateTime? limitStart = fireflyParseDate(limit?["start"])?.toLocal();
    DateTime? limitEnd = fireflyParseDate(limit?["end"])?.toLocal();
    double amount = fireflyParseAmount(limit?["amount"]) ??
        fireflyParseAmount(attributes["auto_budget_amount"]) ??
        0;
    (BudgetReoccurence, int) period = fireflyBudgetPeriod(
        attributes["auto_budget_period"]?.toString(), limitStart, limitEnd);
    DateTime start = limitStart ?? monthStart;
    start = DateTime(start.year, start.month, start.day);

    List<FireflySyncMapEntry> maps = await fireflyMapsOfRemote(_budget, id);
    FireflySyncMapEntry? map = maps.isEmpty ? null : maps.first;
    Budget? local = map == null
        ? null
        : await (database.select(database.budgets)
              ..where((b) => b.budgetPk.equals(map.localPk)))
            .getSingleOrNull();
    String name = (attributes["name"] ?? "").toString();
    bool archived = attributes["active"] == false;
    Budget row = local != null
        ? local.copyWith(
            name: name,
            amount: amount,
            startDate: start,
            endDate: limitEnd ?? monthEnd,
            reoccurrence: Value(period.$1),
            periodLength: period.$2,
            archived: archived,
            addedTransactionsOnly: true,
          )
        : Budget(
            budgetPk: map?.localPk ?? uuid.v4(),
            name: name,
            amount: amount,
            startDate: start,
            endDate: limitEnd ?? monthEnd,
            income: false,
            archived: archived,
            addedTransactionsOnly: true,
            periodLength: period.$2,
            reoccurrence: period.$1,
            dateCreated: DateTime.now(),
            dateTimeModified: DateTime.now(),
            pinned: false,
            order: nextOrder++,
            walletFk: "0",
            isAbsoluteSpendingLimit: false,
          );
    await database.into(database.budgets).insert(row.toCompanion(true),
        mode: InsertMode.insertOrReplace);
    await fireflyWriteMap(
      type: _budget,
      localPk: row.budgetPk,
      fireflyId: id,
      snapshot: {...record, "limit": limit},
      localModified: row.dateTimeModified ?? DateTime.now(),
      remoteUpdatedAt: fireflyParseDate(attributes["updated_at"]),
    );
    ctx.budgetPkById[id] = row.budgetPk;
  }

  // A budget that the server deleted. Its rows lose the budget, as on the
  // server.
  for (FireflySyncMapEntry map in await fireflyMapsOfType(_budget)) {
    if (remoteIds.contains(map.fireflyId)) continue;
    await (database.update(database.transactions)
          ..where((t) => t.sharedReferenceBudgetPk.equals(map.localPk)))
        .write(const TransactionsCompanion(
            sharedReferenceBudgetPk: Value(null)));
    await (database.delete(database.budgets)
          ..where((b) => b.budgetPk.equals(map.localPk)))
        .go();
    await fireflyDeleteMap(_budget, map.localPk);
    ctx.budgetPkById.remove(map.fireflyId);
  }
}

// The budget link of each withdrawal row that has none, from its snapshot.
// For the upgrade to client version 3: a row with a queued change keeps its
// local values in the pull, and with no link the push would clear the budget
// on the server.
Future<void> fireflyBackfillBudgetLinks() async {
  Map<int, String> budgetPkById = {
    for (FireflySyncMapEntry map in await fireflyMapsOfType(_budget))
      map.fireflyId: map.localPk,
  };
  for (FireflySyncMapEntry map
      in await fireflyMapsOfType(FireflySyncEntityType.transaction)) {
    Map<String, dynamic>? split =
        fireflySnapshotOf(map)?[kSnapSplit] as Map<String, dynamic>?;
    if (split == null || fireflySplitType(split) != "withdrawal") continue;
    String? budgetPk = budgetPkById[fireflyParseInt(split["budget_id"])];
    if (budgetPk == null) continue;
    await (database.update(database.transactions)
          ..where((t) =>
              t.transactionPk.equals(map.localPk) &
              t.sharedReferenceBudgetPk.isNull()))
        .write(TransactionsCompanion(sharedReferenceBudgetPk: Value(budgetPk)));
  }
}

// --- Piggy banks and bills --------------------------------------------------

// Keeps each record of `path` as a cached map row of `type`, and removes the
// cached rows of records that the server no longer has.
Future<void> _pullCache(FireflyPullContext ctx, FireflySyncEntityType type,
    String path, Map<String, dynamic> query) async {
  List<Map<String, dynamic>> remote = await ctx.client.getAllRaw(path, query);
  Set<String> keep = {};
  for (Map<String, dynamic> record in remote) {
    int? id = fireflyParseInt(record["id"]);
    if (id == null) continue;
    String key = fireflyCacheKey(type, id);
    keep.add(key);
    await fireflyWriteMap(
      type: type,
      localPk: key,
      fireflyId: id,
      snapshot: record,
      localModified: DateTime.now(),
      remoteUpdatedAt: fireflyParseDate(_attributes(record)["updated_at"]),
    );
  }
  for (FireflySyncMapEntry map in await fireflyMapsOfType(type)) {
    if (!keep.contains(map.localPk)) await fireflyDeleteMap(type, map.localPk);
  }
}

Future<void> fireflyPullPiggyBanksAndBills(
    FireflyPullContext ctx, DateTime now) async {
  await _pullCache(ctx, FireflySyncEntityType.piggyBank, "/piggy-banks", {});
  // With a range, a bill holds its expected and paid dates in that range.
  DateTime start = DateTime(now.year, now.month, 1);
  DateTime end = DateTime(now.year, now.month + 2, 0);
  await _pullCache(ctx, FireflySyncEntityType.bill, "/bills",
      {"start": _date(start), "end": _date(end)});
}

// The cached records of a type, as the server sent them.
Future<List<Map<String, dynamic>>> fireflyCachedRecords(
    FireflySyncEntityType type) async {
  return [
    for (FireflySyncMapEntry map in await fireflyMapsOfType(type))
      if (fireflySnapshotOf(map) != null) fireflySnapshotOf(map)!,
  ];
}
