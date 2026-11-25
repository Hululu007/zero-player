import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/features/publications/data/publication_cdstm_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/data/publication_klib_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_oalib_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_panda_classics.dart';
import 'package:zero_player/features/publications/data/publication_panda_companions.dart';
import 'package:zero_player/features/publications/data/publication_panda_publishers.dart';
import 'package:zero_player/features/publications/data/publication_panda_wordpress.dart';
import 'package:zero_player/features/publications/data/publication_pingshu_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_qianqiu_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_shidian_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_vorleser_catalogue.dart';
import 'package:zero_player/features/publications/domain/publication.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'OALib keeps article authors and only recognized publisher PDF routes',
    () {
      final listing = parseOalibCatalogue('''
      <input name="kw" placeholder="Search OALib Journal Articles">
      <div class="paperlist">
        <p><a href="http://www.scirp.org/journal/PaperDownload.aspx?paperID=154727"><i class="oagr">Open Access</i></a></p>
        <h3><a href="//www.oalib.com/articles/6906930">Equilibrium Current Dynamics</a></h3>
        <h5><a href="../search?kw=Author&searchField=authors">Author Name</a></h5>
      </div>
      <div class="paperlist">
        <p><a href="https://unrelated.example/a.pdf"><i class="oagr">Open Access</i></a></p>
        <h3><a href="/articles/6906931">Unverified PDF</a></h3>
      </div>
    ''');
      final book = listing.books.first;
      expect(book.author, 'Author Name');
      expect(
        book.candidates.single.link.toString(),
        'https://www.scirp.org/journal/PaperDownload.aspx?paperID=154727',
      );
      expect(listing.books.last.candidates, isEmpty);
    },
  );

  test(
    'Bookln selects official book records and pagination from nested JSON',
    () {
      final listing = parseBooklnCatalogue(r'''
      {"success":true,"data":"{\"currentPage\":1,\"totalPages\":2,\"pageData\":[{\"id\":692694,\"idSign\":\"1fbf9a\",\"name\":\"Python程序设计基础\",\"author\":\"宣继涛\",\"publisher\":\"电子社\"}]}"}
    ''');
      expect(listing.hasNext, isTrue);
      final book = listing.books.single;
      expect(book.author, '宣继涛');
      expect(book.page?.path, '/books/bookDetails');
      expect(book.page?.queryParameters, {'id': '692694', 'idSign': '1fbf9a'});
    },
  );

  test('Shuzhou retains only reviewed published share addresses', () {
    final listing = parseShuzhouCatalogue(r'''
      [
        {"title":"《斯通纳》约翰·威廉斯/epub+mobi","url":"https://fast8com.pipipan.com/fs/16058819-365252431"},
        {"title":"《三体全集》刘慈欣/epub+mobi+azw3","url":"https://url81.ctfile.com/d/41266081-53392461-85b4f4?p=7199"},
        {"title":"《三体全集》刘慈欣/epub","url":"https://url81.ctfile.com/d/41266081-53392461-85b4f4?p=7199&next=bad"},
        {"title":"《假资源》","url":"https://unrelated.example/book.epub"}
      ]
    ''');
    expect(listing.books.map((b) => b.title), ['斯通纳', '三体全集']);
    expect(listing.books.first.author, '约翰·威廉斯');
    expect(
      listing.books.first.resources.single.link.host,
      'fast8com.ctfile.com',
    );
    expect(listing.books.last.resources.single.code, '7199');
  });

  test('Qianqiu only collects published guest buttons with book formats', () {
    final links = parseQianqiuShares('''
      <div class="ordown-buy">
        <a class="ordown-button" href="https://a56666.ctfile.com/fs/12213659-327935776">epub下载</a>
        <a class="ordown-button" href="https://a56666.ctfile.com/fs/12213659-327935772">azw3下载</a>
        <a class="ordown-button" href="https://a56666.ctfile.com/fs/1-1">exe下载</a>
        <a class="ordown-button" href="https://unrelated.example/s/example">epub下载</a>
      </div>
    ''');
    expect(links.map((link) => link.format), [
      PublicationFormat.epub,
      PublicationFormat.azw3,
    ]);
  });

  test(
    'Hanji indexes the official credit, version and original reader',
    () async {
      final transport = MediaHttpClient();
      addTearDown(transport.close);
      final source = hanjiCatalogue(
        PublicationHttp(transport, authorize: (_) {}),
      );
      final results = await source.search(
        '張元忭',
        CancellationToken(),
        maxPages: 1,
        allowed: (_) => true,
        filter: PublicationFieldSearch(PublicationSearchField.author, '張元忭'),
      );
      final record = results.singleWhere((book) => book.title == '雲門志略');
      expect(record.author, contains('張元忭'));
      expect(record.edition, contains('明刊本'));
      expect(
        record.page.toString(),
        'https://hanchi.ihp.sinica.edu.tw/ihpc/hanjieb?32mhEwpp8',
      );
    },
  );

  test('Hina indexes named books from the official product sitemap', () async {
    final transport = MediaHttpClient();
    addTearDown(transport.close);
    final source = HinabookCatalogue(
      PublicationHttp(transport, authorize: (_) {}),
    );
    final rows = await source.search(
      '棉花帝国',
      CancellationToken(),
      maxPages: 1,
      allowed: (_) => true,
      filter: PublicationFieldSearch(PublicationSearchField.title, '棉花帝国'),
    );
    expect(rows.single.page?.pathSegments, ['product-page', '棉花帝国']);
    expect(rows.single.cover?.host, 'static.wixstatic.com');
    expect(rows.single.author, isEmpty);
  });

  test('Pingshu keeps the credited author separate from the narrator', () {
    final result = parsePingshu365Catalogue('''
      <form name="searchform"><input name="keyword"></form>
      <div class="book">
        <div class="pic"><img src="/pic/2013613230419.jpg"></div>
        <div class="text">
          <p><span><a href="/ps/3092.html">三国演义(365回)</a></span></p>
          <ul><li>播讲：袁阔成</li><li>作者：罗贯中</li></ul>
        </div>
      </div>
      <a href="1.asp?page=2">下一页</a>
    ''');
    expect(result.books.single.author, '罗贯中');
    expect(result.books.single.description, '播讲 袁阔成');
    expect(result.books.single.page?.path, '/ps/3092.html');
    expect(result.hasNext, isTrue);
  });

  test('361 strips the file label and extracts repeated credited names', () {
    final result = parseLibrary361Catalogue('''
      <input name="s">
      <main>
        <article class="post-item">
          <h2 class="entry-title"><a href="/82086.html">红楼梦-(清)曹雪芹（(清)曹雪芹）（EPUB电子书）</a></h2>
        </article>
        <article class="post-item">
          <h2 class="entry-title"><a href="/992.html">其他文章</a></h2>
          <div class="entry-cat-dot"><a href="https://unrelated.example/freebook">免费图书馆</a></div>
        </article>
      </main>
    ''');
    expect(result.books.single.title, '红楼梦');
    expect(result.books.single.author, '(清)曹雪芹');
  });

  test('Shidian deduplicates matched books and keeps alternate titles', () {
    final result = parseShidianCatalogue(r'''
      <script>
      window._ROUTER_DATA = {"loaderData":{"__session/(lang$)/search.(query$)/page":{
      "data":{"recommendBooks":{"books":[{"bookId":"GY025","bookName":"石頭記",
      "addNames":["紅樓夢"],"authors":[{"persName":"曹雪芹"}],
      "edition":{"edition":"程甲本"},"beautifulCover":"https://unrelated.example/image.png"}]},
      "paragraphs":[{"bookInfo":{"bookId":"GY025","bookName":"石頭記",
      "addNames":[],"authors":[],"edition":{},"beautifulCover":null}}]}}}}
      </script>
    ''');
    expect(result.books.single.title, '石頭記（紅樓夢）');
    expect(result.books.single.author, '曹雪芹');
    expect(result.books.single.edition, '程甲本');
    expect(result.books.single.page?.path, '/zh/book/GY025');
    expect(result.books.single.cover, isNull);
  });

  test('Vorleser recognizes homepage cards and their same-origin covers', () {
    final result = parseVorleserCatalogue('''
      <form action="/suche"><input type="search"></form>
      <main>
        <article class="audiobook">
          <header class="audiobook__header">
            <div class="title"><a href="/hoerbuch/angst?pop=1">Angst</a></div>
            <p class="author">Stefan Zweig</p>
          </header>
          <div class="audiobook-cover">
            <img src="fileadmin/_processed_/files_user/5/0/angst.jpg">
          </div>
        </article>
        <article class="audiobook">
          <header class="audiobook__header">
            <div class="title">
              <a href="https://other.example/hoerbuch/angst?pop=1">Angst</a>
            </div>
          </header>
        </article>
      </main>
    ''');
    final book = result.books.single;
    expect(book.title, 'Angst');
    expect(book.author, 'Stefan Zweig');
    expect(book.page.toString(), 'https://www.vorleser.net/hoerbuch/angst');
    expect(
      book.cover.toString(),
      'https://www.vorleser.net/fileadmin/_processed_/files_user/5/0/angst.jpg',
    );
  });

  test('CBETA index returns source credits and an official reader', () async {
    final transport = MediaHttpClient();
    addTearDown(transport.close);
    final source = cbetaCatalogue(
      PublicationHttp(transport, authorize: (_) {}),
    );
    final rows = await source.search(
      '金刚般若波罗蜜经',
      CancellationToken(),
      maxPages: 3,
      allowed: (_) => true,
    );
    final book = rows.firstWhere((book) => book.page?.path == '/zh/T0235');
    expect(book.title, '金剛般若波羅蜜經');
    expect(book.author, '鳩摩羅什');
    expect(book.page?.host, 'cbetaonline.dila.edu.tw');
  });

  test(
    'CText index returns the source record and official link resolver',
    () async {
      final transport = MediaHttpClient();
      addTearDown(transport.close);
      final source = ctextCatalogue(
        PublicationHttp(transport, authorize: (_) {}),
      );
      final rows = await source.search(
        '论语',
        CancellationToken(),
        maxPages: 1,
        allowed: (_) => true,
      );
      final book = rows.first;
      expect(book.title, '論語');
      expect(book.page?.host, 'api.ctext.org');
      expect(book.page?.queryParameters, {
        'if': 'zh',
        'urn': 'ctp:analects',
        'redirect': '1',
      });
    },
  );
  test(
    'Klib snapshot searches the published ranking and keeps the book link',
    () async {
      final transport = MediaHttpClient();
      addTearDown(transport.close);
      final source = KlibRankingCatalogue(
        PublicationHttp(transport, authorize: (_) {}),
      );
      final books = await source.search(
        '刘慈欣',
        CancellationToken(),
        maxPages: 2,
        allowed: (_) => true,
        filter: PublicationFieldSearch(PublicationSearchField.author, '刘慈欣'),
      );
      expect(books.first.title, '三体（全集）');
      expect(books.first.page.toString(), 'https://s.klib.me/695233.html');
      expect(books.every((book) => book.author.contains('刘慈欣')), isTrue);
    },
  );

  test('Daizhige indexes book titles and explicit author credits', () async {
    final transport = MediaHttpClient();
    addTearDown(transport.close);
    final source = daizhigeCatalogue(
      PublicationHttp(transport, authorize: (_) {}),
    );
    final token = CancellationToken();
    final books = await source.search(
      '宋史',
      token,
      maxPages: 2,
      allowed: (_) => true,
      filter: PublicationFieldSearch(PublicationSearchField.title, '宋史'),
    );
    final history = books.singleWhere((book) => book.title == '宋史');
    expect(history.page!.pathSegments, ['史藏', '正史', '宋史.html']);
    final credits = await source.search(
      '河上公',
      token,
      maxPages: 2,
      allowed: (_) => true,
      filter: PublicationFieldSearch(PublicationSearchField.author, '河上公'),
    );
    expect(credits.single.author, '河上公');
    expect(credits.single.page!.host, 'daizhige.org');
    expect(daizhigeReader('集藏/../outside.html'), isNull);
  });

  test(
    'Shiren searches multiple directories and scopes its published PDF',
    () async {
      final transport = MediaHttpClient();
      addTearDown(transport.close);
      final catalogue = ShirenCatalogue(
        PublicationHttp(transport, authorize: (_) {}),
      );
      final token = CancellationToken();
      for (final (query, path) in [
        ('李白', '/shiku/gs/libai.htm'),
        ('海子', '/shiku/xs/haizi.htm'),
        ('André Breton', '/shiku/ws/ww/breton.htm'),
      ]) {
        final records = await catalogue.search(
          query,
          token,
          maxPages: 3,
          allowed: (_) => true,
          filter: PublicationFieldSearch(PublicationSearchField.author, query),
        );
        expect(records.any((book) => book.page?.path == path), isTrue);
      }
      final books = await catalogue.search(
        '中国现代主义诗群大观',
        token,
        maxPages: 2,
        allowed: (_) => true,
      );
      final pdf = books
          .singleWhere((book) => book.page?.path == '/shiku/xs/xz/1986.pdf')
          .candidates
          .single;
      expect(pdf.format, PublicationFormat.pdf);
      expect((await catalogue.download(pdf, token)).uri, pdf.link);
      final unknown = pdf.link.resolve('unlisted.pdf');
      await expectLater(
        catalogue.download(
          AcquisitionCandidate(
            source: pdf.source,
            link: unknown,
            page: unknown,
            format: PublicationFormat.pdf,
          ),
          token,
        ),
        throwsA(isA<PublicationFailure>()),
      );
    },
  );

  test('Science museum indexes published ISBNs across collections', () async {
    final transport = MediaHttpClient();
    addTearDown(transport.close);
    final catalogue = CdstmCatalogue(
      PublicationHttp(transport, authorize: (_) {}),
    );
    final token = CancellationToken();
    final title = await catalogue.search(
      '植物',
      token,
      maxPages: 2,
      allowed: (_) => true,
    );
    expect(title.any((book) => book.title == '博士带你玩——植物'), isTrue);
    const isbn = '9787110101537';
    final entries = await catalogue.search(
      isbn,
      token,
      maxPages: 2,
      allowed: (_) => true,
      filter: PublicationFieldSearch(PublicationSearchField.isbn, isbn),
    );
    final book = entries.single;
    expect(book.title, '华夏之光：中国古代天文');
    expect(book.author, contains('赵洋'));
    final pdf = book.candidates.single;
    expect((await catalogue.download(pdf, token)).uri, pdf.link);
    expect(pdf.link.path, '/h5/jzrm/20210219hxzgzggdtw.pdf');
  });
}
