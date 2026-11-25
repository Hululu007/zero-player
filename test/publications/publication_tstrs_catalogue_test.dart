import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/data/publication_tstrs_catalogue.dart';
import 'package:zero_player/features/publications/domain/publication.dart';

import '../../test_support/publication_catalogue_fixture.dart';

void main() {
  test(
    'keyword search considers every public board when discovery shows one',
    () async {
      await withPublicationCatalogue(
        (fixture) async {
          final transport = MediaHttpClient();
          try {
            final catalog = TstrsCatalogue(
              PublicationHttp(transport, authorize: (_) {}),
            );
            final books = await catalog.search(
              'Outside the first board',
              CancellationToken(),
              maxPages: 1,
              allowed: (_) => true,
            );
            expect(books.single.page?.path, '/b/hidden-book');
            expect(
              fixture.requests.map((uri) => uri.queryParameters['board']),
              unorderedEquals(['classics', 'hot', 'top-rated', 'hidden']),
            );
          } finally {
            transport.close();
          }
        },
        host: 'tstrs.me',
        respond: (request) async {
          final board = request.uri.queryParameters['board'];
          request.response.write(
            _chart([
              if (board == 'hidden')
                _row('/b/hidden-book', 'Outside the first board')
              else
                _row('/b/first-board', 'Other book'),
            ]),
          );
          await request.response.close();
        },
      );
    },
  );

  test('reads chart metadata and exposes only the original detail page', () {
    final chart = _chart([
      _row('/b/红楼梦', ' 红楼梦 '),
      _row('https://tstrs.me/b/%E7%BA%A2%E6%A5%BC%E6%A2%A6', 'Duplicate'),
      _row('/b/alice-in-wonderland', 'Alice in Wonderland'),
      '<a class="side-row" href="/b/recommendation">Sidebar item</a>',
    ]);
    final entries = parseTstrsChart(chart);
    expect(entries.map((entry) => entry.title), ['红楼梦', 'Alice in Wonderland']);
    final entry = entries.first;
    expect(entry.author, '曹雪芹 / 李智 / 杨晶');
    expect(entry.edition, '北方文艺出版社 · 2015');
    expect(entry.page?.pathSegments, ['b', '红楼梦']);
    expect(entry.candidates, isEmpty);
  });

  test('ignores other origins, gated routes and forged slugs', () {
    final chart = _chart([
      _row('//other.test/b/book', 'Scheme relative'),
      _row('https://other.test/b/book', 'Other host'),
      _row('https://tstrs.me.other.test/b/book', 'Other host suffix'),
      _row('https://tstrs.me:444/b/book', 'Other port'),
      _row('https://user@tstrs.me/b/book', 'User information'),
      _row('http://tstrs.me/b/book', 'Insecure'),
      _row('/out?url=https://other.test/', 'Redirector'),
      _row('/search?q=foo', 'Search'),
      _row('/b/escape%2Fout', 'Encoded path separator'),
      _row('/b/..%5Cout', 'Encoded backslash'),
      _row('/b/html#section', 'Fragment'),
      _row('/b/html?url=https://other.test/', 'Query'),
      _row('/b/book', 'Safe chart row'),
    ]);
    expect(parseTstrsChart(chart).single.title, 'Safe chart row');
  });

  test('an access page or changed chart format is rejected', () {
    expect(
      () => parseTstrsChart('<main><p>Human verification</p></main>'),
      throwsA(
        isA<PublicationFailure>().having(
          (error) => error.problem,
          'problem',
          PublicationProblem.invalid,
        ),
      ),
    );
  });
}

String _chart(List<String> rows) => '<main>${rows.join()}</main>';

String _row(String href, String title) =>
    '''
<a class="search-row rank-item" href="$href">
  <span class="search-row-title">$title</span>
  <span class="search-row-author">曹雪芹 / 李智 / 杨晶</span>
  <span class="search-row-press">北方文艺出版社 · 2015</span>
  <span class="search-row-summary"><a href="/out">Ignore</a></span>
</a>
''';
