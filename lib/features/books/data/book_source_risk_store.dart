import 'dart:convert';

import '../../../core/persistence/app_database.dart';

/// An assessed root page belongs to this exact host, independently of a
/// particular source ID or book type. A record also survives source removal.
final class BookSourceAssessment {
  const BookSourceAssessment({
    required this.sourceId,
    required this.name,
    required this.host,
    required this.adult,
    required this.quarantined,
    required this.adultHost,
    required this.quarantinedHost,
    required this.version,
  });

  final String sourceId, name, host;
  final bool adult, quarantined;
  final bool adultHost, quarantinedHost;
  final int version;

  Map<String, Object> toJson() => {
    'name': name,
    'host': host,
    'adult': adult,
    'quarantined': quarantined,
    'adultHost': adultHost,
    'quarantinedHost': quarantinedHost,
    'version': version,
  };

  factory BookSourceAssessment.fromJson(String id, Object? data) {
    if (data is! Map ||
        data['name'] is! String ||
        data['host'] is! String ||
        data['adult'] is! bool ||
        data['quarantined'] is! bool ||
        data['adultHost'] is! bool ||
        data['quarantinedHost'] is! bool ||
        (data['adultHost'] == true && data['adult'] != true) ||
        (data['quarantinedHost'] == true && data['quarantined'] != true) ||
        data['version'] is! int ||
        (data['version'] as int) < 1) {
      // Corrupted evidence is kept restricted until explicitly reviewed.
      return BookSourceAssessment(
        sourceId: id,
        name: '风险记录损坏',
        host: '',
        adult: true,
        quarantined: true,
        adultHost: false,
        quarantinedHost: false,
        version: 1,
      );
    }
    return BookSourceAssessment(
      sourceId: id,
      name: data['name'] as String,
      host: (data['host'] as String).toLowerCase(),
      adult: data['adult'] as bool,
      quarantined: data['quarantined'] as bool,
      adultHost: data['adultHost'] as bool,
      quarantinedHost: data['quarantinedHost'] as bool,
      version: data['version'] as int,
    );
  }
}

/// The stored fields are deliberately limited to evidence and an identity;
/// fetched HTML and credentials are never persisted here.
final class BookSourceRiskStore {
  const BookSourceRiskStore(this.db);
  final AppDatabase db;
  static const _prefix = 'books_source_risk:';

  Future<Map<String, BookSourceAssessment>> all() async {
    final rows = await db.rows(
      "SELECT key,value FROM app_meta WHERE key GLOB 'books_source_risk:*'",
    );
    final result = <String, BookSourceAssessment>{};
    for (final row in rows) {
      final id = (row['key'] as String).substring(_prefix.length);
      Object? value;
      try {
        value = jsonDecode(row['value'] as String);
      } on Object {
        // Treat invalid JSON exactly like a damaged risk record.
      }
      result[id] = BookSourceAssessment.fromJson(id, value);
    }
    return result;
  }

  Future<BookSourceAssessment?> get(String id) async {
    final rows = await db.rows('SELECT value FROM app_meta WHERE key=?', [
      '$_prefix$id',
    ]);
    if (rows.isEmpty) return null;
    Object? value;
    try {
      value = jsonDecode(rows.single['value'] as String);
    } on Object {
      // Keep damaged records restricted.
    }
    return BookSourceAssessment.fromJson(id, value);
  }

  Future<void> write(BookSourceAssessment assessment) => db.write(
    'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
    ['$_prefix${assessment.sourceId}', jsonEncode(assessment.toJson())],
  );
}

/// A review row is a snapshot. Clearing it is conditional on [version].
final class BookSourceRiskEntry {
  const BookSourceRiskEntry({
    required this.sourceId,
    required this.name,
    required this.host,
    required this.adult,
    required this.quarantined,
    required this.fixedQuarantine,
    required this.version,
  });

  final String sourceId, name, host;
  final bool adult, quarantined, fixedQuarantine;
  final int version;
}
