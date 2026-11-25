import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/data/publication_kgbook_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_kgbook_download.dart';
import 'package:zero_player/features/publications/data/publication_kgbook_rows.dart'
    show kgbookListing;
import 'package:zero_player/features/publications/domain/publication.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'verified 1984 options can be shown without fetching its detail page',
    () async {
      final transport = MediaHttpClient();
      addTearDown(transport.close);
      final downloads = KgbookDownloads(
        PublicationHttp(transport, authorize: (_) {}),
      );
      final page = Uri.https('kgbook.com', '/waiguowenxue/1007.html');
      final choices = await downloads.resources(page, CancellationToken());
      expect(
        choices.map((entry) => entry.format),
        unorderedEquals([PublicationFormat.pdf, PublicationFormat.mobi]),
      );
      final resolved = await downloads.resolve(
        AcquisitionCandidate(
          source: kgbookSource,
          link: page,
          page: page,
          format: PublicationFormat.pdf,
        ),
        CancellationToken(),
      );
      expect(resolved.uri.path, '/e/DownSys/GetDown/');
      expect(resolved.rangeTarget!(resolved.uri), isFalse);
    },
  );

  test('1984 PDF and MOBI options are scoped to the published book', () {
    final page = Uri.https('kgbook.com', '/waiguowenxue/1007.html');
    final rows = parseKgbookDownloadLinks(
      '''
      <a href="/e/DownSys/GetDown?classid=7&amp;id=1008&amp;pathid=0">PDF</a>
      <a href="/e/DownSys/GetDown?classid=7&amp;id=1007&amp;pathid=0">6寸pdf</a>
      <a href="/e/DownSys/GetDown?classid=7&amp;id=1007&amp;pathid=1">Mobi格式</a>
      ''',
      page,
      '1007',
    );
    expect(rows[PublicationFormat.pdf]?.queryParameters['id'], '1007');
    expect(rows[PublicationFormat.pdf]?.queryParameters['pathid'], '0');
    expect(rows[PublicationFormat.mobi]?.queryParameters['pathid'], '1');
  });

  test(
    'keyword search covers the public biography, classics and sci-fi catalogues',
    () async {
      final transport = MediaHttpClient();
      addTearDown(transport.close);
      final adapter = KgbookCatalogue(
        PublicationHttp(transport, authorize: (_) {}),
      );
      for (final (title, path, format) in [
        ('红楼梦', '/gudianwenxue/714.html', PublicationFormat.mobi),
        ('三体', '/kehuanxuanhuan/513.html', PublicationFormat.pdf),
        ('斯通纳', '/renwuchuanji/1298.html', PublicationFormat.azw3),
      ]) {
        final results = await adapter.search(
          title,
          CancellationToken(),
          maxPages: 1,
          allowed: (_) => true,
        );
        final book = results.singleWhere((book) => book.title == title);
        final candidate = book.candidates.single;
        expect(candidate.link, Uri.https('kgbook.com', path));
        expect(candidate.format, format);
        expect(book.resources.single.lookupRequired, isTrue);
      }
    },
  );

  test('Kgbook extracts title and author from the classics directory', () {
    final page = parseKgbookCatalogue('''
      <h3 class="list-title">
        <a href="https://kgbook.com/gudianwenxue/1231.html">庄子今注今译</a>
        <span class="list-author"><em>陈鼓应</em></span>
      </h3>
      <h3 class="list-title"><a href="/gudianwenxue/1231.html">重复</a></h3>
      <h3 class="list-title"><a href="/e/1231.html">受限路径</a></h3>
      <h3 class="list-title"><a href="https://example.com/gudianwenxue/1231.html">外站</a></h3>
      <a href="/d/1231.html">下载</a>
      <a href="index_2.html">下一页</a>
      ''', kgbookListing('gudianwenxue'));

    final edition = page.editions.single;
    expect(edition.title, '庄子今注今译');
    expect(edition.author, '陈鼓应');
    expect(edition.page?.path, '/gudianwenxue/1231.html');
    expect(edition.candidates, isEmpty);
    expect(page.next?.path, '/gudianwenxue/index_2.html');
  });

  test('Kgbook stays on adjacent pages inside its public directory', () {
    for (final url in [
      '/e/search/index.php',
      '/gudianwenxue/index_3.html',
      '/gudianwenxue/index_2.html?x=1',
      'https://kgbook.com.example.com/gudianwenxue/index_2.html',
    ]) {
      final page = parseKgbookCatalogue(
        '<a href="$url">下一页</a>',
        kgbookListing('gudianwenxue'),
      );
      expect(page.next, isNull);
    }
  });
}
