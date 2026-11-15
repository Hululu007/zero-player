import 'dart:convert';

import 'package:crypto/crypto.dart';

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
    this.recordKey,
  });

  final String sourceId, name, host;
  final bool adult, quarantined;
  final bool adultHost, quarantinedHost;
  final int version;

  /// Existing installations use the source ID as the key. Additional hosts
  /// have their own deterministic key and independent review revision.
  final String? recordKey;
  String get key => recordKey ?? sourceId;

  Map<String, Object> toJson() => {
    'name': name,
    'host': host,
    'adult': adult,
    'quarantined': quarantined,
    'adultHost': adultHost,
    'quarantinedHost': quarantinedHost,
    'version': version,
  };

  factory BookSourceAssessment.fromJson(
    String id,
    Object? data, {
    String? recordKey,
  }) {
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
        (data['version'] as int) < 1 ||
        (recordKey != null &&
            recordKey != id &&
            recordKey !=
                BookSourceRiskStore.hostKey(id, data['host'] as String))) {
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
        recordKey: recordKey,
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
      recordKey: recordKey,
    );
  }
}

/// The stored fields are deliberately limited to evidence and an identity;
/// fetched HTML and credentials are never persisted here.
final class BookSourceRiskStore {
  const BookSourceRiskStore(this.db);
  final AppDatabase db;
  static const _prefix = 'books_source_risk:';

  static String hostKey(String sourceId, String host) =>
      '$sourceId:${sha256.convert(utf8.encode(host.toLowerCase()))}';

  static String _sourceId(String key) => key.split(':').first;

  Future<Map<String, BookSourceAssessment>> all() async {
    final rows = await db.rows(
      "SELECT key,value FROM app_meta WHERE key GLOB 'books_source_risk:*'",
    );
    final result = <String, BookSourceAssessment>{};
    for (final row in rows) {
      final key = (row['key'] as String).substring(_prefix.length);
      final id = _sourceId(key);
      Object? value;
      try {
        value = jsonDecode(row['value'] as String);
      } on Object {
        // Treat invalid JSON exactly like a damaged risk record.
      }
      result[key] = BookSourceAssessment.fromJson(id, value, recordKey: key);
    }
    return result;
  }

  Future<BookSourceAssessment?> get(String id) => getRecord(id);

  Future<BookSourceAssessment?> getRecord(String key) async {
    final rows = await db.rows('SELECT value FROM app_meta WHERE key=?', [
      '$_prefix$key',
    ]);
    if (rows.isEmpty) return null;
    Object? value;
    try {
      value = jsonDecode(rows.single['value'] as String);
    } on Object {
      // Keep damaged records restricted.
    }
    return BookSourceAssessment.fromJson(_sourceId(key), value, recordKey: key);
  }

  Future<void> write(BookSourceAssessment assessment) => db.write(
    'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
    ['$_prefix${assessment.key}', jsonEncode(assessment.toJson())],
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
    this.adultRestricted = false,
    this.recordKey,
  });

  final String sourceId, name, host;
  final bool adult, quarantined, fixedQuarantine;

  /// A different record for this source can restrict the whole ID even when
  /// this host itself has no adult evidence.
  final bool adultRestricted;
  final int version;
  final String? recordKey;
}
