// The copy of the local database that a rebuild makes first. The rebuild
// replaces local data, thus this copy is the way back.
import 'dart:ffi';
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/firefly/fireflySyncEngine.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:sqlite3/open.dart' as sqlite_open;
// ignore: depend_on_referenced_packages
import 'package:sqlite3/sqlite3.dart' as raw;

void main() {
  setUpAll(() {
    if (!Platform.isLinux) return;
    sqlite_open.open.overrideFor(sqlite_open.OperatingSystem.linux, () {
      for (String name in ['libsqlite3.so', 'libsqlite3.so.0']) {
        try {
          return DynamicLibrary.open(name);
        } catch (_) {}
      }
      return DynamicLibrary.open('libsqlite3.so');
    });
  });

  test('the backup is a readable copy that holds the rows', () async {
    Directory folder = await Directory.systemTemp.createTemp("firefly-backup");
    addTearDown(() => folder.delete(recursive: true));
    database = FinanceDatabase(NativeDatabase(File("${folder.path}/db.sqlite")));
    addTearDown(() => database.close());
    await database.into(database.wallets).insert(
        WalletsCompanion.insert(name: "Kept wallet", order: 0));

    String path = await fireflyBackupDatabaseTo(folder.path);

    raw.Database copy = raw.sqlite3.open(path, mode: raw.OpenMode.readOnly);
    addTearDown(copy.dispose);
    expect(copy.select("SELECT name FROM wallets").map((r) => r["name"]),
        contains("Kept wallet"));
  });
}
