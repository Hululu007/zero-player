import 'dart:convert';
import 'dart:math';

import '../../../core/persistence/app_database.dart';

/// Independent per-source freshness token. Random generations also invalidate
/// old observations when missing or damaged metadata must be re-created.
final class BookSiteRevisions {
  const BookSiteRevisions(this.db);

  static const prefix = 'books_site_revision:';
  static const upsertSql =
      'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)';
  final AppDatabase db;

  static String key(String id) => '$prefix$id';

  static String newToken() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static String? decode(Object? raw) {
    if (raw is! String) return null;
    try {
      final value = jsonDecode(raw);
      return value is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(value)
          ? value
          : null;
    } on FormatException {
      return null;
    }
  }

  /// The caller must include this write in the source mutation transaction.
  Future<void> change(String id) =>
      db.write(upsertSql, [key(id), jsonEncode(newToken())]);

  Future<String?> get(String id) async {
    final rows = await db.rows('SELECT value FROM app_meta WHERE key=?', [
      key(id),
    ]);
    return rows.isEmpty ? null : decode(rows.single['value']);
  }

  Future<Map<String, String>> _read(Set<String> ids) async {
    final rows = await db.rows(
      "SELECT key,value FROM app_meta WHERE key GLOB 'books_site_revision:*'",
    );
    final found = <String, String>{};
    for (final row in rows) {
      final keyValue = row['key'];
      if (keyValue is! String || !keyValue.startsWith(prefix)) continue;
      final id = keyValue.substring(prefix.length);
      if (!ids.contains(id)) continue;
      final token = decode(row['value']);
      if (token != null) found[id] = token;
    }
    return found;
  }

  /// The common no-change path only reads; it must not trigger UI reloads.
  /// Missing or damaged tokens are rechecked under a write transaction and
  /// replaced by independently generated 128-bit tokens.
  Future<Map<String, String>> ensure(Set<String> ids) async {
    if (ids.isEmpty) return <String, String>{};
    final initial = await _read(ids);
    if (initial.length == ids.length) return initial;
    var changed = false;
    final result = await db.transaction(() async {
      final current = await _read(ids);
      final missing = ids.difference(current.keys.toSet());
      if (missing.isNotEmpty) {
        await db.batch((batch) {
          for (final id in missing) {
            final token = newToken();
            batch.customStatement(upsertSql, [key(id), jsonEncode(token)]);
            current[id] = token;
          }
        });
        changed = true;
      }
      return current;
    });
    if (changed) db.changed(tables: {'app_meta'});
    return result;
  }
}
