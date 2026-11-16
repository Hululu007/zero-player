// Offline association, privacy and integrity checks; no network or Flutter.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';

import 'book_source_ledger_four_risk.dart' as audit;

const _archive = 'assets/catalogs/books/legado/catalog.json.bz2';
const _inventory = 'docs/implementation/legado-import-inventory-20261115.json';
const _amsi = 'docs/implementation/legado-amsi-template-clusters-20261115.json';
const _indices = [36, 1439, 2098, 4568];

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

String hash(List<int> value) => sha256.convert(value).toString();

final class Fixture {
  Fixture() {
    final archive = File(_archive).readAsBytesSync();
    final evidenceBytes = File(
      'docs/implementation/${audit.fourRiskEvidenceFile}',
    ).readAsBytesSync();
    final amsiBytes = File(_amsi).readAsBytesSync();
    hashes = {
      _archive: hash(archive),
      _inventory: hash(File(_inventory).readAsBytesSync()),
      _amsi: hash(amsiBytes),
      'docs/implementation/${audit.fourRiskEvidenceFile}': hash(evidenceBytes),
    };
    evidence = jsonDecode(utf8.decode(evidenceBytes)) as Map;
    amsi = jsonDecode(utf8.decode(amsiBytes)) as Map;
    rows =
        (jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive)))
                as Map)['records']
            as List;
  }

  late final Map evidence, amsi;
  late final List rows;
  late final Map<String, String> hashes;

  audit.FourRiskRevisitLedgerEvidence load({
    Map? value,
    Map? amsiValue,
    List? records,
    Map<String, String>? digests,
  }) => audit.readFourRiskRevisitEvidence(
    value ?? evidence,
    amsiValue ?? amsi,
    digests ?? hashes,
    records ?? rows,
  );
}

Map<String, Object?> linkedRow(
  Fixture f,
  audit.FourRiskRevisitLedgerEvidence linked,
  int index,
) => audit
    .selectFourRiskRevisitEvidence(
      linked,
      parseBookSourceRecord(f.rows[index]),
      index,
    )
    .single;

Map step(Map row, String stage) => (row['http_observations'] as List)
    .cast<Map>()
    .singleWhere((item) => item['stage'] == stage);

Map structure(Map row, String stage) =>
    (row['static_page_structure_observations'] as List).cast<Map>().singleWhere(
      (item) => item['stage'] == stage,
    );

void checkSources(Fixture f, audit.FourRiskRevisitLedgerEvidence linked) {
  var requests = 0, samples = 0, truncations = 0, redirects = 0;
  for (final index in _indices) {
    final source = parseBookSourceRecord(f.rows[index]);
    final row = linkedRow(f, linked, index);
    final http = (row['http_observations'] as List).cast<Map>();
    requests += http.length;
    samples += http.where((value) => value['sample_bytes'] != null).length;
    truncations += http
        .where((value) => value['sample_truncated'] == true)
        .length;
    redirects += http.where((value) => value['redirect'] != null).length;
    final app = row['application_reading_chain'] as Map;
    check(
      row['historical_selected_record_index'] == index &&
          row['matches_current_selected_raw_record'] == true &&
          row['matches_current_source_kind'] == true &&
          row['matches_current_source_format'] == true &&
          row['matches_current_full_endpoint'] == true &&
          row['matches_current_normalized_legado_rule'] == true &&
          row['matches_current_source_configuration'] == true &&
          row['site_security_verified'] == null &&
          row['sitewide_adult_content_verified'] == null &&
          row['whole_source_unavailable_verified'] == null &&
          row['current_rule_validity_verified'] == null &&
          row['historical_runtime_fully_reconstructed'] == false &&
          row['raw_pages_and_collectors_replayable'] == false &&
          row['network_authenticity_offline_verified'] == false &&
          row['overall_wall_deadline_enforced'] == false &&
          app['legado_engine_executed'] == false &&
          app['webview_executed'] == false &&
          app['full_source_readability_verified'] == null,
      'invalid evidence association or unproven conclusion for $index',
    );
    check(
      audit.selectFourRiskRevisitEvidence(linked, source, index + 1).isEmpty,
      'other selected index inherited evidence',
    );
  }
  check(
    requests == 17 && samples == 10 && truncations == 2 && redirects == 4,
    'observation counts changed',
  );
}

void checkRecordedFacts(Fixture f, audit.FourRiskRevisitLedgerEvidence linked) {
  for (final index in [36, 1439, 2098]) {
    final row = linkedRow(f, linked, index);
    final prior = row['historical_amsi_sample'] as Map;
    check(
      prior['root_classification'] == 'detected' &&
          prior['separate_inline_classification'] == 'not_detected' &&
          row['current_amsi_assessment'] == null,
      'historical AMSI result was confused with a current scan',
    );
  }
  final source = linkedRow(f, linked, 2098);
  final oldCategory = step(source, 'old_category_html');
  check(
    oldCategory['visible_characters'] == null &&
        oldCategory['http_status'] == 200,
    'unknown coverage became a known zero',
  );
  final redirect = step(source, 'repeat_home')['redirect'] as Map;
  check(
    redirect['destination_host'] == 'zairuc.com' &&
        redirect['followed'] == false,
    'external redirect attribution changed',
  );
  final mixed = linkedRow(f, linked, 4568);
  final clues = step(mixed, 'initial_home')['visible_text_clues'] as Map;
  check(
    clues['adult_business'] == true &&
        clues['ordinary_genres'] == true &&
        mixed['sitewide_adult_content_verified'] == null,
    'mixed observed text was promoted to a source-wide verdict',
  );
  final search =
      structure(mixed, 'synthetic_search')['static_selector_counts'] as Map;
  final details = structure(mixed, 'detail_1');
  final chapter =
      structure(mixed, 'chapter_1')['static_selector_counts'] as Map;
  final app = mixed['application_reading_chain'] as Map;
  check(
    search['tbody_rows'] == 0 &&
        search['usable_links'] == 0 &&
        details['sample_truncated'] == true &&
        (details['static_selector_counts'] as Map)['old_toc_anchor_count'] ==
            366 &&
        chapter['old_content_selector_matches'] == 1 &&
        chapter['old_content_visible_characters'] == 1646 &&
        app['old_rule_declares_webview_true'] == true &&
        app['inspected_historical_parser_implements_webview_option'] == false &&
        app['application_chapter_readability_verified'] == null,
    'static structure or application execution boundary changed',
  );
}

void checkVariants(Fixture f, audit.FourRiskRevisitLedgerEvidence linked) {
  final source = parseBookSourceRecord(f.rows[4568]);
  final updated = BookSource.fromJson({
    ...source.toJson(),
    'legado': {...source.legado!.toJson(), 'search': '/other-search'},
  });
  final moved = BookSource.fromJson({
    ...source.toJson(),
    'url': 'https://${source.endpoint.host}/different-endpoint',
  });
  final differentId = BookSource.fromJson({
    ...source.toJson(),
    'sourceKey': 'other',
  });
  final differentHost = BookSource.fromJson({
    ...source.toJson(),
    'url': 'https://other.example/',
  });
  check(
    updated.id == source.id && moved.id == source.id,
    'fixture variants unexpectedly changed identity',
  );
  final updatedRow = audit
      .selectFourRiskRevisitEvidence(linked, updated, 4568)
      .single;
  final movedRow = audit
      .selectFourRiskRevisitEvidence(linked, moved, 4568)
      .single;
  check(
    updatedRow['matches_current_normalized_legado_rule'] == false &&
        updatedRow['matches_current_source_configuration'] == false &&
        movedRow['matches_current_full_endpoint'] == false &&
        movedRow['matches_current_source_configuration'] == false,
    'same-ID revised rule or endpoint presented as current historical configuration',
  );
  check(
    audit.selectFourRiskRevisitEvidence(linked, differentId, 4568).isEmpty &&
        audit
            .selectFourRiskRevisitEvidence(linked, differentHost, 4568)
            .isEmpty,
    'other source identity or host inherited evidence',
  );
}

void checkTampering(Fixture f) {
  void rejected(void Function(Map) change, String reason) {
    final changed = jsonDecode(jsonEncode(f.evidence)) as Map;
    change(changed);
    var caught = false;
    try {
      f.load(value: changed);
    } on FormatException {
      caught = true;
    }
    check(caught, reason);
  }

  rejected(
    (e) => e['sources'][0]['source_id'] = '0' * 64,
    'changed ID accepted',
  );
  rejected(
    (e) => e['sources'][1]['record_index'] = 0,
    'changed index accepted',
  );
  rejected(
    (e) => e['sources'][2]['endpoint_host'] = 'other.example',
    'changed host accepted',
  );
  rejected(
    (e) => e['provenance']['sampling_ledger']['sha256'] = '0' * 64,
    'changed first historical ledger accepted',
  );
  rejected(
    (e) => e['provenance']['summary_ledger']['matching_git_commit'] = '0' * 40,
    'changed second historical ledger accepted',
  );
  rejected(
    (e) => e['observations'][0]['http_status'] = 200,
    'changed redirect status accepted',
  );
  rejected(
    (e) => e['observations'].removeLast(),
    'omitted chapter observation accepted',
  );
  rejected(
    (e) =>
        e['interpretation']['actual_legado_engine_or_webview_executed'] = true,
    'invented application execution accepted',
  );
  rejected(
    (e) => e['observations'].last['body'] = 'private body',
    'private body accepted',
  );
  final modifiedRows = [...f.rows];
  modifiedRows[36] = {...modifiedRows[36] as Map, 'bookSourceName': 'changed'};
  var caught = false;
  try {
    f.load(records: modifiedRows);
  } on FormatException {
    caught = true;
  }
  check(caught, 'modified archive record accepted');
  for (final key in [
    _archive,
    _inventory,
    _amsi,
    'docs/implementation/${audit.fourRiskEvidenceFile}',
  ]) {
    caught = false;
    try {
      f.load(digests: {...f.hashes, key: '0' * 64});
    } on FormatException {
      caught = true;
    }
    check(caught, 'modified input digest accepted: $key');
  }
  final changedAmsi = jsonDecode(jsonEncode(f.amsi)) as Map;
  (changedAmsi['results'] as List).removeLast();
  caught = false;
  try {
    f.load(amsiValue: changedAmsi);
  } on FormatException {
    caught = true;
  }
  check(caught, 'modified AMSI parsed evidence accepted');
}

void checkSnapshotIsolation(
  Fixture f,
  audit.FourRiskRevisitLedgerEvidence linked,
) {
  final first = linkedRow(f, linked, 4568);
  (first['http_observations'] as List).clear();
  (first['application_reading_chain'] as Map)['legado_engine_executed'] = true;
  final again = linkedRow(f, linked, 4568);
  check(
    (again['http_observations'] as List).length == 7 &&
        (again['application_reading_chain'] as Map)['legado_engine_executed'] ==
            false,
    'caller mutation changed internally retained observations',
  );
}

void main() {
  final fixture = Fixture();
  final linked = fixture.load();
  checkSources(fixture, linked);
  checkRecordedFacts(fixture, linked);
  checkVariants(fixture, linked);
  checkTampering(fixture);
  checkSnapshotIsolation(fixture, linked);
  stdout.writeln(
    'four-source selected evidence association offline checks passed',
  );
}
