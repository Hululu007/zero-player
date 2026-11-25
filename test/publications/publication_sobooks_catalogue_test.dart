import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/data/publication_sobooks_catalogue.dart';

import '../../test_support/publication_catalogue_fixture.dart';

void main() {
  test(
    'SoBooks resolves the advertised browser entries and keeps valid shares',
    () async {
      final page = Uri.https('sobooks.cc', '/books/25667.html');
      await withPublicationCatalogue(
        (fixture) async {
          final transport = MediaHttpClient();
          try {
            final catalogue = SobooksCatalogue(
              PublicationHttp(transport, authorize: (_) {}),
            );
            final books = await catalogue.search(
              '示例',
              CancellationToken(),
              maxPages: 1,
              allowed: (_) => true,
            );
            expect(books.single.resources.single.lookupRequired, isTrue);
            expect(fixture.requests.map((request) => request.path), ['/']);
            final shares = await catalogue.loadResources(
              page,
              CancellationToken(),
            );
            expect(shares.map((item) => item.label), ['城通网盘', '夸克网盘']);
            expect(shares.first.code, '123456');
            expect(shares.last.code, 'AB12');
            expect(shares.last.link, Uri.https('pan.quark.cn', '/s/testbook'));
            expect(shares.last.canListFiles, isTrue);
            expect(fixture.requests.map((request) => request.path), [
              '/',
              page.path,
              '/go.html',
              '/go.html',
              '/go.html',
            ]);
            catalogue.restrictShare(page, shares.last.link);
          } finally {
            transport.close();
          }
        },
        host: page.host,
        respond: (request) async {
          switch (request.uri.path) {
            case '/':
              request.response.write(
                '<div class="card-item"><h3>'
                '<a href="/books/25667.html">示例</a></h3></div>',
              );
            case '/books/25667.html':
              request.response.write('''
              <a class="cloud-download-btn cloud-ctfile" href="/go.html?url=CTFILE123">城通</a>
              <a class="cloud-download-btn cloud-quark" href="/go.html?url=QUARK1234">夸克</a>
              <a class="cloud-download-btn cloud-baidu" href="/go.html?url=BAIDU1234">百度</a>
              <a class="cloud-download-btn cloud-quark"
                href="https://other.test/go.html?url=QUARK5678">外站</a>
              <a class="cloud-download-btn cloud-quark" href="/other?url=QUARK5678">无关入口</a>
            ''');
            case '/go.html':
              switch (request.uri.queryParameters['url']) {
                case 'CTFILE123':
                  request.response.write(
                    '<a id="goLink" href="https://url66.ctfile.com/f/123-456-aabbcc?p=123456">继续访问</a>',
                  );
                case 'QUARK1234':
                  request.response.write(
                    '<a id="goLink" href="https://pan.quark.cn/s/testbook/?pwd=AB12">继续访问</a>'
                    '<button id="copyBtn" data-code="AB12">复制</button>',
                  );
                case 'BAIDU1234':
                  // A followed HTTP redirect cannot expand the catalogue scope.
                  request.response.statusCode = HttpStatus.found;
                  request.response.headers.set(
                    HttpHeaders.locationHeader,
                    'https://pan.baidu.com/s/testbook',
                  );
              }
          }
          await request.response.close();
        },
      );
    },
  );
}
