import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/publications/data/publication_panda_html_catalogues.dart';
import 'package:zero_player/features/publications/data/publication_zulu_catalogue.dart';
import 'package:zero_player/features/publications/domain/publication.dart';

void main() {
  test('Shukui reads named bibliographic fields from same-site books', () {
    final page = parseShukuiCatalogue('''
      <header id="header"><input name="q"></header>
      <main id="main">
        <div class="cate-item"><div class="cate-info">
          <h2><a href="/book/123.html">示例<em>书</em></a></h2>
          <p>作者：示例作者</p><p>ISBN：9787560175362</p>
          <p>出版社：某地：示例出版社</p>
        </div></div>
        <div class="cate-item"><h2><a href="https://foreign.example/book/123.html">外站</a></h2></div>
        <div class="page-navi"><a class="next" href="?p=2">2</a></div>
      </main>
    ''');
    expect(page.hasNext, isTrue);
    final book = page.books.single;
    expect(book.title, '示例书');
    expect(book.author, '示例作者');
    expect(book.isbn, '9787560175362');
    expect(book.publisher, '某地：示例出版社');
  });

  test('Zulu validates both the book page and the exact file route', () {
    final page = Uri.parse('https://zulu-ebooks.com/belletristik/some-book');
    final books = parseZuluFiles('''
      <link rel="canonical" href="$page">
      <div class="z-ebook__formate">
        <a href="${page.path}/pdf">PDF</a>
        <a href="${page.path}/pdf/epub">EPUB</a>
        <a href="https://foreign.example${page.path}/pdf/mobi">MOBI</a>
        <a href="/belletristik/other-book/pdf/mobi">MOBI</a>
      </div>
    ''', page);
    expect(books.map((book) => book.format), [
      PublicationFormat.pdf,
      PublicationFormat.epub,
    ]);
  });
}
