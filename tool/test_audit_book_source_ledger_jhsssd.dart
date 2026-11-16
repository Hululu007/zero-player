import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';

import 'book_source_ledger_jhsssd.dart' as audit;

void check(bool value, String reason) {
  if (!value) throw StateError(reason);
}

String hash(List<int> bytes) => sha256.convert(bytes).toString();

final class Fixture {
  Fixture()
    : archive = File(
        'assets/catalogs/books/legado/catalog.json.bz2',
      ).readAsBytesSync(),
      evidenceBytes = File(
        'docs/implementation/${audit.jhsssdEvidenceFile}',
      ).readAsBytesSync() {
    evidence = jsonDecode(utf8.decode(evidenceBytes)) as Map;
    rows =
        (jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive)))
                as Map)['records']
            as List;
  }

  final List<int> archive, evidenceBytes;
  late final Map evidence;
  late final List rows;

  audit.JhsssdLedgerEvidence load({
    Map? value,
    List? rawRecords,
    Map<String, String>? hashes,
  }) => audit.readJhsssdEvidence(
    value ?? evidence,
    hashes ??
        {
          'assets/catalogs/books/legado/catalog.json.bz2': hash(archive),
          'docs/implementation/${audit.jhsssdEvidenceFile}': hash(
            evidenceBytes,
          ),
        },
    rawRecords ?? rows,
  );
}

void checkSample(Fixture fixture, audit.JhsssdLedgerEvidence linked) {
  final source = parseBookSourceRecord(fixture.rows[4651]);
  final row = audit.selectJhsssdEvidence(linked, source, 4651).single;
  check(
    row['matches_current_selected_raw_record'] == true &&
        row['matches_current_source_kind'] == true &&
        row['matches_current_source_format'] == true &&
        row['matches_current_full_endpoint'] == true &&
        row['matches_current_normalized_legado_rule'] == false &&
        row['site_security_verified'] == null &&
        row['full_readability_verified'] == null &&
        row['whole_source_unavailable_verified'] == null &&
        row['current_rule_validity_verified'] == null,
    'repaired rule or unknown conclusions not preserved',
  );
  final samples = row['samples'] as Map;
  final works = (samples['works'] as List).cast<Map>();
  check(works.length == 2, 'two bounded works expected');
  for (final work in works) {
    final old = work['detail_before'] as Map;
    final candidate = work['detail_candidate'] as Map;
    check(
      old['status'] == 200 &&
          old['sample_sha256'] == candidate['sample_sha256'] &&
          old['detail_category_length'] == 0 &&
          candidate['detail_category_length'] == 4 &&
          candidate['category_matches_og'] == true,
      'original and repaired category sample mismatch',
    );
  }
}

void checkVariants(Fixture fixture, audit.JhsssdLedgerEvidence linked) {
  final source = parseBookSourceRecord(fixture.rows[4651]);
  final oldRules = Map<String, String>.of(source.legado!.rules)
    ..remove('infoCategory');
  final old = BookSource.fromJson({
    ...source.toJson(),
    'discoveryCategories': [
      {'title': '自定义', 'url': '/custom'},
    ],
    'legado': {...source.legado!.toJson(), 'rules': oldRules},
  });
  check(
    audit
            .selectJhsssdEvidence(linked, old, 4651)
            .single['matches_current_normalized_legado_rule'] ==
        true,
    'exact old rule must match',
  );
  final changed = BookSource.fromJson({
    ...old.toJson(),
    'legado': {...old.legado!.toJson(), 'search': '/different-search'},
  });
  check(
    changed.id == source.id &&
        audit
                .selectJhsssdEvidence(linked, changed, 4651)
                .single['matches_current_normalized_legado_rule'] ==
            false,
    'same-ID custom rule must not match',
  );
  final moved = BookSource.fromJson({
    ...source.toJson(),
    'url': 'https://m.jhsssd.com/changed',
  });
  check(
    moved.id == source.id &&
        audit
                .selectJhsssdEvidence(linked, moved, 4651)
                .single['matches_current_full_endpoint'] ==
            false,
    'same-ID changed endpoint must be identified',
  );
  check(
    audit
            .selectJhsssdEvidence(linked, source, 4650)
            .single['matches_current_selected_raw_record'] ==
        false,
    'different raw index must be identified',
  );
  final other = BookSource.fromJson({...source.toJson(), 'sourceKey': 'other'});
  check(
    audit.selectJhsssdEvidence(linked, other, 4651).isEmpty,
    'other ID inherited evidence',
  );
  final otherHost = BookSource.fromJson({
    ...source.toJson(),
    'url': 'https://other.example/',
  });
  check(
    audit.selectJhsssdEvidence(linked, otherHost, 4651).isEmpty,
    'other host inherited evidence',
  );
}

void checkTampering(Fixture fixture) {
  void rejects(void Function(Map) mutate, String reason) {
    final copy = jsonDecode(jsonEncode(fixture.evidence)) as Map;
    mutate(copy);
    var rejected = false;
    try {
      fixture.load(value: copy);
    } on FormatException {
      rejected = true;
    }
    check(rejected, reason);
  }

  rejects((e) => e['source']['id'] = '0' * 64, 'changed ID accepted');
  rejects(
    (e) => e['source']['endpoint_sha256'] = '0' * 64,
    'changed endpoint accepted',
  );
  rejects(
    (e) => e['source']['old_legado_canonical_sha256'] = '0' * 64,
    'changed rule accepted',
  );
  rejects(
    (e) =>
        e['observations']['candidate_two_works']['works'][0]['detail']['analysis']['category_diag']['engine_matches_og'] =
            false,
    'changed category result accepted',
  );
  final alteredRows = [...fixture.rows];
  alteredRows[4651] = {
    ...alteredRows[4651] as Map,
    'bookSourceName': 'changed',
  };
  var rejected = false;
  try {
    fixture.load(rawRecords: alteredRows);
  } on FormatException {
    rejected = true;
  }
  check(rejected, 'changed raw record accepted');
}

void main() {
  final fixture = Fixture();
  final linked = fixture.load();
  checkSample(fixture, linked);
  checkVariants(fixture, linked);
  checkTampering(fixture);
  stdout.writeln('jhsssd source evidence association offline checks passed');
}
