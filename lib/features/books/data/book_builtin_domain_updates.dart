import 'dart:convert';

import 'package:flutter/services.dart';

import '../domain/book.dart';
import '../domain/legado_source_fingerprint.dart';
import 'book_source_risk_store.dart';
import 'book_store.dart';

/// Reviewed replacements are separate identities. Historical rules, works,
/// downloads and risk evidence continue to belong to their original hosts.
Future<List<BookSource>> loadReviewedBookDomains(
  BookStore store,
  BookSourceRiskStore risks, {
  required bool migratePreferences,
}) async {
  final data =
      jsonDecode(
            await rootBundle.loadString(
              'assets/catalogs/books/reviewed-domain-updates.json',
            ),
          )
          as Map;
  final updates = (data['updates'] as List).cast<Map>();
  final sources = [
    for (final row in updates)
      BookSource.fromJson(row['source'] as Map, builtin: true),
  ];
  if (!migratePreferences) return sources;
  await store.db.transaction(() async {
    final blocked = await store.blockedSources();
    final assessments = await risks.all();
    for (final (index, source) in sources.indexed) {
      if (await _savedState(store, source.id) != null) continue;
      final previous = (updates[index]['previous'] as List).cast<Map>();
      final ids = previous.map((p) => p['id'] as String).toSet();
      // Deletion and manual risk restrictions must not become enabled just
      // because a reviewed successor has a different identity.
      if (ids.any(blocked.containsKey)) {
        await store.write('books_source:${source.id}', {
          'removed': true,
          'enabled': false,
        });
        continue;
      }
      Map? selected;
      for (final predecessor in previous) {
        final state = await _savedState(store, predecessor['id'] as String);
        if (state is! Map || !_unchangedCatalogSource(state, predecessor)) {
          continue;
        }
        if (selected == null || state['enabled'] == true) selected = state;
      }
      if (selected == null) continue;
      final restricted = assessments.values.any(
        (a) =>
            ids.contains(a.sourceId) &&
            (a.adult || a.quarantined || a.adultHost || a.quarantinedHost),
      );
      await store.write('books_source:${source.id}', {
        'enabled': selected['enabled'] == true && !restricted,
        'favorite': selected['favorite'] == true,
        if (selected['group'] is String) 'group': selected['group'],
        'health': '',
        'checkedAt': null,
      });
    }
  });
  return sources;
}

Future<Object?> _savedState(BookStore store, String id) async {
  try {
    return await store.read('books_source:$id');
  } on FormatException {
    // Leave damaged JSON untouched; it cannot authorize a preference migration.
    return const <String, Object?>{};
  }
}

bool _unchangedCatalogSource(Map state, Map expected) {
  final raw = state['source'];
  if (state['catalog'] != true || state['removed'] == true || raw is! Map) {
    return false;
  }
  try {
    final source = BookSource.fromJson(raw);
    return source.id == expected['id'] &&
        source.endpoint.toString() == expected['url'] &&
        source.legado != null &&
        source.mediaHosts.isEmpty &&
        source.rules.isEmpty &&
        source.search.isEmpty &&
        source.searchForm.isEmpty &&
        source.discover.isEmpty &&
        source.discoveryCategories.isEmpty &&
        !source.adultEvidence &&
        legadoSourceFingerprint(source.legado!) == expected['legadoSha256'];
  } on Object {
    // Persisted user JSON may also fail a cast or enum lookup. Keep the
    // original row recoverable without preventing all built-ins from loading.
    return false;
  }
}
