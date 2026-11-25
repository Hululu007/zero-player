import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/features/publications/data/publication_haodoo_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/data/publication_rule_examples.dart';
import 'package:zero_player/features/publications/data/publication_sources.dart';
import 'package:zero_player/features/publications/data/publication_treasure_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_wikisource_catalogue.dart';
import 'package:zero_player/features/publications/domain/publication.dart';
import 'package:zero_player/features/publications/data/publication_open_textbooks_catalogue.dart';

import '../../test_support/publication_catalogue_fixture.dart';

void _openTextbooksTest() {
  test('Open Textbook Library binds free editions to their declared files', () {
    final body = jsonEncode({
      'links': {'total_pages': 2},
      'data': [
        {
          'id': 19,
          'title': 'Open Course',
          'isbn13': '9781491939369',
          'license': 'Attribution',
          'url': 'https://open.umn.edu/opentextbooks/textbooks/open-course',
          'formats': [
            {
              'type': 'PDF',
              'url': 'https://publisher.example/course.pdf',
              'price': {'cents': 0},
            },
            {
              'type': 'eBook',
              'url': 'https://publisher.example/access',
              'price': {'cents': 0},
            },
            {
              'type': 'eBook',
              'url': 'https://publisher.example/paid.epub',
              'price': {'cents': 899},
            },
          ],
        },
      ],
    });
    final result = parseOpenTextbooksPage(body, isbn: '9781491939369');
    expect(result.totalPages, 2);
    final book = result.books.single;
    expect(book.candidates.single.format, PublicationFormat.pdf);
    expect(book.resources.single.link.path, '/access');
    expect(parseOpenTextbooksPage(body, isbn: '9781491929568').books, isEmpty);
  });
}

void main() {
  _openTextbooksTest();

  test('Wikisource binds the licensed EPUB to its own versioned work page', () {
    final books = parseWikisourceCatalogue(
      _feed([
        _wikiEntry('Book_%281912%29'),
        _wikiEntry('Book_%281918%29'),
        _wikiEntry('Book_%281912%29'),
        _wikiEntry('Different_work', exportTitle: 'Book_%281912%29'),
        _wikiEntry('Unlicensed_work', rights: ''),
        _wikiEntry('Other_host', exportHost: 'example.org'),
        _wikiEntry('Repeated_parameter', extraQuery: '&amp;page=Other_book'),
      ]),
    );
    expect(books.length, 2);
    expect(books.map((book) => book.id).toSet(), hasLength(2));
    expect(books.first.matches('Example Author'), isTrue);
    expect(books.first.edition, '1912');
    expect(books.first.candidates.single.format, PublicationFormat.epub);
    expect(
      books.first.candidates.single.link.queryParameters['page'],
      'Book_(1912)',
    );
    expect(
      () => parseWikisourceCatalogue('<!DOCTYPE feed>${_feed([])}'),
      throwsA(isA<PublicationFailure>()),
    );
  });

  test(
    'Wikisource keyword search includes works outside the export catalogue',
    () async {
      await withPublicationCatalogue(
        (fixture) async {
          final transport = MediaHttpClient();
          try {
            final catalog = WikisourceCatalogue(
              PublicationHttp(transport, authorize: (_) {}),
            );
            final books = await catalog.search(
              'Reference work',
              CancellationToken(),
              maxPages: 1,
              allowed: (_) => true,
            );
            expect(books.single.page?.path, '/wiki/Reference_work');
            expect(books.single.candidates, isEmpty);
            expect(
              fixture.requests.single.queryParameters['srsearch'],
              'Reference work',
            );
          } finally {
            transport.close();
          }
        },
        host: 'en.wikisource.org',
        respond: (request) async {
          expect(request.uri.path, '/w/api.php');
          request.response.write(
            '{"query":{"search":[{"ns":0,"title":"Reference work"}]}}',
          );
          await request.response.close();
        },
      );
    },
  );

  test('Treasure index exposes a per-title share without persisting it', () {
    final books = parseTreasureCatalogue(
      jsonEncode([
        {
          'title': '示例书',
          'author': '示例作者',
          'category': '文学',
          'language': 'ZH',
          'link': 'https://url89.ctfile.com/f/123-456-abcd12?p=1234',
          'formats': ['epub', 'mobi'],
        },
        {'title': '示例书', 'author': '示例作者', 'category': '重复'},
        {'title': '', 'link': 'https://example.org/book.pdf'},
      ]),
    );
    final book = books.single;
    expect(book.matches('示例作者 文学'), isTrue);
    expect(book.page, treasureCataloguePage.replace(fragment: 'search-input'));
    expect(book.candidates, isEmpty);
    expect(book.resources.single.label, '城通网盘');
    expect(book.resources.single.code, '1234');
    expect(book.resources.single.canListFiles, isFalse);
    expect(jsonEncode(book.toJson()), isNot(contains('ctfile')));
  });

  test(
    'Haodoo requests and uses the cover from the public product list',
    () async {
      await withPublicationCatalogue(
        (fixture) async {
          final transport = MediaHttpClient();
          try {
            final catalogue = HaodooCatalogue(
              PublicationHttp(transport, authorize: (_) {}),
            );
            final results = await catalogue.search(
              '',
              CancellationToken(),
              maxPages: 1,
              allowed: (_) => true,
            );
            expect(
              fixture.requests.single.queryParameters['_fields']?.split(','),
              contains('images'),
            );
            expect(results.single.cover?.host, 'i0.wp.com');
          } finally {
            transport.close();
          }
        },
        host: 'haodoo.org',
        respond: (request) async {
          request.response.write('''
          [{"id":1,"name":"示例書","permalink":"https://haodoo.org/?product=1010491026",
            "images":[{"thumbnail":"https://i0.wp.com/haodoo.org/wp-content/uploads/book.jpg"}]}]
          ''');
          await request.response.close();
        },
      );
    },
  );

  test(
    'public metadata keeps valid same-site records and ignores file links',
    () {
      final mobi = PublicationSource.configure(mobiPublicationRule);
      final haodooRows = parseHaodooCatalogue(
        jsonEncode([
          {
            'id': 1,
            'name': '富貴浮雲',
            'permalink': 'https://haodoo.org/?product=1010491026',
            'epub': 'https://haodoo.org/private/book.epub',
          },
          {
            'id': 2,
            'name': 'Other',
            'permalink': 'https://haodoo.org/?product=1010491026&key=private',
          },
        ]),
      ).books;
      final mobiRows = configuredPublicationRows(mobi, '''
<article class="post"><header><h2><a href="/wenxue/28857.html">
<strong>伊势物语</strong> (新文本译丛)</a></h2></header>
<a href="https://example.org/download.epub">下载</a></article>
''');
      expect(haodooRows.single.page?.queryParameters['product'], '1010491026');
      expect(mobiRows.single.page?.path, '/wenxue/28857.html');
      expect(mobiRows.single.matches('伊势物语'), isTrue);
      expect(
        [...haodooRows, ...mobiRows].expand((row) => row.candidates),
        isEmpty,
      );
    },
  );
}

String _feed(List<String> entries) =>
    '<feed xmlns="http://www.w3.org/2005/Atom" '
    'xmlns:dcterms="http://purl.org/dc/terms/">${entries.join()}</feed>';

String _wikiEntry(
  String title, {
  String? exportTitle,
  String exportHost = 'ws-export.wmcloud.org',
  String rights = 'http://creativecommons.org/licenses/by-sa/3.0',
  String extraQuery = '',
}) =>
    '''
<entry>
  <title>Book</title>
  <id>https://en.wikisource.org/wiki/$title</id>
  <rights>$rights</rights>
  <author><name>Example Author</name></author>
  <dcterms:issued>1912</dcterms:issued>
  <link rel="http://opds-spec.org/acquisition" type="application/epub+zip"
    href="https://$exportHost/?lang=en&amp;format=epub&amp;page=${exportTitle ?? title}$extraQuery"/>
</entry>
''';
