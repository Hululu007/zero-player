import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/features/publications/data/cloud_navhub_catalog.dart';
import 'package:zero_player/features/publications/data/cloud_resource_catalog.dart';
import 'package:zero_player/features/publications/data/cloud_resource_search.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/presentation/cloud_resource_catalog_view.dart';

import '../../test_support/publication_catalogue_fixture.dart';

final class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('HaiSou web search retains the keyword without an API key', () {
    final page = haiSouSearchPage(' Rust 语言 ');
    expect(page.origin, haiSouHome.origin);
    expect(page.path, '/');
    expect(page.queryParameters, {'q': 'Rust 语言'});
    expect(haiSouSearchPage('  '), haiSouHome);
  });

  test(
    'PanHub refusals keep the search keyword for the official page',
    () async {
      final root = await Directory.systemTemp.createTemp('panhub-test-');
      addTearDown(() => root.delete(recursive: true));
      await HttpOverrides.runZoned(
        () => withPublicationCatalogue(
          (fixture) async {
            final transport = MediaHttpClient();
            try {
              final http = PublicationHttp(transport, authorize: (_) {});
              final search = CloudResourceSearch(
                http,
                CloudNavHubCatalog(http, root),
              );
              for (final query in ['图书 PDF', '古籍']) {
                await expectLater(
                  search.panHub(query, CancellationToken()),
                  throwsA(isA<PanHubBrowserRequired>()),
                );
                expect(panHubSearchPage(query).queryParameters['q'], query);
              }
              expect(fixture.requests.single.path, '/api/search.stream');
            } finally {
              transport.close();
            }
          },
          host: panHubHome.host,
          respond: (request) async {
            request.response.statusCode = HttpStatus.forbidden;
            await request.response.close();
          },
        ),
        createHttpClient: _RealHttp().createHttpClient,
      );
    },
  );

  test(
    'PanHub uses the official verification response only on live search',
    () async {
      final root = await Directory.systemTemp.createTemp('panhub-auth-test-');
      addTearDown(() => root.delete(recursive: true));
      var authRequests = 0;
      final headers = <(String, String?)>[];
      await HttpOverrides.runZoned(
        () => withPublicationCatalogue(
          (_) async {
            final transport = MediaHttpClient();
            try {
              final http = PublicationHttp(transport, authorize: (_) {});
              final source = CloudResourceSearch(
                http,
                CloudNavHubCatalog(http, root),
              );
              await source.signInPanHub('123456');
              expect(source.panHubSignedIn, isTrue);
              expect(
                (await source.panHub('PDF', CancellationToken())).single.title,
                '参考资料',
              );
              await source.curated('', CancellationToken());
              source.clearPanHubSession();
              expect(source.panHubSignedIn, isFalse);
              expect(authRequests, 1);
              expect(headers, [
                ('/api/auth/check', null),
                ('/api/search.stream', 'Bearer fixture.panHub.session'),
                ('/api/curated-resources', null),
              ]);
            } finally {
              transport.close();
            }
          },
          host: panHubHome.host,
          extraHosts: const {'wx-auth.shenzjd.com'},
          respond: (request) async {
            headers.add((
              request.uri.path,
              request.headers.value('authorization'),
            ));
            switch (request.uri.path) {
              case '/api/auth/check':
                expect(request.uri.queryParameters, {
                  'siteId': panHubHome.host,
                  'authToken': '123456',
                });
                authRequests++;
                request.response
                  ..headers.contentType = ContentType.json
                  ..write(
                    '{"authenticated":true,"token":"fixture.panHub.session"}',
                  );
              case '/api/search.stream':
                request.response
                  ..headers.contentType = ContentType(
                    'text',
                    'event-stream',
                    charset: 'utf-8',
                  )
                  ..write(
                    'event: done\ndata: {"merged":{"quark":[{"name":"参考资料","url":"https://pan.quark.cn/s/1234"}]}}\n\n',
                  );
              case '/api/curated-resources':
                request.response
                  ..headers.contentType = ContentType.json
                  ..write('{"code":0,"data":{"items":[]}}');
              default:
                request.response.statusCode = HttpStatus.notFound;
            }
            await request.response.close();
          },
        ),
        createHttpClient: _RealHttp().createHttpClient,
      );
    },
  );

  test('NavHub snapshot contains all 13 public categories', () async {
    final root = await Directory.systemTemp.createTemp('navhub-test-');
    final transport = MediaHttpClient();
    addTearDown(transport.close);
    addTearDown(() => root.delete(recursive: true));
    final nav = CloudNavHubCatalog(
      PublicationHttp(transport, authorize: (_) {}),
      root,
    );
    final catalog = await nav.load();
    expect(catalog.rows, hasLength(13));
    expect(catalog.rows[2].name, contains('资源搜索与下载'));
    final search = CloudResourceSearch(
      PublicationHttp(transport, authorize: (_) {}),
      nav,
    );
    expect(
      (await search.navigation('海搜')).map((hit) => hit.link),
      contains(Uri.https('haisou.cc', '/')),
    );
  });

  test('NavHub refresh parses data without using scripts or deleted links', () {
    final category = {
      'name': '资源搜索',
      'sites': [
        {'title': '分享', 'url': 'https://pan.quark.cn/s/1234'},
        {'title': '删除', 'url': 'https://example.com/', '_deleted': true},
        {'title': '本机', 'url': 'http://127.0.0.1/'},
      ],
    };
    final record = jsonEncode([
      [
        r'$',
        r'$Lg',
        null,
        {
          'initialSites': [category],
        },
      ],
    ]);
    final flight = jsonEncode([1, '5:$record\n']);
    expect(
      parseNavHubCategories('<script>self.__next_f.push($flight)</script>'),
      [
        {
          'name': '资源搜索',
          'rows': [
            {'name': '分享', 'url': 'https://pan.quark.cn/s/1234'},
          ],
        },
      ],
    );
  });

  test(
    'PanHub stream deduplicates a share and retains its extraction code',
    () {
      final result = parsePanHubSearch('''
event: chunk
data: {"merged":{"quark":[{"note":"样本","url":"https://pan.quark.cn/s/1234","password":"a123"}]}}

event: done
data: {"merged":{"quark":[{"note":"样本","url":"https://pan.quark.cn/s/1234"}]}}
''');
      expect(result.single.title, '样本');
      expect(result.single.code, 'a123');
    },
  );

  test('PanHub streams protected rows and continues by completed task', () async {
    final root = await Directory.systemTemp.createTemp('panhub-resume-test-');
    addTearDown(() => root.delete(recursive: true));
    final partial = <List<CloudSearchHit>>[];
    PanHubCursor? cursor;
    await HttpOverrides.runZoned(
      () => withPublicationCatalogue(
        (fixture) async {
          final transport = MediaHttpClient();
          try {
            final http = PublicationHttp(transport, authorize: (_) {});
            final search = CloudResourceSearch(
              http,
              CloudNavHubCatalog(http, root),
            );
            final first = await search.panHub(
              'Rust语言',
              CancellationToken(),
              platform: 'quark',
              onPartial: partial.add,
              onContinuation: (next) => cursor = next,
            );
            expect(partial[0].map((hit) => hit.reference), ['item-1', null]);
            expect(partial[1].single.code, 'b234');
            expect(partial, hasLength(2));
            expect(first.last.code, 'b234');
            expect(first.first.link.queryParameters, {
              'q': 'Rust语言',
              'cat': 'quark',
            });
            expect(cursor?.completed, {2, 4});
            final second = await search.panHub(
              'Rust语言',
              CancellationToken(),
              platform: 'quark',
              cursor: cursor,
              onContinuation: (next) => cursor = next,
            );
            expect(second.single.code, 'a123');
            expect(cursor, isNull);
            expect(fixture.requests.last.queryParameters, {
              'kw': 'Rust语言',
              'cat': 'quark',
              'maxResults': '92',
              'initialTotal': '2',
              'skipTasks': '2,4',
            });
          } finally {
            transport.close();
          }
        },
        host: panHubHome.host,
        respond: (request) async {
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          if (request.uri.queryParameters.containsKey('skipTasks')) {
            request.response.write(
              'event: done\ndata: {"merged":{"quark":[{"note":"电子书","url":"https://pan.quark.cn/s/rust","pwd":"a123"}]}}\n\n',
            );
          } else {
            request.response
              ..write(': heartbeat\r\n\r\n')
              ..write(
                'event: chunk\r\ndata: {"merged":\r\ndata: {"quark":[{"note":"Rust语言","tid":"item-1"},{"note":"第二条","url":"https://pan.quark.cn/s/second"}]}}\r\n\r\n',
              );
            await request.response.flush();
            request.response.write(
              'event: chunk\ndata: {"merged":{"quark":[{"note":"第二条","url":"https://pan.quark.cn/s/second","pwd":"b234"}]}}\n\n',
            );
            request.response.write(
              'event: done\ndata: {"completedIndices":[2,4],"reachedLimit":true}\n\n',
            );
          }
          await request.response.close();
        },
      ),
      createHttpClient: _RealHttp().createHttpClient,
    );
  });
  test(
    'bundled resource directory preserves the source categories and archives',
    () async {
      final catalog = await CloudResourceCatalog.load();
      expect(catalog.categories.map((entry) => entry.name), [
        '软件一区',
        '软件二区',
        '音乐一区',
        '音乐二区',
        '影视',
        '电子书',
        '教程',
        '素材',
        '教辅',
        '网创项目',
      ]);
      Iterable<Uri> links(CloudResourceEntry entry) sync* {
        if (entry.link case final link?) yield link;
        for (final row in entry.rows) {
          yield* links(row);
        }
      }

      expect(catalog.categories.expand(links).length, 1221);
      final software = catalog.categories.first;
      expect(
        software.rows
            .singleWhere((row) => row.name == '视频工具')
            .rows
            .singleWhere((row) => row.name == '视频下载')
            .rows
            .first
            .name,
        'ABDownloadManager',
      );
    },
  );

  testWidgets('finding an entry preserves its archive and opens its share', (
    tester,
  ) async {
    final catalog = (await tester.runAsync(CloudResourceCatalog.load))!;
    Uri? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CloudResourceCatalogView(
            catalog: Future.value(catalog),
            allowed: (_) => true,
            open: (_, _) {},
            parse: (uri, _) => selected = uri,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'ABDownloadManager');
    await tester.pumpAndSettle();
    expect(find.text('视频工具'), findsOneWidget);
    expect(find.text('视频下载'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, 'ABDownloadManager'));
    expect(selected, Uri.https('pan.quark.cn', '/s/ecd36baf588b'));
  });
}
