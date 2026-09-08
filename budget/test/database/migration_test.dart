// Upgrades a real on-disk database from each shipped schema version to the
// current one.
//
// This exists because of a bug that made every upgrade from an existing install
// fail to open the database while fresh installs were fine. `onUpgrade` asked
// drift's generated `migrationSteps()` to step all the way to `to`, but
// `drift_schemas/` stops at v46 and the generated switch throws
// `ArgumentError("Unknown migration from 46")` past that. drift's
// `runMigrationSteps` loops `for (var target = from; target < to;)`, so it hit
// that throw, and the call is not inside a try/catch - `onUpgrade` aborted
// before the hand-rolled v47+ blocks ran and the database never opened.
//
// Every other test, and a developer's fresh install, only ever exercises
// `onCreate`, which is exactly why this went unnoticed. These tests stamp
// `user_version` on a database that already has its tables, so opening it takes
// the `onUpgrade` path the way a real upgrading install does.
import 'dart:ffi';
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:sqlite3/open.dart' as sqlite_open;
// ignore: depend_on_referenced_packages
import 'package:sqlite3/sqlite3.dart' as raw;

/// The app itself never has to find sqlite3 - `sqlite3_flutter_libs` bundles it
/// into the Android/iOS/desktop build. `flutter test` runs on the plain Dart VM
/// with no such bundle, so `package:sqlite3` falls back to opening the system
/// library, and it only ever asks for the bare `libsqlite3.so`. That name is
/// the *development* symlink, shipped in `libsqlite3-dev`; a stock Linux box
/// and a GitHub `ubuntu-latest` runner have only the runtime `libsqlite3.so.0`.
/// So point it at the runtime name, falling back to the plain one for images
/// that do have the dev package.
void _useSystemSqlite3() {
  if (!Platform.isLinux) return;
  sqlite_open.open.overrideFor(sqlite_open.OperatingSystem.linux, () {
    for (final String name in <String>["libsqlite3.so.0", "libsqlite3.so"]) {
      try {
        return DynamicLibrary.open(name);
      } on ArgumentError {
        continue;
      }
    }
    throw StateError(
        "No system sqlite3 found. Install libsqlite3-0 (or libsqlite3-dev).");
  });
}

// firefly_sync_map as each version's CREATE TABLE built it. Reconstructed
// rather than dumped from an old build, so keep these in step with the
// migration blocks in tables.dart: whatever a version's block adds is what its
// predecessor's DDL here must lack.

/// v47: before is_tombstone / counterparty_firefly_id / firefly_split_index and
/// before firefly_journal_id, and - the point of the v47 block - without the
/// UNIQUE(entity_type, local_pk) constraint the table carries today.
const String _fireflySyncMapV47 = """
  CREATE TABLE firefly_sync_map (
    sync_map_pk TEXT NOT NULL,
    entity_type INTEGER NOT NULL,
    local_pk TEXT NOT NULL,
    firefly_id INTEGER NOT NULL,
    firefly_updated_at INTEGER NULL,
    last_synced_local_modified INTEGER NULL,
    date_created INTEGER NOT NULL,
    PRIMARY KEY (sync_map_pk)
  )
""";

/// v48: the three columns and the unique constraint arrived together, so a v48
/// install has them from its CREATE TABLE and only lacks firefly_journal_id.
const String _fireflySyncMapV48 = """
  CREATE TABLE firefly_sync_map (
    sync_map_pk TEXT NOT NULL,
    entity_type INTEGER NOT NULL,
    local_pk TEXT NOT NULL,
    firefly_id INTEGER NOT NULL,
    firefly_updated_at INTEGER NULL,
    last_synced_local_modified INTEGER NULL,
    is_tombstone INTEGER NOT NULL DEFAULT 0,
    counterparty_firefly_id INTEGER NULL,
    firefly_split_index INTEGER NOT NULL DEFAULT 0,
    date_created INTEGER NOT NULL,
    PRIMARY KEY (sync_map_pk),
    UNIQUE (entity_type, local_pk)
  )
""";

/// Rewinds a current-schema database so that reopening it runs `onUpgrade`
/// rather than `onCreate`, with firefly_sync_map in the shape [version] left
/// it. Every other table is close enough: no migration at or above 46 touches
/// one, so their current shape is also their v46 shape.
void _rewindTo(String path, int version) {
  final raw.Database db = raw.sqlite3.open(path);
  try {
    db.execute("DROP TABLE IF EXISTS firefly_sync_map");
    // v46 predates the Firefly feature, so it has no such table at all.
    if (version == 47) db.execute(_fireflySyncMapV47);
    if (version == 48) db.execute(_fireflySyncMapV48);
    db.execute("PRAGMA user_version = $version");
  } finally {
    db.dispose();
  }
}

Future<List<String>> _columnsOf(FinanceDatabase db, String table) async {
  final List<QueryRow> rows =
      await db.customSelect("PRAGMA table_info($table)").get();
  return rows.map((QueryRow row) => row.read<String>("name")).toList();
}

void main() {
  late Directory directory;

  setUpAll(_useSystemSqlite3);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp("cashew-migration");
  });
  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  /// Creates a database at the current schema via `onCreate` and closes it,
  /// returning its path.
  Future<String> freshDatabase(String name) async {
    final File file = File("${directory.path}/$name.sqlite");
    final FinanceDatabase database = FinanceDatabase(NativeDatabase(file));
    await database.customSelect("SELECT 1").get();
    await database.close();
    return file.path;
  }

  for (final int from in <int>[46, 47, 48]) {
    test("upgrades a v$from database to v$schemaVersionGlobal", () async {
      final String path = await freshDatabase("db-$from");
      _rewindTo(path, from);

      final FinanceDatabase database = FinanceDatabase(NativeDatabase(
        File(path),
      ));
      addTearDown(database.close);

      // Before the fix this threw ArgumentError("Unknown migration from $from")
      // out of onUpgrade, so the database never opened and this first query -
      // whatever it was - was what surfaced it.
      final List<String> columns =
          await _columnsOf(database, "firefly_sync_map");

      expect(columns, contains("firefly_journal_id"),
          reason: "the v49 addColumn block must have run");
      expect(columns, contains("is_tombstone"));
      expect(columns, contains("counterparty_firefly_id"));
      expect(columns, contains("firefly_split_index"));

      final QueryRow version =
          await database.customSelect("PRAGMA user_version").getSingle();
      expect(version.read<int>("user_version"), schemaVersionGlobal,
          reason: "the upgrade must be recorded, not left half-applied");
    });
  }

  test("an upgraded v47 database enforces one map row per entity", () async {
    // The columns being present is not proof the v47 block finished: it also
    // has to create the UNIQUE(entity_type, local_pk) index that a v47
    // CREATE TABLE lacked and that _upsertSyncMap's insertOrReplace depends on
    // to replace the previous mapping rather than append another one. That part
    // has its own try/catch, so a failure there is printed, not thrown.
    final String path = await freshDatabase("writable");
    _rewindTo(path, 47);
    final FinanceDatabase database =
        FinanceDatabase(NativeDatabase(File(path)));
    addTearDown(database.close);

    for (int journalId = 1000; journalId <= 1001; journalId++) {
      await database.into(database.fireflySyncMap).insert(
            FireflySyncMapCompanion.insert(
              entityType: FireflySyncEntityType.transaction,
              localPk: "local-1",
              fireflyId: 42,
              fireflyJournalId: Value(journalId),
            ),
            mode: InsertMode.insertOrReplace,
          );
    }

    final List<FireflySyncMapEntry> rows =
        await database.select(database.fireflySyncMap).get();
    expect(rows.length, 1,
        reason: "the unique index must make the second write a replace");
    expect(rows.single.fireflyJournalId, 1001);
  });

  test("a fresh database gets firefly_journal_id from onCreate", () async {
    final String path = await freshDatabase("fresh");
    final FinanceDatabase database =
        FinanceDatabase(NativeDatabase(File(path)));
    addTearDown(database.close);
    expect(await _columnsOf(database, "firefly_sync_map"),
        contains("firefly_journal_id"));
  });
}
