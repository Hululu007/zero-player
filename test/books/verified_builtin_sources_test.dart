import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/document_client.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/features/books/data/book_client.dart';
import 'package:zero_player/features/books/data/book_import.dart';
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
      expect(rows, hasLength(20));
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
      expect(sources.map((source) => source.endpoint).toSet(), hasLength(20));
      expect(sources.map((source) => source.name).toSet(), hasLength(20));
      expect(byName.keys.where((name) => name.startsWith('机核 ·')), isEmpty);

      final comic = sources.singleWhere((source) => source.name == '新人漫画');
      expect(comic.kind, BookKind.comic);
      expect(comic.defaultEnabled, isTrue);
      expect(comic.hasDiscovery && comic.hasSearch, isTrue);
      expect(comic.mediaHosts, {'works.xinmanhua.net'});
      expect(sources.where((source) => source.kind == BookKind.comic), [comic]);

      final portable = parseBookSources(encodeBookSourceRules(sources));
      expect(portable.issues, isEmpty);
      expect(
        portable.sources.map((source) => source.toJson()),
        sources.map((source) => source.toJson()),
      );
      expect(
        sources
            .singleWhere((source) => source.format == BookFormat.ximalaya)
            .jsonCatalog['discover']!
            .read({
              'data': {
                'albums': [1],
              },
            }, 'list'),
        [1],
      );
      expect(
        () => parseBookSources(
          '{"schema":"zero-player/book-source-rules","version":2,"sources":[]}',
        ),
        throwsFormatException,
      );

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

  _portableRuleExecutionTest();
  _ximalayaFeaturedTest();
}

void _ximalayaFeaturedTest() {
  test(
    'Ximalaya discovers across categories and preserves the free filter',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final http = HttpOverrides.runZoned(
        MediaHttpClient.new,
        createHttpClient: (context) => _CatalogFixtureHttp(
          _SystemHttpOverrides().createHttpClient(context),
          server.port,
        ),
      );
      addTearDown(http.close);
      addTearDown(() => server.close(force: true));
      final visited = <String>{};
      server.listen((request) async {
        final id = request.uri.queryParameters['categoryId']!;
        visited.add(id);
        Map<String, Object> album(String key, {bool paid = false}) => {
          'albumId': key,
          'albumTitle': '专辑$key',
          'isPaid': paid,
          'vipType': 0,
          'albumCoverPath': 'group01/cover.jpg',
        };
        request.response.write(
          jsonEncode({
            'ret': 200,
            'data': {
              'total': 60,
              'albums': [album('1'), album(id), album('99', paid: true)],
            },
          }),
        );
        await request.response.close();
      });
      final rows =
          jsonDecode(
                await rootBundle.loadString(
                  'assets/catalogs/books/verified.json',
                ),
              )
              as List;
      final source = BookSource.fromJson(
        rows.cast<Map>().singleWhere((row) => row['format'] == 'ximalaya'),
      );
      final client = BookClient(DocumentClient(http));
      final token = CancellationToken();
      final categories = await client.categories(source, token);
      expect(categories.first.title, '免费精选');
      final page = await client.discover(source, token);
      expect(visited, {'3', '1001', '1002', '6', '9', '12'});
      expect(page.books, hasLength(7));
      expect(page.books.map((book) => book.title), isNot(contains('专辑99')));
      expect(page.next, '2');
      final book = page.books.first;
      expect(
        source.resolve(book.uri, book.cover, media: true).host,
        'imagev2.xmcdn.com',
      );
      visited.clear();
      await client.discover(source, token, category: categories.last);
      expect(visited, {categories.last.address});
    },
  );
}

void _portableRuleExecutionTest() {
  test('exported JSON and HTML mappings run against a local source', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final http = HttpOverrides.runZoned(
      MediaHttpClient.new,
      createHttpClient: (context) => _CatalogFixtureHttp(
        _SystemHttpOverrides().createHttpClient(context),
        server.port,
      ),
    );
    addTearDown(http.close);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.uri.path == '/book/1') {
        request.response.write('<main><a href="/chapter/1">第一章</a></main>');
      } else {
        request.response.write(
          jsonEncode({
            'items': [
              {'name': '示例书', 'href': '/book/1', 'writer': '作者'},
              {'name': '其他站点', 'href': 'https://other.example/book'},
            ],
            'more': '/discover?page=2',
          }),
        );
      }
      await request.response.close();
    });
    const mapping = {
      'list': 'items',
      'title': 'name',
      'url': 'href',
      'author': 'writer',
      'next': 'more',
    };
    final source = BookSource.fromJson({
      'name': '混合规则',
      'kind': 'text',
      'format': 'html',
      'url': 'https://catalog.example',
      'search': '/search?q={key}',
      'discover': '/discover',
      'jsonCatalog': {'search': mapping, 'discover': mapping},
      'rules': {
        'chapters': 'main a',
        'chapterTitle': '@text',
        'chapterUrl': '@href',
        'content': 'article@text',
      },
    });
    final imported = parseBookSources(
      encodeBookSourceRules([source]),
    ).sources.single;
    final client = BookClient(DocumentClient(http));
    final token = CancellationToken();
    final page = await client.discover(imported, token);
    expect(page.books.single.title, '示例书');
    expect(page.next, 'https://catalog.example/discover?page=2');
    final books = await client.books(imported, '示例书', token);
    expect(books.single.author, '作者');
    expect(
      (await client.chapters(imported, books.single, token)).single.title,
      '第一章',
    );
  });
}

final class _SystemHttpOverrides extends HttpOverrides {}

final class _CatalogFixtureHttp implements HttpClient {
  _CatalogFixtureHttp(this.client, this.port);
  final HttpClient client;
  final int port;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) => client.openUrl(
    method,
    uri.replace(scheme: 'http', host: '127.0.0.1', port: port),
  );

  @override
  void close({bool force = false}) => client.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.isSetter ? null : super.noSuchMethod(invocation);
}
