import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/publications/data/publication_gallica_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_obp_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_obp_distribution.dart';
import 'package:zero_player/features/publications/domain/publication.dart';
import 'package:zero_player/features/publications/data/publication_sobooks_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_standard_ebooks_catalogue.dart';

void main() {
  test('Standard Ebooks follows only its same-file public refresh', () {
    final epub = Uri.https(
      'standardebooks.org',
      '/ebooks/a/b/downloads/a_b.epub',
    );
    final expected = epub.replace(queryParameters: {'source': 'download'});
    String page(Uri target) =>
        '<head><meta http-equiv="refresh" content="0; url=$target"></head>';
    expect(parseStandardEbooksDownloadPage(page(expected), epub), expected);
    expect(
      parseStandardEbooksDownloadPage(
        page(expected.replace(host: 'outside.test')),
        epub,
      ),
      isNull,
    );
    expect(
      parseStandardEbooksDownloadPage(
        page(expected.replace(path: '${epub.path}.zip')),
        epub,
      ),
      isNull,
    );
  });

  test(
    'BnF MARC separates formats using the official 856 digital identifiers',
    () {
      final page = parseGallicaCatalogue('''
<srw:searchRetrieveResponse xmlns:srw="http://www.loc.gov/zing/srw/"
                           xmlns:mxc="info:lc/xmlns/marcxchange-v2">
  <srw:numberOfRecords>10</srw:numberOfRecords><srw:nextRecordPosition>11</srw:nextRecordPosition>
  <srw:records><srw:record><srw:recordData>
    <mxc:record format="UNIMARC" type="Bibliographic">
      <mxc:datafield tag="200"><mxc:subfield code="a">Dépit amoureux</mxc:subfield></mxc:datafield>
      <mxc:datafield tag="700"><mxc:subfield code="a">Molière</mxc:subfield></mxc:datafield>
      <mxc:datafield tag="856"><mxc:subfield code="u">http://gallica.bnf.fr/ark:/12148/bpt6k9688417m</mxc:subfield></mxc:datafield>
      <mxc:datafield tag="856"><mxc:subfield code="u">https://gallica.bnf.fr/ark:/12148/bpt6k5797545n</mxc:subfield></mxc:datafield>
      <mxc:datafield tag="856"><mxc:subfield code="u">https://example.test/ark:/12148/bpt6k9688417m</mxc:subfield></mxc:datafield>
      <mxc:datafield tag="856"><mxc:subfield code="u">https://gallica.bnf.fr/ark:/12148/bpt6k9688417m/f1.pdf</mxc:subfield></mxc:datafield>
    </mxc:record>
  </srw:recordData></srw:record></srw:records>
</srw:searchRetrieveResponse>
''');
      expect(page.next, 11);
      expect(page.books.map((row) => row.id).toSet(), hasLength(2));
      expect(page.books.first.page?.scheme, 'https');
      expect(page.books.first.author, 'Molière');
      expect(page.books.expand((row) => row.candidates), isEmpty);
      expect(
        gallicaCatalogueQuery('Molière" or *'),
        contains('bib.title all "Molière or"'),
      );
    },
  );

  test(
    'Standard Ebooks binds a licensed compatible EPUB to the listed work',
    () {
      const path = '/ebooks/arthur-conan-doyle/sir-nigel';
      final page = Uri.https('standardebooks.org', path);
      final epub = page.replace(
        path: '$path/downloads/arthur-conan-doyle_sir-nigel.epub',
      );
      final editions = parseStandardEbooksFeed('''
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry><id>$page</id><title>Sir Nigel</title><author><name>Arthur Conan Doyle</name></author>
    <rights>Public domain in the United States. Creative Commons CC0 1.0.</rights>
    <link rel="enclosure" type="application/epub+zip" href="$epub?source=feed"/>
  </entry>
  <entry><id>https://standardebooks.org/ebooks/author/other</id><title>Other book</title>
    <rights>Public domain in the United States. Creative Commons CC0 1.0.</rights>
    <link rel="enclosure" type="application/epub+zip" href="$epub?source=feed"/>
  </entry>
</feed>
''');
      expect(editions.first.candidates.single.link, epub);
      expect(editions.last.candidates, isEmpty);
      expect(
        parseStandardEbooksDetails(
          _standardDetails(path, epub.toString()),
          page,
        ),
        epub,
      );
      expect(
        parseStandardEbooksDetails(
          _standardDetails(path, epub.replace(host: 'other.test').toString()),
          page,
        ),
        isNull,
      );
      expect(
        parseStandardEbooksDetails(
          _standardDetails(
            path,
            epub.toString(),
            license: 'https://example.test/',
          ),
          page,
        ),
        isNull,
      );
    },
  );

  test('Standard Ebooks uses the same work key for search and discovery', () {
    const path = '/ebooks/arthur-conan-doyle/sir-nigel';
    final rows = parseStandardEbooksSearch('''
<main><ol class="ebooks-list">
<li about="$path">
  <p><a property="schema:url" href="$path">Sir Nigel</a></p>
  <p class="author">Arthur Conan Doyle</p>
</li>
<li about="$path"><p><a property="schema:url" href="https://other.test$path">Other</a></p></li>
</ol></main>
''');
    expect(rows.single.matches('arthur conan doyle'), isTrue);
    expect(rows.single.page?.path, path);
  });

  test(
    'SoBooks exposes only same-site title records from its public cards',
    () {
      final books = parseSobooksCatalogue('''
<main>
  <div class="card-item"><h3><a href="/books/10.html">示例</a></h3>
    <p>作者</p><a href="https://downloads.test/a.pdf">下载</a>
  </div>
  <div class="card-item"><h3><a href="/search?q=fake">Other</a></h3></div>
  <div class="card-item"><h3><a href="https://other.test/books/10.html">Other</a></h3></div>
</main>
''');
      expect(books.single.matches('作者'), isTrue);
      expect(books.single.page, Uri.https('sobooks.cc', '/books/10.html'));
      expect(books.single.candidates, isEmpty);
    },
  );

  test('KBART retains both ISBNs and validates the registered publisher DOI', () {
    const header =
        'publication_title\tprint_identifier\tonline_identifier\ttitle_url\t'
        'title_id\tfirst_author\tfirst_editor\tpublisher_name\tpublication_type\t'
        'date_monograph_published_online\tmonograph_edition';
    const tail =
        '10.11647/OBP.0290\t\tNebel\tOpen Book Publishers\tMonograph\t2022\t1';
    const page = 'https://www.openbookpublishers.com/books/10.11647/obp.0290';
    const data =
        'A Common Good Approach to Development\t978-1-80064-404-5\t978-1-80064-406-9';
    final (book, printIsbn) = parseObpCatalogue(
      '$header\n$data\t$page\t$tail\n'
      '$data\t$page?key=x\t$tail\n',
    ).single;
    expect(book.page, Uri.parse(page));
    expect(book.matches('978-1-80064-406-9'), isTrue);
    expect(printIsbn, '9781800644045');
    expect(book.author, 'Nebel');
    expect(book.candidates, isEmpty);
  });

  test(
    'OBP only uses hosted copies bound to a publisher edition and licence',
    () {
      final work = Uri.https('unglue.it', '/work/136328/');
      final book = PublicationEdition(
        id: 'obp-book',
        title: 'The Classic Short Story',
        isbn: '9781909254770',
        page: Uri.https(
          'www.openbookpublishers.com',
          '/books/10.11647/obp.0039',
        ),
      );
      String details({
        String doi = '10.11647/OBP.0039',
        String isbn = '9781909254770',
      }) =>
          '''
        <meta property="og:url" content="$work">
        <a href="https://doi.org/$doi">$doi</a>
        <div class="editions"><div class="metadata">
          <a href="/pid/all/4639">Open Book Publishers</a>
          <span itemprop="isbn">$isbn</span>
        </div></div>
        ''';
      expect(confirmsObpDistributionEdition(details(), work, book), isTrue);
      expect(
        confirmsObpDistributionEdition(
          details(doi: '10.11647/OBP.0290'),
          work,
          book,
        ),
        isFalse,
      );
      expect(
        confirmsObpDistributionEdition(
          details(isbn: '9781909254756'),
          work,
          book,
        ),
        isFalse,
      );

      String file(String id, String label, String rights) =>
          '''
      <a href="/download_ebook/$id/"><img alt="$rights"></a>
      <a href="/download_ebook/$id/"><img alt="$label"></a>
      ''';
      final downloads =
          '''
      <h2><a href="${work.path}">The Classic Short Story</a></h2>
      <div class="ebook_download">
        ${file('2314', 'epub at Unglue.it', 'CC BY')}
        ${file('250369', 'pdf at Unglue.it', 'CC BY')}
        ${file('292053', 'pdf at OAPEN Library', 'CC BY')}
        ${file('2233', 'epub at Unglue.it', 'All rights reserved')}
      </div>
      ''';
      expect(
        parseObpHostedCopies(downloads, work).map((copy) => copy.link.path),
        ['/download_ebook/2314/', '/download_ebook/250369/'],
      );
      expect(
        parseObpHostedCopies(downloads, Uri.https('unglue.it', '/work/2/')),
        isEmpty,
      );
    },
  );
}

String _standardDetails(
  String path,
  String href, {
  String license = 'https://creativecommons.org/publicdomain/zero/1.0/',
}) =>
    '''
<article class="ebook" about="$path">
  <section id="read-free"><meta property="schema:license" content="$license">
    <section id="download"><a class="epub" href="$href">EPUB</a></section>
  </section>
</article>
''';
