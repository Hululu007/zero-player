import 'dart:convert';
import 'dart:io';
import 'dart:developer' as developer;

import 'segment_metadata.dart';
import 'segment_store.dart';
import '../../core/persistence/app_database.dart';

final class SegmentIndex implements SegmentMetadata {
  const SegmentIndex(this.db);
  final AppDatabase db;
  @override
  Future<Map<String, StoredResource>> entries() async {
    final entries = <String, StoredResource>{};
    for (final row in await db.rows(
      'SELECT * FROM segment_index ORDER BY used_at',
    )) {
      try {
        entries[row['cache_key'] as String] = StoredResource(
          file: File(row['path'] as String),
          length: row['bytes'] as int,
          digest: row['digest'] as String,
          statusCode: row['status_code'] as int,
          headers: Map<String, String>.from(
            jsonDecode(row['headers'] as String),
          ),
        );
      } on FormatException {
        _reportDamagedEntry();
      } on TypeError {
        _reportDamagedEntry();
      }
    }
    return entries;
  }

  void _reportDamagedEntry() {
    // Keep the row, file and download pins for recovery; never expose corrupt
    // headers to playback or remove unrelated offline data to restore startup.
    developer.log('已隔离损坏的缓存索引；保留文件和离线引用，请重新下载。', name: 'segment_index');
  }

  @override
  Future<void> put(String key, StoredResource value) => db.customStatement(
    '''INSERT INTO segment_index
    (cache_key,path,bytes,digest,status_code,headers,used_at) VALUES(?,?,?,?,?,?,?)
    ON CONFLICT(cache_key) DO UPDATE SET path=excluded.path,bytes=excluded.bytes,
    digest=excluded.digest,status_code=excluded.status_code,headers=excluded.headers,used_at=excluded.used_at''',
    [
      key,
      value.file.path,
      value.length,
      value.digest,
      value.statusCode,
      jsonEncode(value.headers),
      DateTime.now().millisecondsSinceEpoch,
    ],
  );
  @override
  Future<void> remove(String key) =>
      db.customStatement('DELETE FROM segment_index WHERE cache_key=?', [key]);
  @override
  Future<Set<String>> protectedKeys() async => (await db.rows(
    'SELECT DISTINCT cache_key FROM segment_references',
  )).map((r) => r['cache_key'] as String).toSet();
  @override
  Future<Set<String>> ownedKeys(String owner) async => (await db.rows(
    'SELECT cache_key FROM segment_references WHERE owner=?',
    [owner],
  )).map((row) => row['cache_key'] as String).toSet();
  @override
  Future<Map<String, Set<String>>> ownedKeysFor(Set<String> owners) async {
    final requested = owners.toList();
    final result = {for (final owner in requested) owner: <String>{}};
    // Stay below SQLite's parameter limit, including older Android builds.
    const chunkSize = 400;
    for (var offset = 0; offset < requested.length; offset += chunkSize) {
      final chunk = requested.skip(offset).take(chunkSize).toList();
      final placeholders = List.filled(chunk.length, '?').join(',');
      for (final row in await db.rows(
        'SELECT owner,cache_key FROM segment_references WHERE owner IN ($placeholders)',
        chunk,
      )) {
        result[row['owner']]!.add(row['cache_key'] as String);
      }
    }
    return result;
  }

  @override
  Future<void> pin(String owner, String key) => db.customStatement(
    'INSERT OR IGNORE INTO segment_references VALUES(?,?)',
    [owner, key],
  );
  @override
  Future<void> unpin(String owner) => db.customStatement(
    'DELETE FROM segment_references WHERE owner=?',
    [owner],
  );
  @override
  Future<void> retainPins(String owner, Set<String> keys) =>
      db.atomic(() async {
        final rows = await db.rows(
          'SELECT cache_key FROM segment_references WHERE owner=?',
          [owner],
        );
        for (final row in rows) {
          if (!keys.contains(row['cache_key'])) {
            await db.customStatement(
              'DELETE FROM segment_references WHERE owner=? AND cache_key=?',
              [owner, row['cache_key']],
            );
          }
        }
      }, tables: const {'segment_references'});
}
