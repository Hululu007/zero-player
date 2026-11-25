import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/publications/data/publication_panda_book_sites.dart';

void main() {
  test(
    'Taoshudang preserves an inner book title and reads the author credit',
    () {
      final result = parseTaoshudangCatalogue('''
      <form><input name="s"></form>
      <div id="content">
        <article><h2 class="entry-title">
          <a href="/32038.html">《《红楼梦》索隐（套装共3册）》隋邦森&amp;隋海鹰（作者）-epub+mobi+azw3</a>
        </h2></article>
        <article><h2 class="entry-title">
          <a href="/39034.html">站点公告</a>
        </h2></article>
      </div>
      <a class="next page-numbers" href="/page/2/">下一页</a>
    ''');
      expect(result.hasNext, isTrue);
      expect(result.books.single.title, '《红楼梦》索隐（套装共3册）');
      expect(result.books.single.author, '隋邦森&隋海鹰');
    },
  );

  test('Huiyankan homepage and search recognise the same book detail', () {
    final home = parseHuiyankanHomepage('''
      <form><input name="s"></form>
      <main id="main">
        <article class="type-post"><h2 class="entry-title">
          <a href="/202512200842457.html" rel="bookmark">斯通纳三部曲</a>
        </h2></article>
        <article class="type-post"><h2 class="entry-title">
          <a href="https://example.com/202512200842457.html" rel="bookmark">其他链接</a>
        </h2></article>
      </main>
    ''');
    final search = parseHuiyankanCatalogue('''
      [{"link":"https://www.huiyankan.com/202512200842457.html",
        "title":{"rendered":"斯通纳三部曲"}}]
    ''');
    expect(home.books.single.id, search.books.single.id);
    expect(search.books.single.title, '斯通纳三部曲');
  });

  test('Klib uses the verified book host and HTTPS', () {
    final book = parseKlibRankingCatalogue('''
      <li class="fcm68">
        <a class="fcm69" href="http://s.klib.me/695233.html"></a>
        <p class="book_title">三体（全集）</p><p class="book_author">刘慈欣</p>
      </li>
      <li class="fcm68">
        <a class="fcm69" href="http://elsewhere.example/695233.html"></a>
        <p class="book_title">其他</p>
      </li>
    ''').books.single;
    expect(book.author, '刘慈欣');
    expect(book.page.toString(), 'https://s.klib.me/695233.html');
  });
}
