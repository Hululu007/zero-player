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
    'reviewed normalized rules are blocked without blocking safe variants',
    () async {
      final compressed = await File(
        'assets/catalogs/books/legado/catalog.json.bz2',
      ).readAsBytes();
      final decoded =
          jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(compressed)))
              as Map;
      final records = decoded['records'] as List;
      const reviewed = [
        12,
        190,
        192,
        1066,
        1227,
        1794,
        2176,
        3067,
        3322,
        3926,
        3973,
        4813,
        4826,
      ];
      for (final index in reviewed) {
        final source = parseBookSourceRecord(records[index]);
        expect(knownUntrustedBookRule(source), isTrue, reason: 'record $index');
        expect(quarantinedBookSource(source), isTrue, reason: 'record $index');
        expect(
          quarantinedBookSourceId(source.id),
          isTrue,
          reason: 'record $index',
        );
        final legado = source.legado!.toJson();
        final cleaned = BookSource.fromJson({
          ...source.toJson(),
          'legado': {
            ...legado,
            'rules': {'content': 'p@text', 'searchList': '.book'},
          },
        });
        expect(cleaned.id, source.id);
        // Includes a retained dangerous comment with no executable caller.
        expect(
          knownUntrustedBookRule(cleaned),
          isFalse,
          reason: 'record $index',
        );
      }
      for (final index in [12, 1794, 4813]) {
        final source = parseBookSourceRecord(records[index]);
        final sanitized = BookSource.fromJson({
          ...source.toJson(),
          'legado': {...source.legado!.toJson(), 'comment': '普通说明'},
        });
        expect(sanitized.id, source.id);
        expect(
          knownUntrustedBookRule(sanitized),
          isFalse,
          reason: 'record $index',
        );
      }
      // JSONP / object expression candidates are not in the confirmed set.
      final dataExpression = parseBookSourceRecord(records[17]);
      expect(knownUntrustedBookRule(dataExpression), isFalse);
      final oldVariant = parseBookSourceRecord(records[535]);
      final selectedVariant = parseBookSourceRecord(records[1798]);
      expect(oldVariant.id, selectedVariant.id);
      expect(quarantinedBookSource(oldVariant), isTrue);
      expect(quarantinedBookSource(selectedVariant), isFalse);
    },
  );
}
