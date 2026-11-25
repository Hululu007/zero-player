import 'dart:convert';

import 'package:flutter/services.dart';

import '../domain/book.dart';
import '../domain/legado_source_fingerprint.dart';
import 'book_source_risk_store.dart';
import 'book_store.dart';

// Only suppress untouched bundled profiles for domains observed redirecting
// to a canonical source. Saved works and private source rules keep their IDs.
const _redirectedCatalogRules = {
  'e308bb0820ca1b48b575bbddaa706b7fe237d235cec5d94541c0b1c797cf42c7': (
    url: 'https://69shuba.cx',
    hash: '99ac1f0ac9848c7f899192c6551a497a78f25f8b4f01d1649937a6258a965c3f',
  ),
  '0cc1db5b5a86559ff69d6e48db7f76954358f1a4fe7cb6f568bb674fcef5babe': (
    url: 'https://m.aixdzs.com',
    hash: '25be93885cbe17cab9de106eb02c3c6a364239a09fd529c29729e6e2d2431483',
  ),
  '886a51d06c75af23bcc6a11d22e6eb14a81e7d1de251785ed0f49004f131a1c0': (
    url: 'https://m.aixdzs.com',
    hash: '6cfcf226a2400524d6bce3147d204af2755c65303c89a9188c42578c0a1bcd5d',
  ),
  'a568074c3fae624683839f246c983dd9722db23af61415b89fdc418fe833407a': (
    url: 'https://m.aixdzs.com',
    hash: '09a7e5163c192ccf087c93fd39e39a7d89f3a3d53f0ac771d0e6fd191ad6b2d2',
  ),
};

bool supersededBundledBookSource(BookSourceEntry entry) {
  if (!entry.fromCatalog) return false;
  final expected = _redirectedCatalogRules[entry.source.id];
  return expected != null &&
      _matchesCatalogRules(entry.source, expected.url, expected.hash);
}

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
        _matchesCatalogRules(
          source,
          expected['url'] as String,
          expected['legadoSha256'] as String,
        );
  } on Object {
    // Persisted user JSON may also fail a cast or enum lookup. Keep the
    // original row recoverable without preventing all built-ins from loading.
    return false;
  }
}

bool _matchesCatalogRules(BookSource source, String url, String hash) =>
    source.endpoint.toString() == url &&
    source.legado != null &&
    source.mediaHosts.isEmpty &&
    source.rules.isEmpty &&
    source.search.isEmpty &&
    source.searchForm.isEmpty &&
    source.discover.isEmpty &&
    source.discoveryCategories.isEmpty &&
    !source.adultEvidence &&
    legadoSourceFingerprint(source.legado!) == hash;
