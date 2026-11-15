// Pure Dart regression test; does not run Flutter or contact the network.
import 'dart:io';

import 'package:zero_player/features/books/data/book_import.dart';

import 'audit_blocklistproject_policy.dart' as audit;

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Map<String, Object?> evidenceFor(String id) => {
  'comparison': {
    'categories': {
      'porn': {
        'selected_sources_by_relation': {
          'exact_endpoint': [
            {
              'source_id': id,
              'selected_record_index': 0,
              'source_endpoint_host': 'old.example',
            },
          ],
          'listed_parent_endpoint': [],
          'other_fields_only': [],
        },
      },
    },
  },
};

void main() {
  final original = <String, Object?>{
    'name': 'Source',
    'kind': 'text',
    'format': 'feed',
    'url': 'https://old.example/',
    'sourceKey': 'fixture-stable-key',
    'updatedAt': 1,
  };
  final adultOld = {...original, 'name': '🔞 adult', 'updatedAt': 2};
  final current = {
    ...original,
    'name': 'New source',
    'url': 'https://new.example/',
    'updatedAt': 3,
  };
  final id = parseBookSourceRecord(original).id;
  check(
    parseBookSourceRecord(current).id == id,
    'fixture IDs must be identical',
  );
  final targets = audit.readTargets(evidenceFor(id));
  check(targets.historicalIndices[id] == 0, 'historical index changed');
  check(
    audit.currentExactCategories(targets, id, 'old.example').single == 'porn',
    'the exact old endpoint was lost',
  );
  check(
    audit.currentExactCategories(targets, id, 'new.example').isEmpty,
    'a changed host must not inherit an exact endpoint match',
  );

  final replay = audit.replayImport(
    {
      'packs': [
        {'id': 'one', 'count': 4},
      ],
    },
    {
      'records': [original, adultOld, current],
      'packs': {
        'one': [0, 1, 2, 1],
      },
    },
    targets,
  );
  check(replay.currentIndices[id] == 2, 'the current version index is wrong');
  final source = replay.imported.sources.single;
  check(
    source.endpoint.host == 'new.example',
    'the latest version was not selected',
  );
  check(
    source.adultEvidence,
    'the older same-ID adult label was not preserved',
  );
  check(
    replay.adultVariants[id]!.single['record_index'] == 1,
    'adult evidence must retain the original record index',
  );

  final bad = evidenceFor(id);
  final categories = ((bad['comparison'] as Map)['categories'] as Map);
  final groups =
      ((categories['porn'] as Map)['selected_sources_by_relation'] as Map);
  (groups['other_fields_only'] as List).add({
    'source_id': id,
    'selected_record_index': 2,
    'source_endpoint_host': 'old.example',
  });
  var rejected = false;
  try {
    audit.readTargets(bad);
  } on FormatException {
    rejected = true;
  }
  check(rejected, 'conflicting historical selected indices must be rejected');
  stdout.writeln('4 offline Dart policy checks passed');
}
