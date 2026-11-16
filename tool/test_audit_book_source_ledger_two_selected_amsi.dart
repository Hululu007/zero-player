// Pure Dart offline identity, attribution, privacy and tampering regressions.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';

import 'book_source_ledger_two_selected_amsi.dart' as audit;

const _archive = 'assets/catalogs/books/legado/catalog.json.bz2';
const _inventory = 'docs/implementation/legado-import-inventory-20261115.json';
const _prior = 'docs/implementation/legado-amsi-other-hosts-20261115.json';
const _later =
    'docs/implementation/legado-amsi-template-clusters-20261115.json';
const _evidence = 'docs/implementation/${audit.twoSelectedAmsiFile}';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

String hash(List<int> bytes) => sha256.convert(bytes).toString();
Map copy(Map value) => jsonDecode(jsonEncode(value)) as Map;

final class OfflineOnly extends IOOverrides {
  @override
  File createFile(String path) {
    if (p
        .split(p.normalize(path))
        .any((part) => part.toLowerCase() == 'build')) {
      throw StateError('build must not be an evidence input');
    }
    return super.createFile(path);
  }
}

final class Fixture {
  Fixture() {
    final archive = File(_archive).readAsBytesSync();
    final priorBytes = File(_prior).readAsBytesSync();
    final laterBytes = File(_later).readAsBytesSync();
    final evidenceBytes = File(_evidence).readAsBytesSync();
    hashes = {
      _archive: hash(archive),
      _inventory: hash(File(_inventory).readAsBytesSync()),
      _prior: hash(priorBytes),
      _later: hash(laterBytes),
      _evidence: hash(evidenceBytes),
    };
    prior = jsonDecode(utf8.decode(priorBytes)) as Map;
    later = jsonDecode(utf8.decode(laterBytes)) as Map;
    evidence = jsonDecode(utf8.decode(evidenceBytes)) as Map;
    records =
        (jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive)))
                as Map)['records']
            as List;
  }

  late final Map prior, later, evidence;
  late final List records;
  late final Map<String, String> hashes;

  audit.TwoSelectedAmsiEvidence load({
    Map? value,
    Map? historical,
    Map? followup,
    List? archive,
    Map<String, String>? digests,
  }) => audit.readTwoSelectedAmsiEvidence(
    value ?? evidence,
    historical ?? prior,
    followup ?? later,
    digests ?? hashes,
    archive ?? records,
  );
}

Map row(Fixture fixture, audit.TwoSelectedAmsiEvidence evidence, int index) =>
    audit
        .selectTwoSelectedAmsiEvidence(
          evidence,
          parseBookSourceRecord(fixture.records[index]),
          index,
        )
        .single;

void checkAssociation(Fixture fixture, audit.TwoSelectedAmsiEvidence evidence) {
  for (final index in [4838, 3558]) {
    final source = parseBookSourceRecord(fixture.records[index]);
    final result = row(fixture, evidence, index);
    check(
      result['historical_selected_record_index'] == index &&
          result['matches_current_selected_raw_record'] == true &&
          result['matches_current_source_kind'] == true &&
          result['matches_current_source_format'] == true &&
          result['matches_current_full_endpoint'] == true &&
          result['matches_current_normalized_legado_rule'] == true &&
          result['matches_current_source_configuration'] == true &&
          result['site_security_verified'] == null &&
          result['site_malware_verified'] == null &&
          result['sitewide_adult_verified'] == null &&
          result['whole_source_unavailable_verified'] == null &&
          result['whole_source_readability_verified'] == null &&
          result['redirects_followed'] == false &&
          result['redirect_target_collected'] == false &&
          result['source_or_page_scripts_executed'] == false &&
          result['network_authenticity_verified_offline'] == false &&
          result['same_template_proves_independent_threats'] == false,
      'invalid identity, boundary or unproven conclusion for $index',
    );
    final prior = (result['historical_engine_samples'] as List).cast<Map>();
    check(
      prior.length == 2 &&
          prior.every((row) => row['root_classification'] == 'detected'),
      'historical detections must remain separate',
    );
    check(
      audit.selectTwoSelectedAmsiEvidence(evidence, source, index + 1).isEmpty,
      'another selected record inherited observations',
    );
  }
}

void checkOutcomes(Fixture fixture, audit.TwoSelectedAmsiEvidence evidence) {
  final a = row(fixture, evidence, 4838);
  final home = (a['homepage_observations'] as List).cast<Map>();
  final sample = home[1];
  final inline = (sample['inline_scans'] as List).cast<Map>().single;
  final controls = a['engine_control'] as Map;
  check(
    home.length == 2 &&
        home[0]['http_status'] == 302 &&
        home[0]['failure'] == 'redirect_not_followed' &&
        !home[0].containsKey('location') &&
        sample['http_status'] == 200 &&
        sample['sample_bytes'] == 475 &&
        (sample['amsi'] as Map)['classification'] == 'detected' &&
        inline['sample_bytes'] == 371 &&
        (inline['amsi'] as Map)['classification'] == 'not_detected' &&
        controls['basic_controls_passed'] == true &&
        controls['html_wrapped_test_marker'] == 'not_detected' &&
        controls['inline_wrapped_test_marker'] == 'not_detected' &&
        controls['provider_may_upload_sample'] == true,
    'root, inline, redirect or control scope was changed',
  );
  final b = row(fixture, evidence, 3558);
  final failures = (b['homepage_observations'] as List).cast<Map>();
  check(
    failures.length == 2 &&
        failures.every(
          (item) =>
              item['failure'] == 'tls_error' &&
              !item.containsKey('http_status') &&
              !item.containsKey('amsi'),
        ),
    'TLS failures became an HTTP response or scan',
  );
}

void checkVariants(Fixture fixture, audit.TwoSelectedAmsiEvidence evidence) {
  final source = parseBookSourceRecord(fixture.records[4838]);
  final updated = BookSource.fromJson({
    ...source.toJson(),
    'legado': {...source.legado!.toJson(), 'search': '/other-search'},
  });
  final moved = BookSource.fromJson({
    ...source.toJson(),
    'url': 'https://${source.endpoint.host}/other-entry',
  });
  final differentId = BookSource.fromJson({
    ...source.toJson(),
    'sourceKey': 'other-source',
  });
  final differentHost = BookSource.fromJson({
    ...source.toJson(),
    'url': 'https://other.example/',
  });
  check(
    updated.id == source.id && moved.id == source.id,
    'invalid variant fixture',
  );
  final changed = audit
      .selectTwoSelectedAmsiEvidence(evidence, updated, 4838)
      .single;
  final relocated = audit
      .selectTwoSelectedAmsiEvidence(evidence, moved, 4838)
      .single;
  check(
    changed['matches_current_normalized_legado_rule'] == false &&
        changed['matches_current_source_configuration'] == false &&
        relocated['matches_current_full_endpoint'] == false &&
        relocated['matches_current_source_configuration'] == false,
    'historical observation was mislabeled as a current revision',
  );
  check(
    audit.selectTwoSelectedAmsiEvidence(evidence, differentId, 4838).isEmpty &&
        audit
            .selectTwoSelectedAmsiEvidence(evidence, differentHost, 4838)
            .isEmpty,
    'different ID or host inherited historical evidence',
  );
}

void checkTampering(Fixture fixture) {
  void rejected(void Function(Map) mutate, String message) {
    final candidate = copy(fixture.evidence);
    mutate(candidate);
    var caught = false;
    try {
      fixture.load(value: candidate);
    } on FormatException {
      caught = true;
    }
    check(caught, message);
  }

  rejected(
    (x) => x['sources'][0]['source_id'] = '0' * 64,
    'changed ID accepted',
  );
  rejected(
    (x) => x['sources'][1]['host'] = 'other.example',
    'changed host accepted',
  );
  rejected(
    (x) => x['sources'][1]['selected_record_index'] = 3012,
    'changed index accepted',
  );
  rejected(
    (x) => x['sources'][0]['normalized_legado_sha256'] = '0' * 64,
    'changed rule accepted',
  );
  rejected(
    (x) => x['observations'][1]['http_status'] = 404,
    'invented response accepted',
  );
  rejected(
    (x) => x['observations'][0]['location'] = 'https://example.com/',
    'redirect target accepted',
  );
  rejected(
    (x) => x['observations'][2]['body'] = 'private data',
    'response body accepted',
  );
  rejected(
    (x) => x['control']['html_wrapped_eicar']['classification'] = 'detected',
    'control change accepted',
  );
  rejected(
    (x) => x['interpretation']['current_host_security_verified'] = true,
    'safety verdict accepted',
  );
  for (final path in [_archive, _inventory, _prior, _later, _evidence]) {
    var caught = false;
    try {
      fixture.load(digests: {...fixture.hashes, path: '0' * 64});
    } on FormatException {
      caught = true;
    }
    check(caught, 'altered input hash accepted: $path');
  }
  final alteredRows = [...fixture.records];
  alteredRows[4838] = {
    ...alteredRows[4838] as Map,
    'bookSourceName': 'changed',
  };
  var caught = false;
  try {
    fixture.load(archive: alteredRows);
  } on FormatException {
    caught = true;
  }
  check(caught, 'altered original record accepted');
  final alteredPrior = copy(fixture.prior);
  (alteredPrior['results'] as List).removeLast();
  caught = false;
  try {
    fixture.load(historical: alteredPrior);
  } on FormatException {
    caught = true;
  }
  check(caught, 'altered historical engine evidence accepted');
}

void checkSnapshotIsolation(
  Fixture fixture,
  audit.TwoSelectedAmsiEvidence evidence,
) {
  final original = row(fixture, evidence, 4838);
  (original['homepage_observations'] as List).clear();
  (original['engine_control'] as Map)['basic_controls_passed'] = false;
  final after = row(fixture, evidence, 4838);
  check(
    (after['homepage_observations'] as List).length == 2 &&
        (after['engine_control'] as Map)['basic_controls_passed'] == true,
    'caller mutated retained evidence',
  );
}

void main() => HttpOverrides.runZoned(
  () => IOOverrides.runWithIOOverrides(() {
    final fixture = Fixture();
    final evidence = fixture.load();
    checkAssociation(fixture, evidence);
    checkOutcomes(fixture, evidence);
    checkVariants(fixture, evidence);
    checkTampering(fixture);
    checkSnapshotIsolation(fixture, evidence);
    stdout.writeln(
      'two-source selected evidence association offline checks passed',
    );
  }, OfflineOnly()),
  createHttpClient: (_) => throw StateError('network is forbidden'),
);
