import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/books/domain/book.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'built-in sources keep audited defaults and new entries parse',
    () async {
      final rows =
          jsonDecode(
                await rootBundle.loadString(
                  'assets/catalogs/books/verified.json',
                ),
              )
              as List;
      expect(rows, hasLength(21));
      final byName = {
        for (final row in rows.cast<Map>()) row['name'] as String: row,
      };

      for (final name in ['台灣小說網', 'UU看书', '三叠书阁']) {
        expect(byName[name]!['defaultEnabled'], isFalse, reason: name);
      }
      final twkan = byName['台灣小說網']!;
      expect(twkan['url'], startsWith('https://www.twkan.cc'));
      expect(twkan.containsKey('legado'), isFalse);

      final sources = rows.cast<Map>().map(BookSource.fromJson).toList();
      expect(sources.map((source) => source.endpoint).toSet(), hasLength(21));
      expect(sources.map((source) => source.name).toSet(), hasLength(21));

      for (final name in ['书邦 · 双语小说', '古龙武侠（BBS）']) {
        final source = sources.firstWhere((source) => source.name == name);
        expect(source.defaultEnabled, isTrue, reason: name);
        expect(source.legado, isNotNull, reason: name);
        expect(source.legado!.search, contains('{{key}}'), reason: name);
        expect(source.legado!.rules['chapters'], isNotEmpty, reason: name);
        expect(source.legado!.rules['content'], isNotEmpty, reason: name);
      }
      expect(
        sources
            .firstWhere((source) => source.name == '书邦 · 双语小说')
            .endpoint
            .toString(),
        'https://www.shubang.net',
      );
      expect(
        sources
            .firstWhere((source) => source.name == '古龙武侠（BBS）')
            .endpoint
            .toString(),
        'https://m.gulongbbs.com',
      );
    },
  );
}
