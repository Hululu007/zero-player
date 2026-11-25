import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/document_client.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/core/network/poster_repository.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/data/publication_recommendations.dart';
import 'package:zero_player/features/publications/domain/publication.dart';

import '../../test_support/publication_catalogue_fixture.dart';

const _douban = '''
<table><tr class="item">
  <td><a class="nbg"><img src="//img3.doubanio.com/book.jpg"></a></td>
  <td><div class="pl2"><a href="/subject/123/?tracking=yes" title="示例书">另一个标题</a></div>
  <p class="pl">作者 / 译者 / 出版社 / 2020-3 / 50元</p>
  <span class="rating_nums">9.6</span><span class="inq">公开推荐语</span></td>
</tr><tr class="item"><td><div class="pl2">
  <a href="javascript:void(0)">无效书目</a>
</div></td></tr></table>
''';

const _details = '''
<div id="info"><span class="pl">ISBN:</span> 9787020002207<br></div>
<div id="link-report"><div class="short"><div class="intro"><p>节选</p></div></div>
<div class="all"><div class="intro"><p>来源提供的简介</p></div></div></div>
''';

const _weRead = '''
<ul><li class="wr_bookList_item">
  <a href="/web/reader/a123" class="wr_bookList_item_link"></a>
  <img class="wr_bookCover_img" src="https://cdn.weread.qq.com/cover.jpg">
  <p class="wr_bookList_item_title">微信书目</p>
  <p class="wr_bookList_item_author">示例作者</p>
  <span class="wr_bookList_item_reading_percent">92%</span>
  <p class="wr_bookList_item_desc">榜单简介</p>
</li><li class="wr_bookList_item">
  <a href="https://example.com/web/reader/a123" class="wr_bookList_item_link"></a>
  <p class="wr_bookList_item_title">站外条目</p>
</li></ul>
''';

void main() {
  test(
    'anonymous boards preserve public metadata and canonical source links',
    () {
      final book = parsePublicationBoard(
        PublicationBoard.douban,
        _douban,
      ).single;
      expect(book.title, '示例书');
      expect(book.translator, '译者');
      expect(book.publisher, '出版社');
      expect(book.rating, '豆瓣评分 9.6');
      expect(book.cover.toString(), 'https://img3.doubanio.com/book.jpg');
      expect(book.page.toString(), 'https://book.douban.com/subject/123/');
      expect(book.candidates, isEmpty);
      final saved = PublicationEdition.fromJson(
        book.withCandidates([]).toJson(),
      );
      expect(saved.cover, book.cover);
      expect(saved.description, book.description);

      final weRead = parsePublicationBoard(
        PublicationBoard.weReadRising,
        _weRead,
      ).single;
      expect(weRead.title, '微信书目');
      expect(weRead.description, '榜单简介');
      expect(weRead.rating, '微信读书推荐值 92%');
      expect(weRead.cover?.host, 'cdn.weread.qq.com');
      expect(weRead.candidates, isEmpty);
    },
  );

  test(
    'board cache rechecks content policy and details load only on demand',
    () async {
      await withPublicationCatalogue(
        host: PublicationBoard.douban.host,
        respond: (request) async {
          request.response.headers.contentType = ContentType.html;
          request.response.write(
            request.uri.path == '/top250' ? _douban : _details,
          );
          await request.response.close();
        },
        (fixture) async {
          final client = MediaHttpClient();
          addTearDown(client.close);
          var allowed = true;
          final service = PublicationRecommendations(
            PublicationHttp(client, authorize: (_) {}),
            (_) => allowed,
          );
          final result = (await service.load(
            PublicationBoard.douban,
            1,
            CancellationToken(),
          )).single;
          expect(fixture.requests.single.path, '/top250');
          allowed = false;
          expect(
            await service.load(PublicationBoard.douban, 1, CancellationToken()),
            isEmpty,
          );
          expect(await service.details(result, CancellationToken()), isNull);
          allowed = true;
          final detail = await service.details(result, CancellationToken());
          expect(detail, (isbn: '9787020002207', description: '来源提供的简介'));
          expect(await service.details(result, CancellationToken()), detail);
          await service.load(PublicationBoard.douban, 2, CancellationToken());
          expect(fixture.requests.map((uri) => uri.path), [
            '/top250',
            '/subject/123/',
            '/top250',
          ]);
          expect(fixture.requests.last.queryParameters['start'], '25');
        },
      );
    },
  );

  if (const bool.fromEnvironment('RUN_PUBLICATION_BOARDS_ONLINE')) {
    test(
      'live boards, Douban detail and cover use production transport',
      _verifyLiveBoards,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}

Future<void> _verifyLiveBoards() async {
  final client = MediaHttpClient();
  addTearDown(client.close);
  final covers = PosterRepository(
    DocumentClient(client),
    validateTarget: validatePublicationAddress,
  );
  addTearDown(covers.close);
  final service = PublicationRecommendations(
    PublicationHttp(client, authorize: validatePublicationAddress),
    (_) => true,
  );
  await Future.wait(
    PublicationBoard.values.map((board) async {
      final books = await service.load(board, 1, CancellationToken());
      expect(books, isNotEmpty);
      final first = books.firstWhere((book) => book.cover != null);
      final lease = covers.acquire(first.cover.toString());
      try {
        expect(await lease.bytes, isNotEmpty);
      } finally {
        lease.release();
      }
      if (board.isDouban) {
        final detail = await service.details(books.first, CancellationToken());
        expect(detail?.isbn, isNotEmpty);
      }
      stdout.writeln(
        '${board.label}: ${books.length} rows, cover decoded as image payload',
      );
    }),
  );
}
