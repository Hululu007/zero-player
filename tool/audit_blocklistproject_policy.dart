// Offline replay of the current importer and static policies for listed-source
// clues. No source rules are executed and no network or user database is used.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_source_risk.dart';

import 'audit_legado_amsi_classification.dart' as prior;

String digest(List<int> bytes) => sha256.convert(bytes).toString();

const codePaths = [
  'lib/features/books/data/book_import.dart',
  'lib/features/books/data/legado/legado_import.dart',
  'lib/features/books/data/legado/legado_request.dart',
  'lib/features/books/data/legado/legado_discovery.dart',
  'lib/features/books/data/book_source_links.dart',
  'lib/features/books/domain/book.dart',
  'lib/features/books/domain/book_source_risk.dart',
  'lib/features/books/domain/biquge7_legacy_source_fix.dart',
  'lib/features/books/domain/com_rdap_legacy_quarantine.dart',
  'lib/features/books/domain/novel_242_legacy_quarantine.dart',
  'lib/features/books/domain/redirected_legacy_quarantine.dart',
  'lib/features/books/domain/fanfanu_legacy_source_fix.dart',
  'lib/features/books/domain/net_rdap_legacy_quarantine.dart',
  'lib/features/books/domain/moe_rdap_legacy_quarantine.dart',
  'lib/features/books/domain/iqiyi_legacy_quarantine.dart',
  'lib/features/books/domain/taotaoshu_legacy_quarantine.dart',
  'lib/features/books/domain/legado_source_fingerprint.dart',
  'lib/features/books/domain/known_untrusted_book_rules.dart',
  'lib/features/books/domain/legado_source.dart',
  'lib/features/books/domain/legado_source_fixes.dart',
  'lib/features/books/domain/kuwo_legacy_source_fix.dart',
  'lib/features/books/domain/qq_reading_legacy_source_fix.dart',
  'lib/features/books/domain/yuque_legacy_source_fix.dart',
  'lib/features/books/domain/zhongyi_legacy_source_fix.dart',
  'lib/features/books/domain/jingzhi_legacy_source_fix.dart',
  'lib/features/books/domain/shubang_legacy_source_fix.dart',
  'lib/features/books/domain/sfwx_legacy_source_fix.dart',
  'lib/features/books/domain/yingyu_legacy_source_fix.dart',
  'lib/features/supervision/domain/content_classification.dart',
  'lib/features/supervision/domain/adult_source_evidence.dart',
  'tool/audit_legado_amsi_classification.dart',
  'tool/audit_blocklistproject_policy.dart',
];

typedef AuditTargets = ({
  Set<String> ids,
  Map<String, Set<String>> exact,
  Map<String, Map<String, String>> exactHosts,
  Map<String, int> historicalIndices,
});

AuditTargets readTargets(Map evidence) {
  final categories = (evidence['comparison'] as Map)['categories'] as Map;
  final ids = <String>{};
  final exact = <String, Set<String>>{};
  final exactHosts = <String, Map<String, String>>{};
  final historicalIndices = <String, int>{};
  for (final entry in categories.entries) {
    final category = entry.key as String;
    final groups = (entry.value as Map)['selected_sources_by_relation'] as Map;
    for (final group in groups.entries) {
      for (final row in (group.value as List).cast<Map>()) {
        final id = row['source_id'] as String;
        final index = row['selected_record_index'] as int;
        if (historicalIndices.containsKey(id) &&
            historicalIndices[id] != index) {
          throw const FormatException(
            'same ID has inconsistent selected indices',
          );
        }
        ids.add(id);
        historicalIndices[id] = index;
        if (group.key == 'exact_endpoint') {
          exact.putIfAbsent(id, () => <String>{}).add(category);
          exactHosts.putIfAbsent(id, () => {})[category] =
              row['source_endpoint_host'] as String;
        }
      }
    }
  }
  return (
    ids: ids,
    exact: exact,
    exactHosts: exactHosts,
    historicalIndices: historicalIndices,
  );
}

List<String> currentExactCategories(
  AuditTargets targets,
  String id,
  String host,
) =>
    (targets.exact[id] ?? const <String>{})
        .where((category) => targets.exactHosts[id]?[category] == host)
        .toList()
      ..sort();

typedef ReplayedImport = ({
  BookSourceImport imported,
  Map<String, int> currentIndices,
  Map<String, List<Map<String, Object?>>> adultVariants,
});

ReplayedImport replayImport(Map manifest, Map catalog, AuditTargets targets) {
  final rows = catalog['records'] as List;
  final packs = catalog['packs'] as Map;
  final combined = <Object?>[];
  final adultVariants = <String, List<Map<String, Object?>>>{};
  final seenIndices = <int>{};
  final currentIndices = <String, int>{};
  final versions = <String, int>{};
  for (final pack in manifest['packs'] as List) {
    final refs = (packs[pack['id']] as List).cast<int>();
    if (refs.length != pack['count'] ||
        refs.any((index) => index < 0 || index >= rows.length)) {
      throw const FormatException('invalid pack references');
    }
    combined.addAll(refs.map((index) => rows[index]));
    for (final index in refs) {
      if (!seenIndices.add(index)) continue;
      try {
        final source = parseBookSourceRecord(rows[index]);
        if (targets.ids.contains(source.id) &&
            (!versions.containsKey(source.id) ||
                source.updatedAt > versions[source.id]!)) {
          currentIndices[source.id] = index;
          versions[source.id] = source.updatedAt;
        }
        if (!targets.exact.containsKey(source.id) || !adultBookSource(source)) {
          continue;
        }
        adultVariants.putIfAbsent(source.id, () => []).add({
          'record_index': index,
          'name': source.name,
          'group': source.group,
          'host': source.endpoint.host,
          'adult_by_labels': adultBookLabels(source.name, source.group),
          'adult_by_host': adultBookHost(source.endpoint.host),
          'adult_by_bundled_id': adultBundledSourceId(source.id),
          'adult_evidence_field': source.adultEvidence,
        });
      } on Object {
        // Keep the production importer's rejection behavior.
      }
    }
  }
  return (
    imported: parseBookSourceRecords(combined),
    currentIndices: currentIndices,
    adultVariants: adultVariants,
  );
}

void main(List<String> args) {
  if (args.length != 2) {
    throw const FormatException(
      'expected grouped offline evidence and output paths',
    );
  }
  final initialHashes = {
    for (final path in codePaths) path: prior.sourceSha(File(path)),
  };
  final evidenceBytes = File(args[0]).readAsBytesSync();
  final evidence = jsonDecode(utf8.decode(evidenceBytes)) as Map;
  final targets = readTargets(evidence);
  final folder = 'assets/catalogs/books/legado';
  final manifest =
      jsonDecode(File('$folder/manifest.json').readAsStringSync()) as Map;
  final archive = File('$folder/catalog.json.bz2').readAsBytesSync();
  if (digest(archive) != manifest['archiveSha256'] ||
      digest(archive) != (evidence['catalog'] as Map)['archive_sha256']) {
    throw const FormatException('catalog archive hash mismatch');
  }
  final catalog =
      jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive))) as Map;
  final replay = replayImport(manifest, catalog, targets);
  final imported = replay.imported;
  final current = <String, BookSource>{
    for (final source in imported.sources) source.id: source,
  };
  final classifications = <Map<String, Object?>>[];
  final manualReview = <Map<String, Object?>>[];
  final unresolvedExact = <String>[];
  for (final id in targets.ids.toList()..sort()) {
    final source = current[id];
    if (source == null) {
      classifications.add({'id': id, 'missing_from_current_import': true});
      if (targets.exact.containsKey(id)) unresolvedExact.add(id);
      continue;
    }
    final result = prior.classify(source, replay.currentIndices[id]);
    // Keep the review output to identity and policy findings, not rule details.
    result.remove('rule');
    result['historical_selected_record_index'] = targets.historicalIndices[id];
    final currentExact = currentExactCategories(
      targets,
      id,
      source.endpoint.host,
    );
    if (targets.exact.containsKey(id) &&
        currentExact.length != targets.exact[id]!.length) {
      unresolvedExact.add(id);
    }
    result['matching_exact_endpoint_categories'] = currentExact;
    classifications.add(result);
    if (currentExact.isNotEmpty &&
        result['static_normal_mode_when_adult_filter_on'] == true) {
      manualReview.add({
        'id': id,
        'name': source.name,
        'kind': source.kind.name,
        'host': source.endpoint.host,
        'selected_record_index': replay.currentIndices[id],
        'historical_selected_record_index': targets.historicalIndices[id],
        'categories': currentExact,
        'basis':
            'Exact listed endpoint; current static adult-filter and fixed quarantine checks do not exclude the imported source under the stated assumptions. This is a review lead, not a safety or content verdict.',
      });
    }
  }
  for (final path in codePaths) {
    if (prior.sourceSha(File(path)) != initialHashes[path]) {
      throw FormatException('policy code changed during the audit: $path');
    }
  }
  final output = {
    'generated_at': DateTime.now().toUtc().toIso8601String(),
    'archive_sha256': digest(archive),
    'grouped_evidence_sha256': digest(evidenceBytes),
    'policy_script_sha256': digest(
      File(Platform.script.toFilePath()).readAsBytesSync(),
    ),
    'source_digest_convention':
        'SHA-256 of UTF-8 source bytes with CRLF normalized to LF, matching tracked source line endings.',
    'current_policy_code_sha256': initialHashes,
    'scope':
        'Offline current importer and fixed source/domain/adult rules only; no source rule execution, site request, user settings, blacklist or dynamic risk database.',
    'limitations':
        'Static normal-mode result assumes loaded, uncorrupted policy, adult filtering on, and no user-specific restrictions. Imported sources start disabled; supervision independently blocks non-builtin sources and all comics/audio. This is not a claim about current content or installation.',
    'matched_selected_ids': targets.ids.length,
    'current_import_total_ids': imported.sources.length,
    'current_import_missing_or_changed_exact_endpoint_ids': unresolvedExact,
    'exact_endpoint_manual_review': manualReview,
    'exact_endpoint_adult_variant_evidence': replay.adultVariants,
    'sources': classifications,
  };
  final target = File(args[1]);
  if (target.existsSync()) throw const FormatException('output already exists');
  target.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(output)}\n',
  );
  stdout.writeln(
    '${targets.ids.length} selected IDs; ${manualReview.length} exact-endpoint review leads',
  );
}
