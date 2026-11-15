import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/persistence/installation_metadata.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/legado_source.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('dynamic categories retain denied addresses after expansion', (
    tester,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final root = await Directory.systemTemp.createTemp('dynamic-categories-');
    final requests = <(String, Uri)>[];
    var nextLink = '/normal/2?page=2';
    server.listen((request) async {
      if (request.uri.path == '/adult') {
        request.response.headers.contentType = ContentType.json;
        request.response.write('[{"title":"普通","url":"/normal"}]');
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType.html;
      request.response.write('''
        <div class="bookbox"><div class="bookname">
          <a href="/book/1">星际普通</a></div><span class="kind">玄幻</span></div>
        ${request.uri.queryParameters['page'] == '2' ? '' : '<div class="pages"><a class="next" href="$nextLink">下一页</a></div>'}
      ''');
      await request.response.close();
    });
    try {
      await HttpOverrides.runZoned(
        () async {
          final services = AppServices.scoped(root, AppDatabase.memory());
          try {
            await services.db.write(
              'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
              [installationAccessKey, upgradedInstallationAccess],
            );
            await services.settings.load();
            await services.supervision.load();
            expect(services.contentPolicy.filterAdult, isTrue);
            final repository = services.books;
            for (final entry in await repository.sources(
              BookKind.text,
              enabledOnly: true,
            )) {
              await repository.saveSource(entry.source, {'enabled': false});
            }
            final installedIds = <String>{};
            Future<void> install(BookSource item) async {
              expect(installedIds.add(item.id), isTrue, reason: item.name);
              final imported = await repository.importSources([item]);
              expect(imported.added, 1, reason: item.name);
              expect(imported.updated, 0, reason: item.name);
              expect(imported.duplicates, 0, reason: item.name);
              expect(imported.skipped, 0, reason: item.name);
              final saved = await repository.sourceEntry(item.kind, item.id);
              expect(saved, isNotNull, reason: item.name);
              expect(saved!.source.endpoint, item.endpoint, reason: item.name);
              await repository.saveSource(item, {'enabled': true});
              expect(
                (await repository.sourceEntry(item.kind, item.id))!.enabled,
                isTrue,
                reason: item.name,
              );
            }

            final source = BookSource.fromJson({
              'name': '动态分类测试',
              'url': 'https://dynamic.example/',
              'kind': 'text',
              'format': 'html',
              'legado': {
                'explore': [
                  {
                    'title': '',
                    'url':
                        '@js:JSON.stringify(['
                        '{title:"肉文",url:"/normal/2"},'
                        '{title:"普通别名",url:"/normal/2"},'
                        '{title:"玄幻",url:"/normal?page={{page}}"}])',
                  },
                ],
                'rules': {
                  'exploreList': '.bookbox',
                  'exploreTitle': '.bookname a@text',
                  'exploreLink': '.bookname a@href',
                  'exploreCategory': '.kind@text',
                  'nextExplore': '.pages a.next@href',
                  'content': '#content@text',
                },
              },
            });
            await install(source);

            final categories = await repository.categories(
              BookKind.text,
              source.id,
              CancellationToken(),
            );
            expect(categories.map((category) => category.title), ['玄幻']);
            expect(requests, isEmpty);
            await expectLater(
              repository.discover(
                BookKind.text,
                source.id,
                CancellationToken(),
                category: const LegadoCategory('肉文', '/normal/2'),
              ),
              throwsA(isA<ContentBlocked>()),
            );
            expect(requests, isEmpty);

            // This is a valid ordinary page shape, but the expanded adult
            // category has priority and the resulting cursor must be withheld.
            final blocked = await repository.discover(
              BookKind.text,
              source.id,
              CancellationToken(),
            );
            expect(blocked.books.map((book) => book.title), ['星际普通']);
            expect(blocked.next, isNull);
            expect(requests.map((request) => request.$2.path), ['/normal']);

            requests.clear();
            nextLink = '/normal?page=2';
            final first = await repository.discover(
              BookKind.text,
              source.id,
              CancellationToken(),
            );
            expect(first.next, isNotNull);
            final second = await repository.discover(
              BookKind.text,
              source.id,
              CancellationToken(),
              page: 2,
              cursor: first.next,
            );
            expect(second.books.map((book) => book.title), ['星际普通']);
            expect(requests.map((request) => request.$2.path), [
              '/normal',
              '/normal',
            ]);
            expect(
              requests.map((request) => request.$2.queryParameters['page']),
              ['1', '2'],
            );

            BookSource scriptSource(
              String key,
              List<Map<String, String>> categories,
              Map<String, String> rules, {
              String search = '',
              String pattern = '',
              BookKind kind = BookKind.text,
            }) => BookSource.fromJson({
              'name': '发现脚本 $key',
              'url': 'https://$key.dynamic.example/',
              'kind': kind.name,
              'format': 'html',
              'legado': {
                'explore': categories,
                if (search.isNotEmpty) 'search': search,
                if (pattern.isNotEmpty) 'bookUrlPattern': pattern,
                'rules': {'content': '#content@text', ...rules},
              },
            });
            final categoryScript = scriptSource('category-ajax', [
              {'title': '普通', 'url': "@js:java.ajax('/adult')"},
            ], {});
            await install(categoryScript);
            requests.clear();
            await expectLater(
              repository.categories(
                BookKind.text,
                categoryScript.id,
                CancellationToken(),
              ),
              throwsA(isA<FormatException>()),
            );
            expect(requests, isEmpty);

            final addressScript = scriptSource('address-ajax', [
              {
                'title': '',
                'url':
                    '@js:JSON.stringify([{title:"普通",url:"@js:java.ajax(\'/adult\')"}])',
              },
            ], {});
            await install(addressScript);
            requests.clear();
            await expectLater(
              repository.discover(
                BookKind.text,
                addressScript.id,
                CancellationToken(),
              ),
              throwsA(isA<FormatException>()),
            );
            expect(requests, isEmpty);

            final listScript = scriptSource(
              'list-ajax',
              [
                {'title': '普通', 'url': '/normal'},
              ],
              {'exploreList': "@js:java.ajax('/adult')"},
            );
            await install(listScript);
            requests.clear();
            await expectLater(
              repository.discover(
                BookKind.text,
                listScript.id,
                CancellationToken(),
              ),
              throwsA(isA<FormatException>()),
            );
            expect(requests.map((request) => request.$2.path), ['/normal']);
            requests.clear();
            final aggregate = await repository.find(
              BookKind.text,
              '',
              CancellationToken(),
              sourceIds: {listScript.id},
            );
            expect(aggregate.books, isEmpty);
            expect(requests.map((request) => request.$2.path), ['/normal']);
            requests.clear();
            final fallback = await repository.find(
              BookKind.text,
              '星际',
              CancellationToken(),
              sourceIds: {listScript.id},
            );
            expect(fallback.books, isEmpty);
            expect(requests.map((request) => request.$2.path), ['/normal']);

            final directScript = scriptSource(
              'detail-ajax',
              [
                {'title': '普通', 'url': '/normal'},
              ],
              {'infoTitle': "@js:java.ajax('/adult')"},
              pattern: r'https://detail-ajax\.dynamic\.example/book/.*',
            );
            await install(directScript);
            requests.clear();
            final direct = await repository.find(
              BookKind.text,
              'https://detail-ajax.dynamic.example/book/1',
              CancellationToken(),
              sourceIds: {directScript.id},
            );
            expect(direct.books, isEmpty);
            expect(requests.map((request) => request.$2.path), ['/book/1']);

            final detailChain = scriptSource(
              'detail-chain',
              [
                {'title': '肉文', 'url': '/adult'},
                {'title': '普通', 'url': '/normal'},
              ],
              {'infoTitle': "@js:java.ajax('/adult')"},
            );
            await install(detailChain);
            final detailBook = Book(
              detailChain.id,
              BookKind.text,
              '普通作品',
              '作者',
              detailChain.endpoint.resolve('/book/1'),
            );
            requests.clear();
            await expectLater(
              repository.details(detailBook, CancellationToken()),
              throwsA(anything),
            );
            expect(requests.map((request) => request.$2.path), ['/book/1']);

            final safeDetail = scriptSource(
              'safe-detail',
              [
                {'title': '肉文', 'url': '/adult'},
                {'title': '普通', 'url': '/normal'},
              ],
              {'infoTitle': "@js:java.ajax('/helper')"},
            );
            await install(safeDetail);
            final safeBook = Book(
              safeDetail.id,
              BookKind.text,
              '普通作品',
              '作者',
              safeDetail.endpoint.resolve('/book/1'),
            );
            requests.clear();
            await repository.details(safeBook, CancellationToken());
            expect(requests.map((request) => request.$2.path), [
              '/book/1',
              '/helper',
            ]);

            final tocChain = scriptSource(
              'toc-chain',
              [
                {'title': '肉文', 'url': '/adult'},
                {'title': '普通', 'url': '/normal'},
              ],
              {'toc': "@js:java.ajax('/adult')"},
            );
            await install(tocChain);
            final tocBook = Book(
              tocChain.id,
              BookKind.text,
              '普通作品',
              '作者',
              tocChain.endpoint.resolve('/book/1'),
            );
            requests.clear();
            await expectLater(
              repository.chapters(tocBook, CancellationToken()),
              throwsA(anything),
            );
            expect(requests.map((request) => request.$2.path), ['/book/1']);

            final textChain = scriptSource(
              'text-chain',
              [
                {'title': '肉文', 'url': '/adult'},
                {'title': '普通', 'url': '/normal'},
              ],
              {'content': "@js:java.ajax('/adult')"},
            );
            await install(textChain);
            final textBook = Book(
              textChain.id,
              BookKind.text,
              '普通作品',
              '作者',
              textChain.endpoint.resolve('/book/1'),
            );
            final textChapter = BookChapter(
              '第一章',
              textChain.endpoint.resolve('/chapter/1'),
            );
            requests.clear();
            await expectLater(
              repository.readText(textBook, textChapter, CancellationToken()),
              throwsA(anything),
            );
            expect(requests.map((request) => request.$2.path), ['/chapter/1']);
            expect(
              await repository.store.readingCache(textBook, textChapter),
              isNull,
            );

            final probeChain = scriptSource(
              'probe-chain',
              [
                {'title': '肉文', 'url': '/adult'},
                {'title': '普通', 'url': '/normal'},
              ],
              {
                'searchList': '.bookbox',
                'searchTitle': '.bookname a@text',
                'searchLink': '.bookname a@href',
                'infoTitle': "@js:java.ajax('/adult')",
              },
              search: '/search?key={{key}}',
            );
            await install(probeChain);
            requests.clear();
            await repository.probe(probeChain, '星际', CancellationToken());
            expect(requests.map((request) => request.$2.path), [
              '/search',
              '/book/1',
            ]);

            final comicScript = scriptSource(
              'comic-ajax',
              [
                {'title': '肉文', 'url': '/adult'},
                {'title': '普通', 'url': '/normal'},
              ],
              {'content': "@js:java.ajax('/adult')"},
              kind: BookKind.comic,
            );
            await install(comicScript);
            final comicBook = Book(
              comicScript.id,
              BookKind.comic,
              '普通作品',
              '作者',
              comicScript.endpoint.resolve('/book/1'),
            );
            final comicChapter = BookChapter(
              '第一话',
              comicScript.endpoint.resolve('/chapter/1'),
            );
            requests.clear();
            await expectLater(
              repository.chapterImages(
                comicBook,
                comicChapter,
                CancellationToken(),
              ),
              throwsA(anything),
            );
            expect(requests.map((request) => request.$2.path), ['/chapter/1']);

            final audioScript = scriptSource(
              'audio-ajax',
              [
                {'title': '肉文', 'url': '/adult'},
                {'title': '普通', 'url': '/normal'},
              ],
              {'content': "@js:java.ajax('/adult')"},
              kind: BookKind.audio,
            );
            await install(audioScript);
            final audioBook = Book(
              audioScript.id,
              BookKind.audio,
              '普通作品',
              '作者',
              audioScript.endpoint.resolve('/book/1'),
            );
            final audioChapter = BookChapter(
              '第一章',
              audioScript.endpoint.resolve('/chapter/1'),
            );
            requests.clear();
            await expectLater(
              repository.download(audioBook, audioChapter, CancellationToken()),
              throwsA(anything),
            );
            expect(requests.map((request) => request.$2.path), ['/chapter/1']);
            expect(
              await repository.store.provenAudio(audioBook, audioChapter),
              isNull,
            );

            final searchScript = scriptSource('search-ajax', [], {
              'searchList': "@js:java.ajax('/helper')",
            }, search: '/search?key={{key}}');
            await install(searchScript);
            requests.clear();
            await repository.find(
              BookKind.text,
              '星际',
              CancellationToken(),
              sourceIds: {searchScript.id},
            );
            expect(requests.map((request) => request.$2.path), [
              '/search',
              '/helper',
            ]);
            await services.settings.update({'filterAdult': false});
            requests.clear();
            expect(
              (await repository.categories(
                BookKind.text,
                categoryScript.id,
                CancellationToken(),
              )).map((category) => category.title),
              ['普通'],
            );
            expect(requests.map((request) => request.$2.path), ['/adult']);
          } finally {
            await services.close();
          }
        },
        createHttpClient: (context) {
          final client = _RealHttpOverrides().createHttpClient(context)
            ..findProxy = (_) => 'DIRECT';
          return _LoopbackClient(
            client,
            Uri.parse('http://127.0.0.1:${server.port}'),
            requests,
          );
        },
      );
    } finally {
      await server.close(force: true);
      await root.delete(recursive: true);
    }
  });
}

final class _RealHttpOverrides extends HttpOverrides {}

/// Refuse all hosts except the synthetic sources and connect only to loopback.
final class _LoopbackClient implements HttpClient {
  _LoopbackClient(this.client, this.base, this.requests);
  final HttpClient client;
  final Uri base;
  final List<(String, Uri)> requests;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) {
    if (uri.scheme != 'https' ||
        (uri.host != 'dynamic.example' &&
            !uri.host.endsWith('.dynamic.example'))) {
      throw StateError('Unexpected fixture host: ${uri.host}');
    }
    requests.add((method, uri));
    return client.openUrl(
      method,
      base.replace(path: uri.path, query: uri.hasQuery ? uri.query : null),
    );
  }

  @override
  void close({bool force = false}) => client.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isSetter) return null;
    return super.noSuchMethod(invocation);
  }
}
