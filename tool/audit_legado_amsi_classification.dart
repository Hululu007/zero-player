// Offline inspection of the current importer and domain policies. Never run rules.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_source_risk.dart';
import 'package:zero_player/features/supervision/domain/adult_source_evidence.dart';
import 'package:zero_player/features/supervision/domain/content_classification.dart';

String sha(List<int> bytes) => sha256.convert(bytes).toString();

// Source files are tracked with LF endings. Normalize Windows worktrees so the
// recorded digest identifies the same source bytes after a fresh checkout.
String sourceSha(File file) =>
    sha(utf8.encode(file.readAsStringSync().replaceAll('\r\n', '\n')));

bool retiredNews(String host) => const [
  'ithome.com',
  'sspai.com',
  'ifanr.com',
].any((domain) => host == domain || host.endsWith('.$domain'));

Map<String, Object?> classify(BookSource source, int? selectedIndex) {
  final hosts = [source.endpoint.host, ...source.mediaHosts];
  final fixedHost = hosts.any(quarantinedBookHost);
  final fixedSource = quarantinedBookSource(source);
  final adult =
      adultBookSource(source) ||
      hosts.any((host) => adultBookHost(host) || knownAdultHost(host));
  final textAdult =
      adultContent('${source.name} ${source.endpoint.host}') ||
      adultContent(source.group, category: true);
  final news =
      source.kind == BookKind.text && retiredNews(source.endpoint.host);
  final fixedBlocked = fixedSource || fixedHost || news;
  final legado = source.legado;
  return {
    'id': source.id,
    'name': source.name,
    'group': source.group,
    'kind': source.kind.name,
    'endpoint_host': source.endpoint.host,
    'media_hosts': source.mediaHosts.toList()..sort(),
    'current_selected_record_index': selectedIndex,
    'fixed_host_quarantine': fixedHost,
    'fixed_source_policy_quarantine': fixedSource,
    'fixed_current_rule_quarantine':
        knownUnsafeBookRule(source) || knownUnavailableBookRule(source),
    'known_unsafe_current_rule': knownUnsafeBookRule(source),
    'known_unavailable_current_rule': knownUnavailableBookRule(source),
    'orphan_history_id_quarantine': quarantinedBookSourceId(source.id),
    'adult_source_classified': adultBookSource(source),
    'adult_by_host': adultBookHost(source.endpoint.host),
    'adult_by_bundled_id': adultBundledSourceId(source.id),
    'adult_evidence_merged': source.adultEvidence,
    'adult_by_source_labels': adultBookLabels(source.name, source.group),
    'adult_filter_applies_from_policy': adult || textAdult,
    'retired_news_host': news,
    'static_normal_mode_when_adult_filter_on':
        !fixedBlocked && !(adult || textAdult),
    'static_normal_mode_when_adult_filter_off': !fixedBlocked,
    'new_import_enabled_by_default': false,
    'supervision_blocks_nonbuiltin_import': !source.builtin,
    'rule': {
      'format': source.format.name,
      'legado_present': legado != null,
      'search_present':
          source.search.isNotEmpty || (legado?.search.isNotEmpty ?? false),
      'explore_enabled': legado?.enabledExplore,
      'explore_category_count': legado?.categories.length ?? 0,
      'library_present': legado?.library.isNotEmpty ?? false,
      'normalized_rule_keys': legado == null
          ? <String>[]
          : (legado.rules.keys.toList()..sort()),
      'normalized_legado_sha256': legado == null
          ? null
          : sha(utf8.encode(jsonEncode(legado.toJson()))),
    },
  };
}

void main(List<String> args) {
  if (args.length != 3) {
    throw const FormatException(
      'expected summary JSON, clusters JSON and output JSON',
    );
  }
  final summaryBytes = File(args[0]).readAsBytesSync();
  final clusterBytes = File(args[1]).readAsBytesSync();
  final summary = jsonDecode(utf8.decode(summaryBytes)) as Map;
  final cluster = jsonDecode(utf8.decode(clusterBytes)) as Map;
  final oldHits = (summary['detection_observations'] as List).cast<Map>();
  final ids = <String>{
    for (final row in oldHits)
      ...(row['selected_source_ids'] as List).cast<String>(),
  };
  final folder = 'assets/catalogs/books/legado';
  final manifest =
      jsonDecode(File('$folder/manifest.json').readAsStringSync()) as Map;
  final archive = File('$folder/catalog.json.bz2').readAsBytesSync();
  if (sha(archive) != manifest['archiveSha256'] ||
      sha(archive) != summary['archive_sha256']) {
    throw const FormatException('catalog archive hash mismatch');
  }
  final catalog =
      jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive))) as Map;
  final rows = catalog['records'] as List;
  final packs = catalog['packs'] as Map;
  final combined = <Object?>[];
  final selectedIndex = <String, int>{};
  final versions = <String, int>{};
  for (final pack in manifest['packs'] as List) {
    final refs = (packs[pack['id']] as List).cast<int>();
    if (refs.length != pack['count']) {
      throw const FormatException('pack count mismatch');
    }
    for (final index in refs) {
      combined.add(rows[index]);
      try {
        final source = parseBookSourceRecord(rows[index]);
        if (!ids.contains(source.id)) continue;
        if (!versions.containsKey(source.id) ||
            source.updatedAt > versions[source.id]!) {
          selectedIndex[source.id] = index;
          versions[source.id] = source.updatedAt;
        }
      } on Object {
        // Same import rejection semantics as parseBookSourceRecords.
      }
    }
  }
  final imported = parseBookSourceRecords(combined);
  final selected = {for (final source in imported.sources) source.id: source};
  final classification = <Map<String, Object?>>[];
  for (final id in ids.toList()..sort()) {
    final source = selected[id];
    classification.add(
      source == null
          ? {'id': id, 'missing_from_current_import': true}
          : classify(source, selectedIndex[id]),
    );
  }
  final clusterRows = {
    for (final row in (cluster['results'] as List).cast<Map>())
      row['host']: row,
  };
  const codePaths = [
    'lib/features/books/data/book_import.dart',
    'lib/features/books/data/legado/legado_import.dart',
    'lib/features/books/data/books_repository.dart',
    'lib/features/books/data/audiobook_files.dart',
    'lib/features/books/data/book_client.dart',
    'lib/features/books/data/bookan_audio_client.dart',
    'lib/features/books/data/book_comic_download.dart',
    'lib/features/books/data/book_discovery_paging.dart',
    'lib/features/books/data/book_download_coordinator.dart',
    'lib/features/books/data/book_policy_evidence.dart',
    'lib/features/books/data/book_repository_discovery.dart',
    'lib/features/books/data/book_repository_media_access.dart',
    'lib/features/books/data/book_repository_mutations.dart',
    'lib/features/books/data/book_repository_policy_review.dart',
    'lib/features/books/data/book_repository_probe.dart',
    'lib/features/books/data/book_repository_request_policy.dart',
    'lib/features/books/data/book_repository_site_checks.dart',
    'lib/features/books/data/book_request_guard.dart',
    'lib/features/books/data/book_site_check.dart',
    'lib/features/books/data/book_site_inspection.dart',
    'lib/features/books/data/book_site_observed_sources.dart',
    'lib/features/books/data/book_site_revision.dart',
    'lib/features/books/data/book_site_script_clues.dart',
    'lib/features/books/data/book_supervised_site_scan.dart',
    'lib/features/books/data/book_store.dart',
    'lib/features/books/data/legado/legado_client.dart',
    'lib/features/books/data/lit2go_audio_client.dart',
    'lib/features/books/data/shuyin_audio_client.dart',
    'lib/features/books/data/ximalaya_audio_client.dart',
    'lib/features/books/domain/book.dart',
    'lib/features/books/domain/book_source_risk.dart',
    'lib/features/books/domain/biquge7_legacy_source_fix.dart',
    'lib/features/books/domain/jhsssd_legacy_source_fix.dart',
    'lib/features/books/domain/com_rdap_legacy_quarantine.dart',
    'lib/features/books/domain/novel_242_legacy_quarantine.dart',
    'lib/features/books/domain/redirected_legacy_quarantine.dart',
    'lib/features/books/domain/fanfanu_legacy_source_fix.dart',
    'lib/features/books/domain/net_rdap_legacy_quarantine.dart',
    'lib/features/books/domain/moe_rdap_legacy_quarantine.dart',
    'lib/features/books/domain/top_rdap_legacy_quarantine.dart',
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
    'lib/features/books/domain/book_site_audit_clues.dart',
    'lib/features/books/application/book_category_policy.dart',
    'lib/features/books/application/book_site_checks.dart',
    'lib/features/books/application/book_site_monitor.dart',
    'lib/features/supervision/domain/content_classification.dart',
    'lib/features/supervision/domain/adult_source_evidence.dart',
    'lib/features/supervision/application/content_policy.dart',
  ];
  final output = {
    'generated_at': DateTime.now().toUtc().toIso8601String(),
    'archive_sha256': sha(archive),
    'audit_script_sha256': sha(
      File(Platform.script.toFilePath()).readAsBytesSync(),
    ),
    'amsi_summary_sha256': sha(summaryBytes),
    'amsi_clusters_sha256': sha(clusterBytes),
    'scope':
        'Only static current application importer, fixed domain/rule policy and adult metadata; no rule execution, web request, stored user settings, user blacklist or risk database inspected.',
    'limitations':
        'Eligibility assumes supervision disabled, valid supervision state, risk loaded, no user-specific blocks or dynamic assessments, and normal-mode settings as labeled. Imported sources start disabled. It does not establish actual enabled state, parser usability, safety or a malware verdict.',
    'source_digest_convention':
        'SHA-256 of UTF-8 source bytes with CRLF normalized to LF, matching tracked source line endings.',
    'current_policy_code_sha256': {
      for (final path in codePaths) path: sourceSha(File(path)),
    },
    'old_selected_ids': ids.length,
    'current_import_total_ids': imported.sources.length,
    'sources': classification,
    'detected_hosts': [
      for (final hit in oldHits)
        {
          'host': hit['host'],
          'record_indices': hit['record_indices'],
          'old_selected_source_ids': hit['selected_source_ids'],
          'initial_sample_observed_at': hit['sample_observed_at'],
          'initial_sample_bytes': hit['sample_bytes'],
          'initial_sample_truncated': hit['truncated'],
          'initial_sample_sha256': hit['sample_sha256'],
          'initial_amsi': hit['amsi'],
          'initial_detected_inline_scripts': hit['detected_inline_scripts'],
          'cluster_recheck_http_status':
              clusterRows[hit['host']]?['http_status'],
          'cluster_recheck_failure': clusterRows[hit['host']]?['failure'],
          'cluster_recheck_amsi': clusterRows[hit['host']]?['amsi'],
          'cluster_shape_sha256': clusterRows[hit['host']]?['shape_sha256'],
        },
    ],
  };
  final out = File(args[2]);
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(output)}\n',
  );
  stdout.writeln(
    'old ids ${ids.length}; current found ${classification.where((r) => r['missing_from_current_import'] != true).length}; total imported ${imported.sources.length}',
  );
}
