import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/data/publication_lunarora_catalogue.dart';
import 'package:zero_player/features/publications/domain/publication.dart';

import '../../test_support/publication_catalogue_fixture.dart';

void _retryTest() {
  test(
    'Lunarora retries one transient response and honours rate limits',
    () async {
      for (final status in [
        HttpStatus.badGateway,
        HttpStatus.tooManyRequests,
      ]) {
        var requests = 0;
        await withPublicationCatalogue(
          (_) async {
            final transport = MediaHttpClient();
            try {
              final catalogue = LunaroraCatalogue(
                PublicationHttp(transport, authorize: (_) {}),
              );
              final search = catalogue.search(
                '三体',
                CancellationToken(),
                maxPages: 1,
                allowed: (_) => true,
              );
              if (status == HttpStatus.tooManyRequests) {
                await expectLater(
                  search,
                  throwsA(
                    isA<PublicationFailure>().having(
                      (failure) => failure.problem,
                      'problem',
                      PublicationProblem.rateLimit,
                    ),
                  ),
                );
                expect(requests, 1);
              } else {
                expect(await search, isEmpty);
                expect(requests, 2);
              }
            } finally {
              transport.close();
            }
          },
          host: 'lunarora.com',
          respond: (request) async {
            requests++;
            if (requests == 1) {
              request.response.statusCode = status;
            } else {
              request.response.write(
                '{"apiVersion":"2","contentLanguage":"zh-CN","count":0,"results":[]}',
              );
            }
            await request.response.close();
          },
        );
      }
    },
  );
}

void main() {
  _shareParserTest();
  _retryTest();

  test('Lunarora restricts discovery to canonical book paths', () {
    final results = parseLunaroraDirectory('''
      <section class="book-page-group" data-page="1">
        <a class="card" data-book-isbn="9787546237381" href="/book/9787546237381">
          <h3 class="title">草民</h3>
          <img src="https://covers.lunarora.com/fixture.webp">
        </a>
        <a class="card" data-book-isbn="9787546237381" href="/book/9787546237381">
          <h3 class="title">重复条目</h3>
        </a>
        <a data-book-isbn="9787549641895" href="/book/9787549641895?download=1">
          <h3 class="title">受限地址</h3>
        </a>
      </section>
      <a data-book-isbn="9787572617294" href="/book/9787572617294">
        <h3 class="title">目录外链接</h3>
      </a>
      ''');
    expect(results.single.title, '草民');
    expect(results.single.cover?.host, 'covers.lunarora.com');
    expect(
      results.single.page,
      Uri.https('lunarora.com', '/book/9787546237381'),
    );
    expect(results.single.candidates, isEmpty);
    expect(results.single.resources.single.lookupRequired, isTrue);
  });

  test(
    'Lunarora discovery reads each book’s visible download cards on demand',
    () async {
      final page = Uri.https('lunarora.com', '/book/9787020161171');
      await withPublicationCatalogue(
        (fixture) async {
          final transport = MediaHttpClient();
          try {
            final catalogue = LunaroraCatalogue(
              PublicationHttp(transport, authorize: (_) {}),
            );
            final resources = await catalogue.loadResources(
              page,
              CancellationToken(),
            );
            expect(resources.map((item) => item.label), ['夸克网盘', '迅雷网盘']);
            expect(resources.map((item) => item.code), ['AB12', 'EF45']);
            expect(resources.first.link.hasQuery, isFalse);
            expect(resources.first.canListFiles, isTrue);
            expect(resources.last.canListFiles, isFalse);
            expect(fixture.requests, [page]);
            catalogue.restrictShare(page, resources.first.link);
          } finally {
            transport.close();
          }
        },
        host: page.host,
        respond: (request) async {
          request.response.write('''
          <main class="book-detail-main">
            <section class="download-section">
              <div class="download-link-card">
                <div class="extraction-code"><code>AB12</code></div>
                <a class="download-btn" href="https://pan.quark.cn/s/example?pwd=AB12">下载</a>
              </div>
              <div class="download-link-card">
                <div class="extraction-code"><code>EF45</code></div>
                <a class="download-btn" href="https://pan.xunlei.com/s/example">下载</a>
              </div>
              <div class="download-link-card">
                <div class="extraction-code"><code>FAIL</code></div>
                <a class="download-btn" href="https://pan.baidu.com/s/example?pwd=DIFF">无效</a>
              </div>
            </section>
          </main>''');
          await request.response.close();
        },
      );
    },
  );

  test(
    'Lunarora checks API availability independently of its directory',
    () async {
      await withPublicationCatalogue(
        (fixture) async {
          final transport = MediaHttpClient();
          try {
            final catalogue = LunaroraCatalogue(
              PublicationHttp(transport, authorize: (_) {}),
            );
            await catalogue.check(CancellationToken());
            final request = fixture.requests.single;
            expect(request.path, '/api/v2/search');
            expect(request.queryParameters, {'q': '图书', 'limit': '1'});
          } finally {
            transport.close();
          }
        },
        host: 'lunarora.com',
        respond: (request) async {
          if (request.uri.path != '/api/v2/search') {
            request.response.statusCode = HttpStatus.gone;
          } else {
            request.response.write(
              '{"apiVersion":"2","contentLanguage":"zh-CN","count":0,"results":[]}',
            );
          }
          await request.response.close();
        },
      );
    },
  );
}

void _shareParserTest() {
  test(
    'Lunarora binds public shares to the canonical edition and provider',
    () {
      final standard = {
        'type': 'Book',
        'catalogId': '9787115474810',
        'bookUrl': 'https://lunarora.com/book/9787115474810',
        'title': 'Python神经网络编程',
        'authorsText': '[英] Tariq Rashid',
        'coverUrl': 'https://covers.lunarora.com/fixture.jpg',
        'hasDownloadLinks': true,
        'downloadLinks': [
          {
            'provider': 'quark',
            'url': 'https://pan.quark.cn/s/fixture',
            'extractionCode': 'AB12',
          },
          {
            'provider': 'baidu',
            'url': 'https://pan.baidu.com/s/fixture?pwd=EF45',
          },
          {
            'provider': 'quark',
            'url': 'https://pan.quark.cn.example.com/s/fixture',
          },
          {
            'provider': 'baidu',
            'url': 'https://pan.baidu.com/s/fixture?pwd=EF45',
            'extractionCode': 'DIFF',
          },
          {'provider': 'xunlei', 'url': 'https://pan.quark.cn/s/fixture'},
        ],
      };
      final ancient = {
        'type': 'Book',
        'catalogId': 'GJ00000000001',
        'bookUrl': 'https://lunarora.com/book/GJ00000000001',
        'title': '古籍书目',
        'authorsText': '',
      };
      final results = parseLunaroraSearch({
        'apiVersion': '2',
        'contentLanguage': 'zh-CN',
        'count': 5,
        'results': [
          standard,
          standard,
          ancient,
          {...standard, 'bookUrl': 'https://lunarora.com/book/9787115517210'},
          {...ancient, 'bookUrl': 'https://example.com/book/GJ00000000001'},
        ],
      });
      expect(results, hasLength(2));
      expect(results.first.isbn, '9787115474810');
      expect(results.first.author, '[英] Tariq Rashid');
      expect(results.first.cover?.host, 'covers.lunarora.com');
      expect(results.last.isbn, isEmpty);
      expect(results.map((row) => row.candidates), everyElement(isEmpty));
      final resources = results.first.resources;
      expect(resources.map((resource) => resource.code), ['AB12', 'EF45']);
      expect(resources.map((resource) => resource.canListFiles), [true, true]);
      final transport = MediaHttpClient();
      addTearDown(transport.close);
      final adapter = LunaroraCatalogue(
        PublicationHttp(transport, authorize: (_) {}),
      );
      adapter.restrictShare(results.first.page, resources.first.link);
      adapter.restrictShare(results.first.page, resources.last.link);
      expect(
        () => adapter.restrictShare(
          Uri.https('different.example', '/book/9787115474810'),
          resources.last.link,
        ),
        throwsA(isA<PublicationFailure>()),
      );
      expect(
        () => parseLunaroraSearch({'apiVersion': '1', 'results': []}),
        throwsA(isA<PublicationFailure>()),
      );
    },
  );
}
