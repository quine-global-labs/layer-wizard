import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

/// Opens the local layer-history database.
///
/// Fedora/Aurora ship `libsqlite3.so.0` but not the unversioned
/// `libsqlite3.so` symlink that `package:sqlite3` looks for by default —
/// that symlink only shows up with `sqlite-devel`, a layer we don't want to
/// require just to run this app. Point `dlopen` at the versioned name
/// instead, same lib, no extra layer needed.
class HistoryDb {
  static Database? _instance;

  static String get _stateDir => '${Platform.environment['HOME']}/.local/state/layer_wizard';
  static String get _dbPath => '$_stateDir/history.db';

  static Database database() {
    final existing = _instance;
    if (existing != null) return existing;

    if (Platform.isLinux) {
      open.overrideFor(OperatingSystem.linux, _openLinuxLibSqlite3);
    }

    final dir = Directory(_stateDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final db = sqlite3.open(_dbPath);
    _migrate(db);
    _instance = db;
    return db;
  }

  static DynamicLibrary _openLinuxLibSqlite3() {
    for (final name in ['libsqlite3.so.0', 'libsqlite3.so']) {
      try {
        return DynamicLibrary.open(name);
      } catch (_) {
        // Try the next candidate.
      }
    }
    throw ArgumentError('Could not find libsqlite3.so.0 or libsqlite3.so');
  }

  static void _migrate(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS nodes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        checksum TEXT NOT NULL UNIQUE,
        base_checksum TEXT,
        parent_id INTEGER REFERENCES nodes(id),
        action TEXT NOT NULL,
        package_name TEXT,
        version TEXT,
        container_image_ref TEXT,
        requested_packages TEXT,
        source TEXT NOT NULL,
        created_at TEXT NOT NULL,
        applied_at TEXT,
        notes TEXT
      );
    ''');
    db.execute('CREATE INDEX IF NOT EXISTS idx_nodes_parent ON nodes(parent_id);');
    db.execute('''
      CREATE TABLE IF NOT EXISTS pointers (
        name TEXT PRIMARY KEY,
        node_id INTEGER NOT NULL REFERENCES nodes(id)
      );
    ''');
  }
}
