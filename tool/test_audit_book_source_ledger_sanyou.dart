// Offline regression for two individually sampled source identities.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_source_risk.dart';
import 'package:zero_player/features/books/domain/sanyou_legacy_quarantine.dart';

import 'book_source_ledger_sanyou.dart' as audit;

const archivePath = 'assets/catalogs/books/legado/catalog.json.bz2';
const manifestPath = 'assets/catalogs/books/legado/manifest.json';
const pilotPath = 'docs/implementation/legado-eight-source-pilot-20261116.json';
const evidencePath = 'docs/implementation/${audit.sanyouEvidenceFile}';

void check(bool value, String reason) {
  if (!value) throw StateError(reason);
}

String hash(List<int> bytes) => sha256.convert(bytes).toString();

final class Fixture {
  Fixture() {
    final archive = File(archivePath).readAsBytesSync();
    final bytes = File(evidencePath).readAsBytesSync();
    evidence = jsonDecode(utf8.decode(bytes)) as Map;
    hashes = {
      archivePath: hash(archive),
      evidencePath: hash(bytes),
      manifestPath: hash(File(manifestPath).readAsBytesSync()),
      pilotPath: hash(File(pilotPath).readAsBytesSync()),
    };
    rows =
        (jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive)))
                as Map)['records']
            as List;
  }
  late final Map evidence;
  late final Map<String, String> hashes;
  late final List rows;
  audit.SanyouLedgerEvidence load({
    Map? value,
    List? records,
    Map<String, String>? digests,
  }) => audit.readSanyouEvidence(
    value ?? evidence,
    digests ?? hashes,
    records ?? rows,
  );
}

void checkSamples(Fixture f, audit.SanyouLedgerEvidence linked) {
  for (final index in [3134, 918]) {
    final source = parseBookSourceRecord(f.rows[index]);
    check(
      unavailableSanyouLegacySource(source),
      'actual archive source did not match its own rule',
    );
    final samples = audit.selectSanyouEvidence(linked, source, index);
    check(
      samples.length == (index == 3134 ? 10 : 8),
      'wrong source observation count',
    );
    check(
      samples.every(
        (r) =>
            r['matches_current_selected_raw_record'] == true &&
            r['matches_current_source_kind'] == true &&
            r['matches_current_source_format'] == true &&
            r['matches_current_source_key'] == true &&
            r['matches_current_full_endpoint'] == true &&
            r['matches_current_normalized_legado_rule'] == true &&
            r['site_security_verified'] == null &&
            r['whole_source_permanent_failure_verified'] == null &&
            r['direct_book_or_cached_work_verified'] == null &&
            r['host_wide_verdict'] == false,
      ),
      'historical sample scope changed',
    );
    final recent = samples.where(
      (r) => r['observation_kind'] == 'bounded_old_entry_html_sample',
    );
    check(
      recent.length == 8 &&
          recent.every(
            (r) =>
                r['http_status'] == 200 &&
                r['old_list_selector_nodes'] == 0 &&
                r['domain_sale_h1_count'] == 2 &&
                r['css_or_rendering_evaluated'] == false,
          ),
      'bounded observations changed',
    );
    final prior = samples.where(
      (r) => r['observation_kind'] == 'earlier_historical_search_parse',
    );
    check(
      prior.length == (index == 3134 ? 2 : 0) &&
          prior.every(
            (r) =>
                r['engine_book_count'] == 0 &&
                r['sale_heading_recorded'] == null,
          ),
      'earlier empty parse gained an invented sale heading',
    );
    check(
      !quarantinedBookSourceId(source.id) &&
          !quarantinedBookHost(source.endpoint.host),
      'orphan or host-wide restriction was introduced',
    );
    if (index == 918) {
      check(
        source.legado!.rules['searchList'] == '.item' &&
            !source.legado!.rules.containsKey('exploreList'),
        'second discovery fallback changed',
      );
    }
  }
}

void checkVariants(Fixture f, audit.SanyouLedgerEvidence linked) {
  for (final index in [3134, 918]) {
    final source = parseBookSourceRecord(f.rows[index]);
    final changed = BookSource.fromJson({
      ...source.toJson(),
      'legado': {...source.legado!.toJson(), 'search': '/different-search'},
    });
    check(
      changed.id == source.id &&
          !unavailableSanyouLegacySource(changed) &&
          audit
              .selectSanyouEvidence(linked, changed, index)
              .every(
                (row) => row['matches_current_normalized_legado_rule'] == false,
              ),
      'same-ID rule change lost',
    );
    final moved = BookSource.fromJson({
      ...source.toJson(),
      'url': 'https://www.3uxiaoshuo.com/new',
    });
    check(
      moved.id == source.id &&
          !unavailableSanyouLegacySource(moved) &&
          audit
              .selectSanyouEvidence(linked, moved, index)
              .every((row) => row['matches_current_full_endpoint'] == false),
      'same-ID endpoint change lost',
    );
    final disabled = BookSource.fromJson({
      ...source.toJson(),
      'defaultEnabled': false,
    });
    check(
      !disabled.defaultEnabled && unavailableSanyouLegacySource(disabled),
      'disabled state changed rule match',
    );
    check(
      audit.selectSanyouEvidence(linked, source, index + 1).isEmpty,
      'wrong raw index inherited evidence',
    );
    final independent = BookSource.fromJson({
      ...source.toJson(),
      'sourceKey': 'another-source',
    });
    check(
      independent.id != source.id &&
          !unavailableSanyouLegacySource(independent) &&
          audit.selectSanyouEvidence(linked, independent, index).isEmpty,
      'same-host new source inherited restriction',
    );
  }
}

void checkTampering(Fixture f) {
  void rejected(void Function(Map) mutate, String message) {
    final changed = jsonDecode(jsonEncode(f.evidence)) as Map;
    mutate(changed);
    var caught = false;
    try {
      f.load(value: changed);
    } on FormatException {
      caught = true;
    }
    check(caught, message);
  }

  for (final key in ['source', 'second_source']) {
    rejected((e) => e[key]['source_id'] = '0' * 64, 'changed ID accepted');
    rejected(
      (e) => e[key]['selected_record_index'] = 0,
      'changed index accepted',
    );
    rejected(
      (e) => e[key]['normalized_legado_sha256'] = '0' * 64,
      'changed old rule accepted',
    );
  }
  rejected(
    (e) => e['observations'][0]['domain_sale_h1_count'] = 0,
    'changed first observation accepted',
  );
  rejected(
    (e) => e['second_observations'].removeLast(),
    'removed second source observation accepted',
  );
  final altered = [...f.rows];
  altered[918] = {...altered[918] as Map, 'bookSourceName': 'changed'};
  var caught = false;
  try {
    f.load(records: altered);
  } on FormatException {
    caught = true;
  }
  check(caught, 'modified archived record accepted');
}

void main() {
  final f = Fixture();
  final evidence = f.load();
  checkSamples(f, evidence);
  checkVariants(f, evidence);
  checkTampering(f);
  stdout.writeln('sanyou two-source association offline checks passed');
}
