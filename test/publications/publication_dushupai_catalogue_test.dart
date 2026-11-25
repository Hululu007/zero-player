import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/publications/application/publication_discovery.dart';
import 'package:zero_player/features/publications/data/publication_dushupai_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/data/publication_store.dart';
import 'package:zero_player/features/publications/domain/publication.dart';

import '../../test_support/publication_catalogue_fixture.dart';

void main() {
  const listing = '''
    <title>python电子书搜索结果-读书派</title>
    <ul class="portfolio-book">
      <li class="portfolio-item">
        <div class="portfolio-thumb"><a href="/book-content-18908.html">
          <img src="https://images.example.com/18908.jpg"
            data-original="https://tc-new.z.wiki/autoupload/book.jpg" alt="Python 101">
        </a></div>
        <div class="portfolio-title">
          <a href="/book-content-18908.html"><em>Python</em> 101</a>
        </div>
        <div class="portfolio-author">Michael Driscoll</div>
        <a href="https://pan.example.com/book.pdf">下载</a>
      </li>
      <li class="portfolio-item">
        <div class="portfolio-title">
          <a href="https://offsite.example.com/book-content-18908.html">其他</a>
        </div>
      </li>
    </ul>
    ''';

  test('Dushupai extracts metadata and accepts the adjacent category page', () {
    final page = parseDushupaiCatalogue(
      '$listing<a href="/book-category-xiaoshuo-2.html">下一页</a>',
      dushupaiCatalogueEndpoint,
    );
    final book = page.editions.single;
    expect(book.title, 'Python 101');
    expect(book.author, 'Michael Driscoll');
    expect(book.page?.path, '/book-content-18908.html');
    expect(book.candidates, isEmpty);
    expect(book.resources.single.lookupRequired, isTrue);
    expect(book.cover?.host, 'tc-new.z.wiki');
    expect(page.next?.path, '/book-category-xiaoshuo-2.html');
  });

  test('Dushupai remote pagination binds the original query and page', () {
    final address = Uri.https('www.dushupai.com', '/search.html', {
      'k': 'python',
      'p': '8',
    });
    final page = parseDushupaiCatalogue(
      '$listing<a href="/search.html?k=python&amp;p=9">》</a>',
      address,
    );
    expect(page.next?.queryParameters, {'k': 'python', 'p': '9'});
    for (final href in [
      '/search.html?k=other&amp;p=9',
      '/search.html?k=python&amp;p=7',
      '/search.html?k=python&amp;p=9&amp;extra=1',
      'https://other.example.net/search.html?k=python&amp;p=9',
    ]) {
      expect(
        parseDushupaiCatalogue('$listing<a href="$href">下一页</a>', address).next,
        isNull,
      );
    }
    expect(
      () => parseDushupaiCatalogue('<title>Just a moment</title>', address),
      throwsA(isA<PublicationFailure>()),
    );
  });

  test(
    'Dushupai keeps its first page if a later request has a network failure',
    () async {
      for (final status in [HttpStatus.badGateway, HttpStatus.forbidden]) {
        await withPublicationCatalogue(
          (fixture) async {
            final transport = MediaHttpClient();
            try {
              final catalogue = DushupaiCatalogue(
                PublicationHttp(transport, authorize: (_) {}),
              );
              final results = catalogue.search(
                'python',
                CancellationToken(),
                maxPages: 3,
                allowed: (_) => true,
              );
              if (status == HttpStatus.forbidden) {
                await expectLater(
                  results,
                  throwsA(
                    isA<PublicationFailure>().having(
                      (error) => error.problem,
                      'problem',
                      PublicationProblem.challenge,
                    ),
                  ),
                );
              } else {
                expect((await results).single.title, 'Python 101');
              }
              expect(fixture.requests.map((uri) => uri.queryParameters['p']), [
                null,
                '2',
              ]);
            } finally {
              transport.close();
            }
          },
          host: 'www.dushupai.com',
          respond: (request) async {
            if (request.uri.queryParameters['p'] == '2') {
              request.response.statusCode = status;
            } else {
              request.response.write(
                '$listing<a href="/search.html?k=python&amp;p=2">下一页</a>',
              );
            }
            await request.response.close();
          },
        );
      }
    },
  );

  test(
    'Dushupai reads the declared download page for the selected book',
    () async {
      final page = Uri.https('www.dushupai.com', '/book-content-30981.html');
      await withPublicationCatalogue(
        (fixture) async {
          final transport = MediaHttpClient();
          try {
            final catalogue = DushupaiCatalogue(
              PublicationHttp(transport, authorize: (_) {}),
            );
            final shares = await catalogue.loadResources(
              page,
              CancellationToken(),
            );
            expect(shares.map((row) => row.label), ['城通网盘', '迅雷网盘']);
            expect(shares.map((row) => row.code), ['1234', 'ab12']);
            expect(shares.every((row) => !row.canListFiles), isTrue);
            expect(shares.first.link.queryParameters['pwd'], '1234');
            expect(shares.last.link.queryParameters['pwd'], 'ab12');
            expect(shares.last.link.hasFragment, isFalse);
            expect(fixture.requests.map((uri) => uri.path), [
              page.path,
              '/download-book-30981.html',
            ]);
            await expectLater(
              catalogue.loadResources(
                page.replace(query: 'wrong=1'),
                CancellationToken(),
              ),
              throwsA(isA<PublicationFailure>()),
            );
          } finally {
            transport.close();
          }
        },
        host: page.host,
        respond: (request) async {
          if (request.uri.path == page.path) {
            request.response.write('''
            <div class="post-download">
              <a href="/download-book-30982.html">其他书</a>
              <a href="/download-book-30981.html">下载</a>
            </div>''');
          } else {
            expect(
              request.headers.value(HttpHeaders.refererHeader),
              page.toString(),
            );
            request.response.write('''
            <a href="https://pan.quark.cn/s/sidebar">边栏推广</a>
            <div class="block-download">
              <div id="download_declaration"><h1><a href="/book-content-30981.html">示例</a></h1></div>
              <div class="download_blcok"><div class="list">
                <div class="box">
                  <div class="source-info">提取码：1234</div>
                  <div class="button"><a href="https://url89.ctfile.com/f/100-200-abcd12?pwd=1234">立即下载</a></div>
                </div>
                <div class="box">
                  <div class="source-info"><a data-clipboard-text="ab12">复制</a></div>
                  <div class="button"><a href="https://pan.xunlei.com/s/demo-share?pwd=ab12#">立即下载</a></div>
                </div>
                <div class="box"><div class="button">
                  <a href="https://pan.quark.cn/s/extra?next=https://example.org">未知参数</a>
                </div></div>
                <div class="box"><div class="button">
                  <a href="https://pan.xunlei.com.example.org/s/spoof">伪造域</a>
                </div></div>
                <div class="box"><div class="button">
                  <a href="https://pan.xunlei.com/s/demo-other#unexpected">带非空片段</a>
                </div></div>
              </div></div>
            </div>''');
          }
          await request.response.close();
        },
      );
    },
  );

  test(
    'disabling Dushupai cancels an outstanding book resource lookup',
    () async {
      final pending = Completer<void>();
      final release = Completer<void>();
      await withPublicationCatalogue(
        (fixture) async {
          final db = AppDatabase.memory();
          final transport = MediaHttpClient();
          final discovery = PublicationDiscovery(
            PublicationStore(db),
            PublicationHttp(transport, authorize: (_) {}),
            (_) => true,
          );
          try {
            final source = (await discovery.sources())
                .singleWhere((row) => row.source.id == dushupaiSource)
                .source;
            final result = discovery.loadCatalogueResources(
              PublicationResource.lookup(
                source: source.id,
                link: Uri.https(
                  source.endpoint.host,
                  '/book-content-30981.html',
                ),
              ),
              CancellationToken(),
            );
            final stopped = expectLater(
              result,
              throwsA(isA<RequestCancelled>()),
            );
            await pending.future;
            await discovery.setEnabled(source, false);
            release.complete();
            await stopped;
            expect(fixture.requests, hasLength(1));
          } finally {
            if (!release.isCompleted) release.complete();
            discovery.close();
            transport.close();
            await db.close();
          }
        },
        host: 'www.dushupai.com',
        respond: (request) async {
          pending.complete();
          await release.future;
          await request.response.close();
        },
      );
    },
  );
}
