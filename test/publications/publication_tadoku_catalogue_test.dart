import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/publications/data/publication_tadoku_catalogue.dart';
import 'package:zero_player/features/publications/domain/publication.dart';

final _page = Uri.https('tadoku.org', '/japanese/book/2746/');
const _file = '/japanese/wp-content/uploads/w0001e-hanatoiro-v2.pdf';
const _license = 'https://creativecommons.org/licenses/by-nc-nd/4.0/';

void main() {
  test(
    'Tadoku listing extracts book links and removes pronunciation hints',
    () {
      final entries = parseTadokuListing('''
      <div id="freebooks-results">
        <div class="freebooks-book-item" data-level="l0">
          <div class="bl-title"><a href="/japanese/book/2746/">
            <ruby>花<rt>はな</rt></ruby>と<ruby>色<rt>いろ</rt></ruby></a></div>
        </div>
        <div class="freebooks-book-item">
          <div class="bl-title"><a href="https://elsewhere.org/japanese/book/1/">Outside origin</a></div>
        </div>
        <div class="freebooks-book-item">
          <div class="bl-title"><a href="/japanese/book/2/?other=1">Other query</a></div>
        </div>
      </div>
    ''');
      expect(entries.single.page, _page);
      expect(entries.single.title, '花と色');
      expect(entries.single.level, 'l0');
    },
  );

  test(
    'Tadoku offers the licensed electronic PDF and preserves attribution',
    () {
      final book = parseTadokuBook(_bookPage(), _page, level: 'l0')!;
      expect(book.title, '花と色');
      expect(book.author, '作：作田 奈苗');
      expect(book.license, 'CC BY-NC-ND 4.0');
      expect(book.edition, 'Level 0');
      final candidate = book.candidates.single;
      expect(candidate.format, PublicationFormat.pdf);
      expect(candidate.fileId, '2746');
      expect(candidate.page, _page);
      expect(candidate.link, _page.resolve(_file));
    },
  );

  test('Tadoku rejects files with missing or mismatched permission evidence', () {
    final pages = [
      _bookPage(license: 'https://example.org/'),
      _bookPage(canonical: '/japanese/book/42/'),
      _bookPage(link: 'https://elsewhere.org$_file'),
      _bookPage(link: '$_file?tracking=1'),
      _bookPage(link: '/japanese/wp-content/uploads/foo%2fbar.pdf'),
      _bookPage(download: ''),
      _bookPage(
        extra:
            '<a href="/japanese/wp-content/uploads/other.pdf" download>PDF(電子本)</a>',
      ),
    ];
    for (final input in pages) {
      expect(parseTadokuBook(input, _page), isNull);
    }
  });
}

String _bookPage({
  String canonical = '/japanese/book/2746/',
  String license = _license,
  String link = _file,
  String download = 'download',
  String extra = '',
}) =>
    '''
  <link rel="canonical" href="$canonical">
  <article id="post-2746" class="book type-book">
    <div class="bd-title"><h1><ruby>花<rt>はな</rt></ruby>と色</h1></div>
    <div class="bd-author"><ul><li>作：<ruby>作田<rt>さくた</rt></ruby> 奈苗</li></ul></div>
    <div class="bd-note"><a href="$license">CC BY-NC-ND 4.0</a></div>
    <div class="bd-lookinside-pdf">
      <a href="$link" $download>PDF(電子本)<span>｜PDF</span></a>
      <a href="/japanese/wp-content/uploads/print.pdf" download>PDF(印刷用)</a>
      $extra
    </div>
  </article>
''';
