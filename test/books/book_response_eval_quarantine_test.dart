import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_source_risk.dart';
import 'package:zero_player/features/books/domain/known_untrusted_book_rules.dart';

void main() {
  test(
    'each reviewed response-to-code rule is quarantined by exact field',
    () async {
      final raw = await File(
        'assets/catalogs/books/legado/catalog.json.bz2',
      ).readAsBytes();
      final records =
          (jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(raw)))
                  as Map)['records']
              as List;
      final evidence =
          jsonDecode(
                await File(
                  'docs/implementation/legado-response-eval-normalized-20261115.json',
                ).readAsString(),
              )
              as Map;
      final profiles = evidence['profiles'] as List;
      expect(profiles, hasLength(34));
      for (final profile in profiles.cast<Map>()) {
        final source = parseBookSourceRecord(
          records[profile['selected_record_index']],
        );
        expect(source.id, profile['source_id']);
        expect(knownUntrustedBookRule(source), isTrue, reason: source.name);
        expect(quarantinedBookSourceId(source.id), isTrue, reason: source.name);
        final original = source.legado!.rules;
        final keys = <String>{
          for (final entry in profile['selected_rule_evidence'] as List)
            (entry['path'] as String).split('.').last,
        };
        for (final key in keys) {
          final isolated = _withRules(source, {key: original[key]!});
          expect(
            knownUntrustedBookRule(isolated),
            isTrue,
            reason: '${source.name} $key',
          );
        }
        final remaining = Map<String, String>.of(original)
          ..removeWhere((key, _) => keys.contains(key));
        final corrected = _withRules(source, remaining);
        expect(corrected.id, source.id);
        expect(knownUntrustedBookRule(corrected), isFalse, reason: source.name);
      }
    },
  );
}

BookSource _withRules(BookSource source, Map<String, String> rules) =>
    BookSource.fromJson({
      ...source.toJson(),
      'legado': {...source.legado!.toJson(), 'rules': rules},
    });
