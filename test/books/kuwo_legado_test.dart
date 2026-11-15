import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/data/legado/kuwo_discovery.dart';
import 'package:zero_player/features/books/data/legado/legado_worker.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/kuwo_legacy_source_fix.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List records;
  setUpAll(() async {
    final bytes = await File(
      'assets/catalogs/books/legado/catalog.json.bz2',
    ).readAsBytes();
    records =
        (jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(bytes)))
                as Map)['records']
            as List;
  });

  for (final index in [3462, 4136]) {
    test(
      'bundled and persisted Kuwo variant $index gets bounded discovery and working chapter template',
      () {
        final source = parseBookSourceRecord(records[index]);
        expect(isKuwoAuditedDiscovery(source), isTrue);
        expect(source.legado!.categories.single.address, kuwoCategoryEndpoint);
        expect(
          source.legado!.rules['chapterUrl'],
          r'https://appi.kuwo.cn/novels/api/book/{{$.book_id}}/chapters/{{$.chapter_id}}',
        );
        final previous = _oldVersion(source, records[index] as Map);
        final restored = BookSource.fromJson(previous);
        expect(restored.id, source.id);
        expect(isKuwoAuditedDiscovery(restored), isTrue);
        expect(
          restored.legado!.rules['chapterUrl'],
          source.legado!.rules['chapterUrl'],
        );

        final legacy = Map.of(previous['legado'] as Map);
        legacy['explore'] = [
          '${(records[index] as Map)['exploreUrl']}\n// user change',
        ];
        final custom = BookSource.fromJson({...previous, 'legado': legacy});
        expect(isKuwoAuditedDiscovery(custom), isFalse);
        expect(
          custom.legado!.rules['chapterUrl'],
          (records[index] as Map)['ruleToc']['chapterUrl'],
        );
      },
    );
  }

  test('category JSON accepts only reviewed groups, IDs and names', () {
    final categories = parseKuwoCategories(
      jsonEncode({
        'code': 200,
        'data': [
          {
            'freetype': 1,
            'categories': [
              {'category_id': 20001, 'category_name': '玄幻'},
            ],
          },
          {
            'freetype': 2,
            'categories': [
              {'category_id': 30013, 'category_name': '古代言情'},
            ],
          },
          {
            'freetype': 3,
            'categories': [
              {'category_id': 1, 'category_name': 'ignored'},
            ],
          },
        ],
      }),
    );
    expect(categories.map((item) => item.title), ['玄幻', '古代言情']);
    expect(categories.map((item) => item.group), ['男生', '女生']);
    for (final category in categories) {
      final uri = Uri.parse(category.address.replaceAll('{{page}}', '1'));
      expect(uri.scheme, 'https');
      expect(uri.host, 'appi.kuwo.cn');
      expect(category.paginated, isTrue);
    }
    final bad = [
      'callback({"code":200,"data":[]})',
      jsonEncode({
        'code': 200,
        'data': [
          {'freetype': 4, 'categories': []},
        ],
      }),
      jsonEncode({
        'code': 200,
        'data': [
          {
            'freetype': 1,
            'categories': [
              {'category_id': 99999, 'category_name': '未审核'},
            ],
          },
          {
            'freetype': 2,
            'categories': [
              {'category_id': 30013, 'category_name': '古代言情'},
            ],
          },
        ],
      }),
      jsonEncode({
        'code': 200,
        'data': [
          {
            'freetype': 1,
            'categories': [
              {'category_id': '20001', 'category_name': '玄幻'},
            ],
          },
          {
            'freetype': 2,
            'categories': [
              {'category_id': 30013, 'category_name': '古代言情'},
            ],
          },
        ],
      }),
      jsonEncode({
        'code': 200,
        'data': [
          {
            'freetype': 1,
            'categories': [
              {'category_id': 20001, 'category_name': '变更名称'},
            ],
          },
          {
            'freetype': 2,
            'categories': [
              {'category_id': 30013, 'category_name': '古代言情'},
            ],
          },
        ],
      }),
      ' ' * (512 * 1024 + 1),
    ];
    for (final input in bad) {
      expect(() => parseKuwoCategories(input), throwsFormatException);
    }
  });

  test(
    'declarative Kuwo rows resolve same-origin book, catalog and chapter',
    () async {
      final source = parseBookSourceRecord(records[3462]);
      final bookPage = await runLegadoJob(
        LegadoJob(
          source,
          source.endpoint.resolve('/novels/api/book/search'),
          LegadoOperation.books,
          input: jsonEncode({
            'data': [
              {'book_id': '123', 'title': '示例书', 'author_name': '作者'},
            ],
          }),
        ),
        CancellationToken(),
      );
      final book = bookPage.books.single;
      expect(book.uri.toString(), 'https://appi.kuwo.cn/novels/api/book/123');
      final details = jsonEncode({
        'data': {'book_id': '123', 'title': '示例书', 'author_name': '作者'},
      });
      final tocPage = await runLegadoJob(
        LegadoJob(
          source,
          book.uri,
          LegadoOperation.toc,
          input: details,
          book: book,
        ),
        CancellationToken(),
      );
      expect(
        tocPage.links.single,
        contains('/novels/api/book/123/chapters?paging=0'),
      );
      final chapterPage = await runLegadoJob(
        LegadoJob(
          source,
          Uri.parse(
            'https://appi.kuwo.cn/novels/api/book/123/chapters?paging=0',
          ),
          LegadoOperation.toc,
          page: 2,
          book: book,
          input: jsonEncode({
            'data': [
              {'book_id': '123', 'chapter_id': '456', 'chapter_title': '第一章'},
            ],
          }),
        ),
        CancellationToken(),
      );
      final chapter = chapterPage.chapters.single;
      expect(
        chapter.uri.toString(),
        'https://appi.kuwo.cn/novels/api/book/123/chapters/456',
      );
      final body = await runLegadoJob(
        LegadoJob(
          source,
          chapter.uri,
          LegadoOperation.content,
          input: jsonEncode({
            'data': {'content': '测试正文'},
          }),
          book: book,
          chapter: chapter,
        ),
        CancellationToken(),
      );
      expect(body.content, '测试正文');
      expect(
        () => source.requestTarget(Uri.parse('https://other.example/')),
        throwsFormatException,
      );
    },
  );
}

Map _oldVersion(BookSource source, Map raw) => {
  ...source.toJson(),
  'legado': {
    ...source.legado!.toJson(),
    'explore': [raw['exploreUrl']],
    'rules': {
      ...source.legado!.rules,
      'chapterUrl': (raw['ruleToc'] as Map)['chapterUrl'],
    },
  },
};
