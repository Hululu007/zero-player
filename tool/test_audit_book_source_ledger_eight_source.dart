// Offline association and negative cases; no application or website requests.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';

import 'book_source_ledger_eight_source.dart' as audit;

const archivePath = 'assets/catalogs/books/legado/catalog.json.bz2';
const inventoryPath =
    'docs/implementation/legado-import-inventory-20261115.json';
const indices = [407, 1399, 3134, 4371, 3954, 1056, 3817, 4491];

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

String hash(List<int> bytes) => sha256.convert(bytes).toString();

final class Fixture {
  Fixture() {
    final archive = File(archivePath).readAsBytesSync();
    final evidenceBytes = File(
      'docs/implementation/${audit.eightSourceEvidenceFile}',
    ).readAsBytesSync();
    hashes = {
      archivePath: hash(archive),
      inventoryPath: hash(File(inventoryPath).readAsBytesSync()),
      'docs/implementation/${audit.eightSourceEvidenceFile}': hash(
        evidenceBytes,
      ),
    };
    evidence = jsonDecode(utf8.decode(evidenceBytes)) as Map;
    rows =
        (jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive)))
                as Map)['records']
            as List;
  }
  late final Map evidence;
  late final List rows;
  late final Map<String, String> hashes;

  audit.EightSourceLedgerEvidence load({
    Map? value,
    List? records,
    Map<String, String>? digests,
  }) => audit.readEightSourceEvidence(
    value ?? evidence,
    digests ?? hashes,
    records ?? rows,
  );
}

Map<String, Object?> linkedRow(
  Fixture f,
  audit.EightSourceLedgerEvidence linked,
  int index,
) => audit
    .selectEightSourceEvidence(
      linked,
      parseBookSourceRecord(f.rows[index]),
      index,
    )
    .single;

void checkSources(Fixture f, audit.EightSourceLedgerEvidence linked) {
  var followups = 0;
  for (final index in indices) {
    final source = parseBookSourceRecord(f.rows[index]);
    final row = linkedRow(f, linked, index);
    check(
      row['historical_selected_record_index'] == index &&
          row['matches_current_selected_raw_record'] == true &&
          row['matches_current_source_kind'] == true &&
          row['matches_current_source_format'] == true &&
          row['matches_current_full_endpoint'] == true &&
          row['site_security_verified'] == null &&
          row['full_readability_verified'] == null &&
          row['whole_source_unavailable_verified'] == null &&
          row['current_rule_validity_verified'] == null &&
          row['historical_runtime_fully_reconstructed'] == false &&
          row['followup_risk_policy_git_commit'] == null,
      'incorrect association or conclusions for $index',
    );
    final samples = row['samples'] as Map;
    if (samples.containsKey('followup')) followups++;
    final step = (((samples['initial'] as Map)['steps']) as List).first as Map;
    check(
      step['stage'] == 'search' && step['observed_at_utc'] != null,
      'missing initial search',
    );
    check(
      audit.selectEightSourceEvidence(linked, source, index + 1).isEmpty,
      'different selected index inherited evidence',
    );
  }
  check(followups == 4, 'four independent follow-ups expected');
  final failed = linkedRow(f, linked, 407)['samples'] as Map;
  check(
    ((((failed['initial'] as Map)['steps'] as List).first) as Map)['status'] ==
        404,
    'historical 404 changed',
  );
  final discoveries = ((failed['followup'] as Map)['steps'] as List)
      .cast<Map>();
  check(
    discoveries.length == 2 &&
        discoveries.every(
          (step) => step['stage'] == 'discover' && step['status'] == 404,
        ),
    'two separate discovery observations changed',
  );
  final emptySearch =
      ((linkedRow(f, linked, 1399)['samples'] as Map)['initial']
              as Map)['steps']
          as List;
  check(
    (emptySearch.single as Map)['status'] == 200 &&
        (emptySearch.single as Map)['sample_bytes'] == 53 &&
        (emptySearch.single as Map)['book_count'] == 0,
    'bounded empty search observation changed',
  );
  for (final index in [3954, 1056]) {
    final sample =
        ((linkedRow(f, linked, index)['samples'] as Map)['followup'] as Map);
    final steps = (sample['steps'] as List).cast<Map>();
    final content = steps.where((step) => step['stage'] == 'content').toList();
    check(
      sample['outcome'] == 'one_content_sample' &&
          content.length == 1 &&
          content.single['status'] == 200 &&
          content.single['content_characters'] == (index == 3954 ? 3025 : 2001),
      'single sampled chapter changed',
    );
  }
}

void checkVariants(Fixture f, audit.EightSourceLedgerEvidence linked) {
  final source = parseBookSourceRecord(f.rows[407]);
  check(
    audit
            .selectEightSourceEvidence(linked, source, 407)
            .single['matches_current_normalized_legado_rule'] ==
        true,
    'unchanged selected rule did not match its historical fingerprint',
  );
  final changedRule = BookSource.fromJson({
    ...source.toJson(),
    'legado': {...source.legado!.toJson(), 'search': '/different-search'},
  });
  check(
    changedRule.id == source.id &&
        audit
                .selectEightSourceEvidence(linked, changedRule, 407)
                .single['matches_current_normalized_legado_rule'] ==
            false,
    'same-ID edited rule was treated as historical',
  );
  final moved = BookSource.fromJson({
    ...source.toJson(),
    'url': 'https://m.dmxso.com/changed',
  });
  check(
    moved.id == source.id &&
        audit
                .selectEightSourceEvidence(linked, moved, 407)
                .single['matches_current_full_endpoint'] ==
            false,
    'same-ID edited endpoint was treated as historical',
  );
  final other = BookSource.fromJson({...source.toJson(), 'sourceKey': 'other'});
  final host = BookSource.fromJson({
    ...source.toJson(),
    'url': 'https://other.example/',
  });
  check(
    audit.selectEightSourceEvidence(linked, other, 407).isEmpty &&
        audit.selectEightSourceEvidence(linked, host, 407).isEmpty,
    'other source or host inherited evidence',
  );
}

void checkTampering(Fixture f) {
  void rejected(void Function(Map) change, String reason) {
    final copy = jsonDecode(jsonEncode(f.evidence)) as Map;
    change(copy);
    var caught = false;
    try {
      f.load(value: copy);
    } on FormatException {
      caught = true;
    }
    check(caught, reason);
  }

  rejected(
    (e) => e['sources'][0]['id'] = '0' * 64,
    'edited source ID accepted',
  );
  rejected((e) => e['sources'][0]['index'] = 0, 'edited index accepted');
  rejected(
    (e) => e['sources'][0]['historical_legado_canonical_sha256'] = '0' * 64,
    'edited historical rule accepted',
  );
  rejected(
    (e) =>
        e['initial']['observations'][0]['steps'][0]['observation']['http_status'] =
            200,
    'edited 404 accepted',
  );
  rejected(
    (e) =>
        e['sampled_source_snapshots']['later']['full_runtime_snapshot_reconstructable'] =
            true,
    'edited runtime claim accepted',
  );
  rejected(
    (e) => e['followups'][0]['steps'].removeLast(),
    'removed sample accepted',
  );
  final altered = [...f.rows];
  altered[407] = {...altered[407] as Map, 'bookSourceName': 'changed'};
  var rejectedRaw = false;
  try {
    f.load(records: altered);
  } on FormatException {
    rejectedRaw = true;
  }
  check(rejectedRaw, 'modified archive record accepted');
  final badHashes = {
    ...f.hashes,
    'docs/implementation/${audit.eightSourceEvidenceFile}': '0' * 64,
  };
  var rejectedDigest = false;
  try {
    f.load(digests: badHashes);
  } on FormatException {
    rejectedDigest = true;
  }
  check(rejectedDigest, 'modified evidence digest accepted');
}

void main() {
  final f = Fixture();
  final linked = f.load();
  checkSources(f, linked);
  checkVariants(f, linked);
  checkTampering(f);
  stdout.writeln(
    'eight-source selected evidence association offline checks passed',
  );
}
