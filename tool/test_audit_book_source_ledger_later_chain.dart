// Offline provenance, version and bounded-sample association checks.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';

import 'book_source_ledger_later_chain.dart' as audit;

void check(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

String hash(List<int> bytes) => sha256.convert(bytes).toString();

final class Fixture {
  Fixture()
    : archive = File(
        'assets/catalogs/books/legado/catalog.json.bz2',
      ).readAsBytesSync(),
      sfwxBytes = File(
        'docs/implementation/${audit.sfwx3984EvidenceFile}',
      ).readAsBytesSync(),
      categoryBytes = File(
        'docs/implementation/${audit.biquge7EvidenceFile}',
      ).readAsBytesSync() {
    sfwx = jsonDecode(utf8.decode(sfwxBytes)) as Map;
    categories = jsonDecode(utf8.decode(categoryBytes)) as Map;
    rows =
        (jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive)))
                as Map)['records']
            as List;
  }
  final List<int> archive, sfwxBytes, categoryBytes;
  late final Map sfwx, categories;
  late final List rows;

  audit.LaterChainLedgerEvidence load({
    Map? sfwxValue,
    Map? categoryValue,
    List? rawRecords,
    Map<String, String>? hashes,
  }) => audit.readLaterChainEvidence(
    sfwxValue ?? sfwx,
    categoryValue ?? categories,
    hashes ??
        {
          'assets/catalogs/books/legado/catalog.json.bz2': hash(archive),
          'docs/implementation/${audit.sfwx3984EvidenceFile}': hash(sfwxBytes),
          'docs/implementation/${audit.biquge7EvidenceFile}': hash(
            categoryBytes,
          ),
        },
    rawRecords ?? rows,
  );
}

void checkSamples(Fixture fixture, audit.LaterChainLedgerEvidence linked) {
  for (final index in [3984, 828, 3002, 2578]) {
    final source = parseBookSourceRecord(fixture.rows[index]);
    final selected = audit.selectLaterChainEvidence(linked, source, index);
    check(selected.length == 1, 'expected one observation for $index');
    final row = selected.single;
    check(
      row['historical_selected_record_index'] == index &&
          row['matches_current_selected_raw_record'] == true &&
          row['matches_current_full_endpoint'] == true &&
          row['matches_current_source_kind'] == true &&
          row['matches_current_source_format'] == true &&
          row['matches_current_normalized_legado_rule'] == (index == 2578) &&
          row['site_security_verified'] == null &&
          row['full_readability_verified'] == null &&
          row['whole_source_unavailable_verified'] == null &&
          row['current_rule_validity_verified'] == null &&
          row['redirects_followed'] == false &&
          row['post_sent'] == false &&
          row['scripts_executed'] == false &&
          row['subresources_loaded'] == false,
      'incorrect identity, old-rule match or sampling boundary for $index',
    );
    final samples = row['samples'] as Map;
    if (index == 3984) {
      checkSfwxSamples(samples);
    } else if (index == 2578) {
      final previous = samples['previous_search'] as Map;
      final latest = samples['latest_search'] as Map;
      check(
        previous['status'] == 404 &&
            ((latest['requests'] as List).single as Map)['status'] == 404 &&
            (latest['engine_results'] as List).isEmpty,
        '404s must remain search-only without an inferred site verdict',
      );
    } else {
      checkCategorySamples(row, samples, source.id, index);
    }
  }
}

void checkSfwxSamples(Map samples) {
  for (final work in ['work_a', 'work_b']) {
    final data = samples[work] as Map;
    final results = (data['engine_results'] as List).cast<Map>();
    final old = results.singleWhere(
      (r) => r['stage'] == 'details' && r['candidate'] == false,
    );
    final fixed = results.singleWhere(
      (r) => r['stage'] == 'details' && r['candidate'] == true,
    );
    final oldContent = results.singleWhere(
      (r) => r['stage'] == 'content' && r['candidate'] == false,
    );
    final fixedContent = results.singleWhere(
      (r) => r['stage'] == 'content' && r['candidate'] == true,
    );
    check(
      old['known_error'] == 'selector_depth_limit' &&
          fixed['actual_title_rule_matches'] == true &&
          fixed['author_matches'] == true &&
          fixed['category_present'] == true &&
          oldContent['next_content_count'] == 2 &&
          fixedContent['next_content_count'] == 0 &&
          oldContent['content_sha256'] == fixedContent['content_sha256'],
      'two-work original/candidate comparison lost',
    );
  }
  final extra = samples['additional_chapter_samples'] as Map;
  final results = (extra['engine_results'] as List).cast<Map>();
  check(
    (extra['requests'] as List).length == 5 &&
        results.length == 6 &&
        results.map((r) => r['sampled_ordinal']).toSet().length == 3,
    'bounded additional chapter coverage changed',
  );
}

void checkCategorySamples(Map row, Map samples, String id, int index) {
  check(
    row['shared_category_sample_collected_by_source_id'] ==
            '03ce53f0b6632695058a7553e513b103e5aae06c34979992769d32e06af05fa8' &&
        row['shared_category_sample_collected_by_record_index'] == 828,
    'shared page request owner missing',
  );
  final category = samples['shared_category_check'] as Map;
  final results = (category['engine_results'] as List).cast<Map>();
  check(
    results.length == 8 &&
        results.every((r) => r['id'] == id) &&
        results.every(
          (r) =>
              r['category_meta_count'] == 1 &&
              r['category_present'] == r['candidate'] &&
              r['category_matches_meta'] == r['candidate'],
        ),
    'shared page parser results not scoped to the selected source',
  );
  if (index == 828) {
    check(
      samples.containsKey('work_a') && samples.containsKey('work_b'),
      'two reading samples are missing',
    );
  } else {
    check(
      !samples.containsKey('work_a') && !samples.containsKey('work_b'),
      'the other source must not inherit 828 reading samples',
    );
  }
}

Map<String, Object?> oldConfiguration(BookSource source, Map raw, int index) {
  final info = raw['ruleBookInfo'] as Map;
  final rules = {...source.legado!.rules, 'infoCategory': info['kind']};
  if (index == 3984) {
    rules.addAll({
      'infoInit': info['init'],
      'infoTitle': info['name'],
      'infoAuthor': info['author'],
      'infoDescription': info['intro'],
      'infoCover': info['coverUrl'],
      'infoLatest': info['lastChapter'],
      'nextContent': (raw['ruleContent'] as Map)['nextContentUrl'],
    });
  }
  return {
    ...source.toJson(),
    'discoveryCategories': [
      {'title': '自定义', 'url': '/custom'},
    ],
    'legado': {...source.legado!.toJson(), 'rules': rules},
  };
}

void checkVariants(Fixture fixture, audit.LaterChainLedgerEvidence linked) {
  for (final index in [3984, 828, 3002, 2578]) {
    final source = parseBookSourceRecord(fixture.rows[index]);
    final original = BookSource.fromJson(
      oldConfiguration(source, fixture.rows[index] as Map, index),
    );
    final old = audit.selectLaterChainEvidence(linked, original, index).single;
    check(
      old['matches_current_normalized_legado_rule'] == true,
      'exact historical rule must match for $index',
    );
    final changed = BookSource.fromJson({
      ...original.toJson(),
      'legado': {...original.legado!.toJson(), 'search': '/different-search'},
    });
    check(
      changed.id == source.id &&
          audit
                  .selectLaterChainEvidence(linked, changed, index)
                  .single['matches_current_normalized_legado_rule'] ==
              false,
      'same-ID updated rules must remain historical for $index',
    );
    final moved = BookSource.fromJson({
      ...source.toJson(),
      'url': 'https://${source.endpoint.host}/changed',
    });
    check(
      moved.id == source.id &&
          audit
                  .selectLaterChainEvidence(linked, moved, index)
                  .single['matches_current_full_endpoint'] ==
              false,
      'same-ID changed endpoint must remain distinct for $index',
    );
    check(
      audit
              .selectLaterChainEvidence(linked, source, index + 1)
              .single['matches_current_selected_raw_record'] ==
          false,
      'different selected record must remain historical for $index',
    );
    final otherId = BookSource.fromJson({
      ...source.toJson(),
      'sourceKey': 'fixture:other-id',
    });
    check(
      audit.selectLaterChainEvidence(linked, otherId, index).isEmpty,
      'another source ID must not inherit the sample',
    );
  }
  final tagged = parseBookSourceRecord(fixture.rows[828]);
  final otherHost = BookSource.fromJson({
    ...tagged.toJson(),
    'url': 'https://unrelated.example/',
  });
  check(
    otherHost.id == tagged.id &&
        audit.selectLaterChainEvidence(linked, otherHost, 828).isEmpty,
    'same ID on another host must not inherit the observation',
  );
}

void checkTampering(Fixture fixture) {
  void rejects(bool sfwx, void Function(Map) mutate, String reason) {
    final copy =
        jsonDecode(jsonEncode(sfwx ? fixture.sfwx : fixture.categories)) as Map;
    mutate(copy);
    var rejected = false;
    try {
      fixture.load(
        sfwxValue: sfwx ? copy : null,
        categoryValue: sfwx ? null : copy,
      );
    } on FormatException {
      rejected = true;
    }
    check(rejected, reason);
  }

  rejects(
    true,
    (e) => e['source']['id'] = '0' * 64,
    'changed source ID accepted',
  );
  rejects(
    true,
    (e) => e['source']['endpoint_sha256'] = '0' * 64,
    'changed endpoint accepted',
  );
  rejects(
    false,
    (e) => e['sources'][0]['index'] = 3002,
    'duplicate selected index accepted',
  );
  rejects(
    false,
    (e) => e['sources'][0]['old_legado_canonical_sha256'] = '0' * 64,
    'changed old rule accepted',
  );
  rejects(
    false,
    (e) => e['observations']['record_2578_previous_search']['status'] = 200,
    'altered earlier 404 accepted',
  );
  rejects(
    false,
    (e) => e['inputs']['historical_files']['ledger']['sha256'] = '0' * 64,
    'changed historical ledger digest accepted',
  );
  for (final index in [3984, 828, 2578]) {
    final rows = [...fixture.rows];
    rows[index] = {...rows[index] as Map, 'bookSourceName': 'changed'};
    var rejected = false;
    try {
      fixture.load(rawRecords: rows);
    } on FormatException {
      rejected = true;
    }
    check(rejected, 'changed historical raw record $index accepted');
  }
}

void checkFullReplay() {
  final root = Directory.systemTemp.createTempSync('zero-player-later-ledger-');
  final output = File('${root.path}/ledger.json');
  try {
    final run = Process.runSync(Platform.resolvedExecutable, [
      'tool/audit_book_source_ledger.dart',
      output.path,
    ]);
    check(run.exitCode == 0, 'offline ledger generation failed: ${run.stderr}');
    final ledger = jsonDecode(output.readAsStringSync()) as Map;
    final rows = (ledger['sources'] as List).cast<Map>();
    for (final (file, count) in [
      (audit.sfwx3984EvidenceFile, 1),
      (audit.biquge7EvidenceFile, 3),
    ]) {
      final linked = rows
          .where(
            (source) => (source['specialized_reading_observations'] as List)
                .cast<Map>()
                .any((r) => r['evidence'] == file),
          )
          .toList();
      check(linked.length == count, 'wrong source count for $file');
    }
    final src = rows.singleWhere((row) => row['selected_record_index'] == 3002);
    final sample = (src['specialized_reading_observations'] as List)
        .cast<Map>()
        .singleWhere((row) => row['evidence'] == audit.biquge7EvidenceFile);
    check(
      sample['matches_current_normalized_legado_rule'] == false &&
          sample['shared_category_sample_collected_by_record_index'] == 828 &&
          sample['site_security_verified'] == null,
      'repaired rule or shared sample provenance lost',
    );
    final code = ledger['normalized_source_code_sha256'] as Map;
    final runtime =
        ledger['runtime_policy_reference_only_normalized_sha256'] as Map;
    check(
      code.containsKey('tool/book_source_ledger_later_chain.dart') &&
          code.containsKey('tool/verify_legado_sfwx_3984.py') &&
          code.containsKey('tool/verify_legado_biquge7_category.py') &&
          code.containsKey('tool/verify_legado_later_chain_common.py') &&
          code.containsKey(
            'lib/features/books/domain/biquge7_legacy_source_fix.dart',
          ) &&
          runtime.containsKey(
            'lib/features/books/data/book_site_revision.dart',
          ),
      'new source, verifier or runtime policy reference missing',
    );
    check(
      (ledger['later_chain_historical_ledger_reference']
              as Map)['verified_from_git_object'] ==
          true,
      'historical Git verification reference missing',
    );
  } finally {
    if (output.existsSync()) output.deleteSync();
    root.deleteSync();
  }
}

void main() {
  final fixture = Fixture();
  final linked = fixture.load();
  checkSamples(fixture, linked);
  checkVariants(fixture, linked);
  checkTampering(fixture);
  checkFullReplay();
  stdout.writeln(
    'later-chain source evidence association offline checks passed',
  );
}
