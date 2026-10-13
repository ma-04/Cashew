// The local state of the Firefly client: the map rows that link a local
// record to a Firefly record and hold its snapshot, and the outbox of local
// changes that Firefly does not have yet.

import 'dart:convert';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/firefly/fireflySettings.dart' show fireflyEnabled;
import 'package:drift/drift.dart';

// --- Map rows and snapshots -------------------------------------------------

Future<FireflySyncMapEntry?> fireflyMapOf(
    FireflySyncEntityType type, String localPk) {
  return (database.select(database.fireflySyncMap)
        ..where((m) => m.entityType.equals(type.index))
        ..where((m) => m.localPk.equals(localPk)))
      .getSingleOrNull();
}

Future<List<FireflySyncMapEntry>> fireflyMapsOfRemote(
    FireflySyncEntityType type, int fireflyId) {
  return (database.select(database.fireflySyncMap)
        ..where((m) => m.entityType.equals(type.index))
        ..where((m) => m.fireflyId.equals(fireflyId)))
      .get();
}

Future<List<FireflySyncMapEntry>> fireflyMapsOfType(
    FireflySyncEntityType type) {
  return (database.select(database.fireflySyncMap)
        ..where((m) => m.entityType.equals(type.index)))
      .get();
}

Map<String, dynamic>? fireflySnapshotOf(FireflySyncMapEntry? map) {
  String? raw = map?.remoteSnapshot;
  if (raw == null || raw.isEmpty) return null;
  try {
    return Map<String, dynamic>.from(jsonDecode(raw));
  } catch (_) {
    return null;
  }
}

// Writes the map row of one local record. `localModified` is the
// dateTimeModified value that the engine wrote on the local row: a row whose
// value differs from it has a change of the user.
Future<void> fireflyWriteMap({
  required FireflySyncEntityType type,
  required String localPk,
  required int fireflyId,
  required Map<String, dynamic> snapshot,
  required DateTime localModified,
  DateTime? remoteUpdatedAt,
  int? journalId,
}) {
  return database.into(database.fireflySyncMap).insert(
        FireflySyncMapCompanion.insert(
          entityType: type,
          localPk: localPk,
          fireflyId: fireflyId,
          fireflyUpdatedAt: Value(remoteUpdatedAt),
          lastSyncedLocalModified: Value(localModified),
          fireflyJournalId: Value(journalId),
          remoteSnapshot: Value(jsonEncode(snapshot)),
        ),
        mode: InsertMode.insertOrReplace,
      );
}

Future<void> fireflyDeleteMap(FireflySyncEntityType type, String localPk) {
  return (database.delete(database.fireflySyncMap)
        ..where((m) => m.entityType.equals(type.index))
        ..where((m) => m.localPk.equals(localPk)))
      .go();
}

// True if the local row has a change that the engine did not write. The
// engine writes the server updated_at as dateTimeModified and records it in
// the map row, thus each user edit, which writes the current time, differs.
bool fireflyLocalRowIsDirty(
    DateTime? localModified, FireflySyncMapEntry? map) {
  if (map == null) return true;
  if (localModified == null || map.lastSyncedLocalModified == null) {
    return true;
  }
  return localModified.millisecondsSinceEpoch ~/ 1000 !=
      map.lastSyncedLocalModified!.millisecondsSinceEpoch ~/ 1000;
}

// The dateTimeModified value that the engine writes on a local row that it
// takes from the server: one hour before the server change. A user edit
// writes the current time, which is after the server change, thus it always
// differs from this value. The time of the server change itself does not do:
// the database keeps whole seconds, and an edit in the same second as the
// server change would look like no change. The hour also covers a phone clock
// that is behind the server clock.
DateTime fireflyEngineStamp(DateTime? remoteUpdatedAt) {
  DateTime stamp = (remoteUpdatedAt ?? DateTime.now())
      .toLocal()
      .subtract(const Duration(hours: 1));
  return DateTime.fromMillisecondsSinceEpoch(
      stamp.millisecondsSinceEpoch ~/ 1000 * 1000);
}

// --- Outbox -----------------------------------------------------------------

String fireflyOpKey(FireflySyncEntityType type, String localPk) =>
    "${type.index}:$localPk";

// Queues a local change. A change of a record that already has an operation
// joins it. A new edit of a record whose operation failed gives it a new
// chance: the user changed the record again.
//
// The attempt count stays: a create whose request went out once may be on
// the server already, and the next attempt must look for it first.
Future<void> fireflyQueue(FireflySyncEntityType type, String localPk,
    {String? intent}) async {
  int updated = await (database.update(database.fireflyOutbox)
        ..where((o) => o.entityType.equals(type.index))
        ..where((o) => o.localPk.equals(localPk)))
      .write(FireflyOutboxCompanion(
    state: Value(FireflyOutboxState.pending),
    intent: intent == null ? Value.absent() : Value(intent),
  ));
  if (updated > 0) return;
  await database.into(database.fireflyOutbox).insert(
        FireflyOutboxCompanion.insert(
          entityType: type,
          localPk: localPk,
          intent: Value(intent),
        ),
        mode: InsertMode.insertOrIgnore,
      );
}

const String kFireflyIntentDelete = "delete";
const String kFireflyIntentDeactivate = "deactivate";

Future<FireflyOutboxEntry?> fireflyOpOf(
    FireflySyncEntityType type, String localPk) {
  return (database.select(database.fireflyOutbox)
        ..where((o) => o.entityType.equals(type.index))
        ..where((o) => o.localPk.equals(localPk)))
      .getSingleOrNull();
}

Future<List<FireflyOutboxEntry>> fireflyOutboxEntries({
  FireflyOutboxState? state,
}) {
  SimpleSelectStatement<$FireflyOutboxTable, FireflyOutboxEntry> query =
      database.select(database.fireflyOutbox);
  if (state != null) query.where((o) => o.state.equals(state.index));
  query.orderBy([(o) => OrderingTerm(expression: o.dateQueued)]);
  return query.get();
}

Future<Set<String>> fireflyOpenOpKeys() async {
  List<FireflyOutboxEntry> entries = await fireflyOutboxEntries(
    state: FireflyOutboxState.pending,
  );
  return entries.map((e) => fireflyOpKey(e.entityType, e.localPk)).toSet();
}

Future<void> fireflyFinishOp(FireflySyncEntityType type, String localPk) {
  return (database.delete(database.fireflyOutbox)
        ..where((o) => o.entityType.equals(type.index))
        ..where((o) => o.localPk.equals(localPk)))
      .go();
}

// The server refused the change. The operation stays, visible, and is not
// sent again until the user edits the record or retries it.
Future<void> fireflyFailOp(
    FireflySyncEntityType type, String localPk, String error) {
  return (database.update(database.fireflyOutbox)
        ..where((o) => o.entityType.equals(type.index))
        ..where((o) => o.localPk.equals(localPk)))
      .write(FireflyOutboxCompanion(
    state: Value(FireflyOutboxState.failed),
    lastError: Value(error),
  ));
}

// The request did not get an answer. The operation stays pending.
Future<void> fireflyCountAttempt(
    FireflySyncEntityType type, String localPk, String error) async {
  FireflyOutboxEntry? entry = await (database.select(database.fireflyOutbox)
        ..where((o) => o.entityType.equals(type.index))
        ..where((o) => o.localPk.equals(localPk)))
      .getSingleOrNull();
  if (entry == null) return;
  await (database.update(database.fireflyOutbox)
        ..where((o) => o.entityType.equals(type.index))
        ..where((o) => o.localPk.equals(localPk)))
      .write(FireflyOutboxCompanion(
    attempts: Value(entry.attempts + 1),
    lastError: Value(error),
  ));
}

Future<void> fireflyRetryFailedOps() {
  return (database.update(database.fireflyOutbox)
        ..where((o) => o.state.equals(FireflyOutboxState.failed.index)))
      .write(FireflyOutboxCompanion(state: Value(FireflyOutboxState.pending)));
}

Future<void> fireflyClearOutbox() {
  return database.delete(database.fireflyOutbox).go();
}

// Forgets each link, each snapshot and each queued change: the state of one
// server. A token and an id are correct for one server only.
Future<void> fireflyClearClientState() async {
  await database.delete(database.fireflySyncMap).go();
  await fireflyClearOutbox();
}

// A delete of a wallet or a category that Firefly holds. The server does it
// first (see FireflyOutbox.intent); the local record changes when the push
// has done it. Returns false for a record that Firefly does not hold, which
// the caller then deletes as usual.
Future<bool> fireflyQueueDeleteIfLinked(
    FireflySyncEntityType type, String localPk) async {
  if (!fireflyEnabled) return false;
  if (await fireflyMapOf(type, localPk) == null) return false;
  await fireflyQueue(type, localPk,
      intent: type == FireflySyncEntityType.wallet
          ? kFireflyIntentDeactivate
          : kFireflyIntentDelete);
  return true;
}
