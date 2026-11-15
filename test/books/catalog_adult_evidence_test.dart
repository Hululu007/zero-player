import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/books/data/aoaostar_book_catalog.dart';
import 'package:zero_player/features/books/domain/book_source_risk.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'every audited adult-labelled source remains classified after deduplication',
    () async {
      final evidence =
          jsonDecode(
                await File(
                  'docs/implementation/legado-adult-label-evidence-20261115.json',
                ).readAsString(),
              )
              as Map;
      final catalog = await AoaoStarBookCatalog.load();
      expect(catalog.revision, evidence['archive_sha256']);
      final parsed = await catalog.read();
      final sources = {for (final source in parsed.sources) source.id: source};
      final audited = evidence['sources'] as List;
      expect(audited, hasLength(76));
      for (final row in audited.cast<Map>()) {
        final source = sources[row['id']];
        expect(source, isNotNull, reason: 'missing audited ID ${row['id']}');
        expect(
          adultBookSource(source!),
          isTrue,
          reason: 'adult evidence lost for ID ${row['id']}',
        );
      }
    },
  );
}
