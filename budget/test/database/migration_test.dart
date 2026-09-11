// Upgrades a database file from each released schema version to the current
// one.
//
// A defect made each upgrade of an existing installation fail to open the
// database, while a fresh installation was correct. `onUpgrade` told the
// generated `migrationSteps()` of drift to step to `to`, but `drift_schemas/`
// stops at v46 and the generated switch throws
// `ArgumentError("Unknown migration from 46")` after that. The
// `runMigrationSteps` function of drift loops
// `for (var target = from; target < to;)`, thus it found that throw. The call
// is not in a try/catch, thus `onUpgrade` stopped before the hand-written v47
// and later blocks, and the database did not open.
//
// Each other test, and the fresh installation of a developer, uses `onCreate`
// only, which is why nobody saw this. These tests write `user_version` on a
// database that has its tables, thus the open uses `onUpgrade` as a real
// installation does.
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

/// The application does not find sqlite3 itself: `sqlite3_flutter_libs` puts
/// it into the Android, iOS and desktop builds. `flutter test` runs on the Dart
/// VM, which has no such library, thus `package:sqlite3` opens the library of
/// the system and asks for the name `libsqlite3.so`. That name is the symlink
/// of the development package `libsqlite3-dev`. A usual Linux machine and a
/// GitHub `ubuntu-latest` runner have `libsqlite3.so.0` only. Thus ask for the
/// runtime name first and for the other name after it.
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

// The firefly_sync_map table as the CREATE TABLE of each version made it.
// These statements are written by hand, not read from an old build. Keep them
// in agreement with the migration blocks in tables.dart: what a block adds is
// what the statement of the version before it must not have.

/// v47: no is_tombstone, no counterparty_firefly_id, no firefly_split_index
/// and no firefly_journal_id. Also no UNIQUE(entity_type, local_pk), which is
/// the reason for the v47 block.
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

/// v48: the three columns and the unique constraint came together, thus a v48
/// installation has them from its CREATE TABLE. Only firefly_journal_id is
/// absent.
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

/// v49: the table has each column and the unique index. Only the index on
/// (entity_type, firefly_id) that v50 adds is absent.
const String _fireflySyncMapV49 = """
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
    firefly_journal_id INTEGER NULL,
    date_created INTEGER NOT NULL,
    PRIMARY KEY (sync_map_pk),
    UNIQUE (entity_type, local_pk)
  )
""";

/// Puts a database of the current schema back to [version], thus the next
/// open runs `onUpgrade` and not `onCreate`. The firefly_sync_map table gets
/// the shape of that version. The other tables keep their shape, because no
/// migration at v46 or after it changes one.
void _rewindTo(String path, int version) {
  final raw.Database db = raw.sqlite3.open(path);
  try {
    db.execute("DROP TABLE IF EXISTS firefly_sync_map");
    // v46 is before the Firefly feature, thus it has no such table.
    if (version == 47) db.execute(_fireflySyncMapV47);
    if (version == 48) db.execute(_fireflySyncMapV48);
    if (version == 49) db.execute(_fireflySyncMapV49);
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

Future<List<String>> _indexesOf(FinanceDatabase db, String table) async {
  final List<QueryRow> rows =
      await db.customSelect("PRAGMA index_list($table)").get();
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

  /// Makes a database of the current schema with `onCreate`, closes it and
  /// returns its path.
  Future<String> freshDatabase(String name) async {
    final File file = File("${directory.path}/$name.sqlite");
    final FinanceDatabase database = FinanceDatabase(NativeDatabase(file));
    await database.customSelect("SELECT 1").get();
    await database.close();
    return file.path;
  }

  for (final int from in <int>[46, 47, 48, 49]) {
    test("upgrades a v$from database to v$schemaVersionGlobal", () async {
      final String path = await freshDatabase("db-$from");
      _rewindTo(path, from);

      final FinanceDatabase database = FinanceDatabase(NativeDatabase(
        File(path),
      ));
      addTearDown(database.close);

      // Before the fix, onUpgrade threw
      // ArgumentError("Unknown migration from $from"). The database did not
      // open, thus the first query showed the defect.
      final List<String> columns =
          await _columnsOf(database, "firefly_sync_map");

      expect(columns, contains("firefly_journal_id"),
          reason: "the v49 addColumn block must have run");
      expect(columns, contains("is_tombstone"));
      expect(columns, contains("counterparty_firefly_id"));
      expect(columns, contains("firefly_split_index"));

      expect(await _indexesOf(database, "firefly_sync_map"),
          contains("firefly_sync_map_entity_type_firefly_id"),
          reason: "the v50 index block must have run");

      final QueryRow version =
          await database.customSelect("PRAGMA user_version").getSingle();
      expect(version.read<int>("user_version"), schemaVersionGlobal,
          reason: "the upgrade must be recorded, not left half-applied");
    });
  }

  test("an upgraded v47 database enforces one map row per entity", () async {
    // The columns are not proof that the v47 block completed. The block must
    // also create the UNIQUE(entity_type, local_pk) index that a v47
    // CREATE TABLE does not have. The insertOrReplace mode in _upsertSyncMap
    // needs that index to replace the previous link and not to add one more
    // row. That part has its own try/catch, thus a failure prints a message
    // and does not throw.
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

  test("a fresh database gets the firefly_id index from onCreate", () async {
    // The lookups by Firefly id run for each remote record of each cycle. The
    // index is in onCreate, not in the table definition, thus a fresh install
    // needs its own test.
    final String path = await freshDatabase("fresh-index");
    final FinanceDatabase database =
        FinanceDatabase(NativeDatabase(File(path)));
    addTearDown(database.close);
    expect(await _indexesOf(database, "firefly_sync_map"),
        contains("firefly_sync_map_entity_type_firefly_id"));
  });
}
