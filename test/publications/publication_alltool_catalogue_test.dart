import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/publications/data/publication_alltool_catalogue.dart';

void main() {
  test('Alltool keeps the download section on the canonical book page', () {
    final page = parseAlltoolCatalogue('''
      <section>
        <h2><a href="/book/upc2h"><span>万物源起</span></a></h2>
        <div><span class="iconify i-lucide:user"></span>
          <span class="text-gray-400 line-clamp-1">[韩] 金宝英 著</span>
        </div>
        <a href="/book/upc2h"><img src="/upc2h.jpg"></a>
        <a href="https://pan.example.com/page">下载</a>
      </section>
      <section><h2><a href="/book/upc2h">重复书目</a></h2></section>
      <section><h2><a href="https://example.com/book/abcd1">外站</a></h2></section>
      <section><h2><a href="/book/abcd1?download=true">带参数地址</a></h2></section>
      <section><h2><a href="/book/request">导航</a></h2></section>
      <section><h2><a href="/book/ranks">榜单导航</a></h2></section>
      <a href="/book/rank/latest?page=2" data-slot="next">Next Page</a>
      ''', alltoolCatalogueEndpoint);

    final edition = page.editions.single;
    expect(edition.title, '万物源起');
    expect(edition.matches('金宝英'), isTrue);
    expect(edition.page, Uri.https('alltool.top', '/book/upc2h'));
    expect(edition.candidates, isEmpty);
    expect(
      edition.resources.single.link,
      edition.page!.replace(fragment: 'download'),
    );
    expect(page.next?.query, 'page=2');
  });

  test('Alltool only follows the adjacent public ranking page', () {
    for (final url in [
      '/search?query=example',
      '/book/rank/latest?page=3',
      '/book/rank/latest?page=2&other=value',
      'https://alltool.top.example.com/book/rank/latest?page=2',
    ]) {
      final page = parseAlltoolCatalogue(
        '<a href="$url" data-slot="next">Next Page</a>',
        alltoolCatalogueEndpoint,
      );
      expect(page.next, isNull);
    }
  });
}
