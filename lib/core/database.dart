import 'package:sqlite3/sqlite3.dart';

/// SQLite storage: reading positions, chat history, vector index.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const int schemaVersion = 1;

  static AppDatabase open(String path) => AppDatabase._(sqlite3.open(path)).._migrate();

  static AppDatabase inMemory() => AppDatabase._(sqlite3.openInMemory()).._migrate();

  void _migrate() {
    db.execute('PRAGMA journal_mode=WAL;');
    db.execute('PRAGMA synchronous=NORMAL;');
    db.execute('PRAGMA busy_timeout=5000;');
    db.execute('PRAGMA foreign_keys=ON;');
    db.execute('PRAGMA temp_store=MEMORY;');
    db.execute('''
CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS reading_position (
  lib_id TEXT, version_id TEXT, page_path TEXT,
  anchor TEXT, offset_ratio REAL, updated_at INTEGER,
  PRIMARY KEY (lib_id, version_id, page_path)
);
CREATE TABLE IF NOT EXISTS chunk (
  id INTEGER PRIMARY KEY,
  lib_id TEXT, version_id TEXT, page_path TEXT, lang TEXT,
  anchor TEXT, breadcrumb TEXT, text TEXT,
  content_hash TEXT, embed_model TEXT, dim INTEGER,
  vector BLOB,
  updated_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_chunk_scope ON chunk(lib_id, version_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_chunk_key ON chunk(lib_id, version_id, page_path, lang, anchor, content_hash);
CREATE TABLE IF NOT EXISTS chat_session (
  id TEXT PRIMARY KEY, title TEXT, scope TEXT,
  created_at INTEGER, updated_at INTEGER
);
CREATE TABLE IF NOT EXISTS chat_message (
  id INTEGER PRIMARY KEY, session_id TEXT, role TEXT,
  content TEXT, citations TEXT,
  created_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_msg_session ON chat_message(session_id);
''');
    db.execute(
      "INSERT OR REPLACE INTO schema_meta(key, value) VALUES('schema_version', ?)",
      [schemaVersion.toString()],
    );
  }

  // ---- reading position ----

  void saveReadingPosition(String lib, String ver, String page, String? anchor, double ratio) {
    db.execute(
      'INSERT OR REPLACE INTO reading_position VALUES(?,?,?,?,?,?)',
      [lib, ver, page, anchor, ratio, DateTime.now().millisecondsSinceEpoch],
    );
  }

  ({String? anchor, double ratio})? readingPosition(String lib, String ver, String page) {
    final rs = db.select(
      'SELECT anchor, offset_ratio FROM reading_position WHERE lib_id=? AND version_id=? AND page_path=?',
      [lib, ver, page],
    );
    if (rs.isEmpty) return null;
    final row = rs.first;
    return (anchor: row['anchor'] as String?, ratio: (row['offset_ratio'] as num?)?.toDouble() ?? 0);
  }

  /// Flushes WAL pages into the main database file cleanly.
  void checkpoint({bool truncate = false}) {
    try {
      db.execute(truncate ? 'PRAGMA wal_checkpoint(TRUNCATE);' : 'PRAGMA wal_checkpoint(PASSIVE);');
    } catch (_) {}
  }

  void close() {
    checkpoint();
    db.close();
  }
}
