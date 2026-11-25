import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/publications/data/publication_aisixiang_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_cadal_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_cnpereading_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_ebooklist_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_freemagazines_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_gujiguan_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_hep_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_huxiang_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_jb51_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_mit_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_modernhistory_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_panda_book_indexes.dart';
import 'package:zero_player/features/publications/data/publication_sciencereading_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_smartedu_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_tinynews_catalogue.dart';
import 'package:zero_player/features/publications/domain/publication.dart';

void main() {
  test(
    'Bundled book indexes retain scoped catalogue links and explicit bylines',
    () {
      final book = parsePandaBookIndex('''
      [{"id":"3193523","title":"墨子","author":"墨翟",
        "cover":"https://gbcloud-book.oss.zglibrary.com/4a898ab704e245ff85bbe10e448f5139.png"},
       {"id":"../other","title":"Invalid"}]
    ''', zglibrarySource).single;
      expect(book.author, '墨翟');
      expect(book.page?.path, '/detail/3193523');
      expect(book.cover?.host, 'gbcloud-book.oss.zglibrary.com');
      final comic = parsePandaBookIndex('''
      [{"id":"6635","title":"时间大师","page":"bbs-6635-1-163.html","author":"论坛用户"},
       {"id":"15","title":"Mismatch","page":"bbs-16-1-1.html"},
       {"id":"17","title":"Other host","page":"https://example.org/bbs-17-1-1.html"}]
    ''', kindleComicsSource).single;
      expect(comic.title, '时间大师');
      expect(comic.author, isEmpty);
      expect(comic.page?.path, '/bbs-6635-1-163.html');
      expect(comic.hasDownload, isFalse);
    },
  );

  test('HEP accepts only published records and scoped book covers', () {
    final row = {
      'Id': '1009712103705018368',
      'Title': '高等数学引论(第四册)',
      'Author': '华罗庚',
      'Isbn': '978-7-04-025840-0',
      'ObjectType': '53',
      'IsDeleted': '0',
      'IsOnShelf': '1',
      'CoverUrl':
          'https://hep-xueke-res.oss-cn-beijing.aliyuncs.com/files/upload/0de/0de0797a2c6d83d17ecf52984637f472.jpg',
    };
    final page = parseHepCatalogue(
      jsonEncode({
        'code': 200,
        'total': 3,
        'rows': [
          row,
          {...row, 'Id': '24', 'IsOnShelf': '0'},
          {...row, 'Id': '33', 'IsDeleted': '1'},
        ],
      }),
    );
    final book = page.books.single;
    expect(book.author, '华罗庚');
    expect(book.isbn, '9787040258400');
    expect(book.page?.fragment, '/detail?id=1009712103705018368');
    expect(isHepCover(book.cover!), isTrue);
    expect(
      isHepCover(book.cover!.replace(path: '/unrelated/images/book.jpg')),
      isFalse,
    );
  });

  test('Gujiguan scopes the browser search and retains ancient editions', () {
    final page = parseGujiguanCatalogue(
      jsonEncode({
        'code': 200,
        'data': {
          'page': 1,
          'pageCount': 2,
          'rows': [
            {
              'Book_Code': 58110,
              'Book_Name': '<em>红楼梦</em>',
              'Book_Duty': '曹雪芹撰',
              'Book_Vol': '一百二十回',
              'Book_Version': '刊本',
              'Book_Year': '嘉庆十六年',
            },
            {'Book_Code': 'https://other.example', 'Book_Name': 'Invalid'},
          ],
        },
      }),
    );
    final book = page.books.single;
    expect(book.author, '曹雪芹撰');
    expect(book.edition, '一百二十回 · 刊本 · 嘉庆十六年');
    expect(book.page?.origin, gujiguanHome.origin);
    final route = Uri.parse(book.page!.fragment);
    expect(route.path, '/search');
    expect(route.queryParameters['keyword'], '红楼梦');
    expect(page.hasNext, isTrue);
  });

  test(
    'Smart Education preserves published IDs and accepts public image hosts only',
    () {
      final entries = parseSmartEduCatalogue(
        jsonEncode([
          {
            'id': 'bdc00134-465d-454b-a541-dcd0cec4d86e',
            'type': 'assets_document',
            'title': '道德与法治一年级上册',
            'tags': ['统编版', '小学'],
            'cover':
                'https://r3-ndr.ykt.cbern.com.cn/edu_product/esp/assets/covers/1.jpg?v=1725014003021',
          },
          {
            'id': '1e04e52e-41df-4689-b12a-f3b7315a4243',
            'type': 'thematic_course',
            'title': '另一册',
            'cover':
                'https://r3-ndr-private.ykt.cbern.com.cn/edu_product/esp/assets/covers/1.jpg',
          },
          {'id': 'bad&next=1', 'type': 'assets_document', 'title': 'Invalid'},
        ]),
      );
      expect(entries.map((book) => book.title), ['道德与法治一年级上册', '另一册']);
      expect(
        entries.first.page?.queryParameters['contentId'],
        'bdc00134-465d-454b-a541-dcd0cec4d86e',
      );
      expect(entries.first.cover?.host, 'r3-ndr.ykt.cbern.com.cn');
      expect(entries.first.tags, ['统编版', '小学']);
      expect(entries.last.cover, isNull);
    },
  );

  test('Free Magazines accepts only issue-scoped published previews', () {
    final listing = parseFreeMagazinesCatalogue('''
      <main id="main"><article class="type-post status-publish">
        <div class="entry-title"><a rel="bookmark" href="/astronomy-november-2026">Astronomy – November 2026</a></div>
        <div class="post-image"><img class="wp-post-image" src="/wp-content/uploads/2026/11/astronomy.webp"></div>
      </article><nav class="paging-navigation"><a class="next page-numbers" href="/page/2?s=astronomy">Next</a></nav></main>
    ''');
    final issue = listing.books.single;
    expect(listing.hasNext, isTrue);
    expect(issue.cover?.path, '/wp-content/uploads/2026/11/astronomy.webp');
    final body =
        '''
      <link rel="canonical" href="${issue.page}">
      <a href="https://easyupload.us/outer1234/preview">Outside</a>
      <main id="main"><article class="type-post"><div class="entry-content">
        <a href="javascript:void(0)">Script</a>
        <a href="/bogus1234/preview">Relative</a>
        <a href="https://easyupload.us.example/sample123/preview">Other host</a>
        <a href="https://easyupload.us/sample123/preview">Download PDF</a>
      </div></article></main>
    ''';
    expect(
      parseFreeMagazinesResources(issue.page!, body).single.link,
      Uri.https('easyupload.us', '/sample123/preview'),
    );
    expect(
      () => parseFreeMagazinesResources(
        freeMagazinesHome.resolve('another-issue'),
        body,
      ),
      throwsA(isA<PublicationFailure>()),
    );
  });

  test('Aisixiang takes author names from the matching article byline', () {
    final listing = parseAisixiangCatalogue('''
      <div class="text_left"><div class="search_list"><div class="article-title">
        <a href="/data/140912.html" title="胡适：《红楼梦》考证">胡适：《红楼梦》考证</a>
      </div><a class="page-link" aria-label="Next" href="/data/search?page=2">2</a></div></div>
    ''');
    expect(listing.hasNext, isTrue);
    final row = listing.books.single;
    final article = confirmAisixiangArticle(row, '''
      <div class="text_left"><div class="show_text"><h3>胡适：《红楼梦》考证</h3>
        <div class="about">
          <div><div><strong>胡适</strong></div></div>
          <div class="article-content"><strong>正文</strong></div>
        </div>
      </div></div>
    ''');
    expect(article?.title, '《红楼梦》考证');
    expect(article?.author, '胡适');
    expect(confirmAisixiangArticle(row, '<h3>其他文章</h3>'), isNull);
  });

  test('Huxiang accepts list and search IDs and scopes covers to the source', () {
    final page = parseHuxiangCatalogue(
      jsonEncode({
        'code': 200,
        'total': 2,
        'rows': [
          {
            'bookId': '1949724968494297089',
            'title': '湖湘文化辞典 一',
            'author': '万里 主编',
            'coverUrl':
                '/filepublic/2025/08/19/f259776209fa40d88c3d12de4a9e7ecb.jpg',
          },
          {
            'id': '1949742349987868673',
            'title': '湖湘文化辞典 八',
            'coverUrl':
                'https://unrelated.example/filepublic/2025/08/19/f259776209fa40d88c3d12de4a9e7ecb.jpg',
          },
          {'id': 'id/1', 'title': 'Invalid'},
        ],
      }),
    );
    expect(page.hasNext, isFalse);
    expect(page.books.map((book) => book.page?.path), [
      '/book/1949724968494297089',
      '/book/1949742349987868673',
    ]);
    expect(page.books.first.author, '万里 主编');
    expect(page.books.first.cover?.host, 'www.huxiangwenku.cn');
    expect(page.books.last.cover, isNull);
  });

  test(
    'CADAL indexes an official book detail for a grouped catalogue result',
    () {
      final page = parseCadalCatalogue('''
      <div class="resultList"><ul class="results-list">
        <li><div class="imgBox"><img src="/cx/png/image/cover?p=02/111849/otiff/00000001.jpg&amp;ds=1&amp;a=17f5329c97f0f915c0b7b42c24d9959f"></div>
          <dl><dt><a class="title" onclick="changeAggregation('hj02111849','古籍')">
            <font>紅</font>樓夢</a></dt><dd>作者：曹雪芹撰</dd></dl></li>
        <li><dl><dt><a class="title" onclick="audioCardPageGo('02111849','card')">Audio</a></dt></dl></li>
        <li><dl><dt><a class="title" onclick="bookCardPageGo('not-a-book','card')">Invalid</a></dt></dl></li>
      </ul></div>
      <div class="pagination"><a class="active">1</a>
        <a id="lastPage" href="/cadalinfo/search?currentPage=2">2</a></div>
    ''');
      final book = page.books.single;
      expect(book.title, '紅樓夢');
      expect(book.author, '曹雪芹撰');
      expect(book.edition, '代表馆藏');
      expect(book.page?.queryParameters['ssno'], '02111849');
      expect(book.cover?.host, 'cadal.edu.cn');
      expect(page.hasNext, isTrue);
      expect(book.hasDownload, isFalse);
    },
  );

  test('CNPE retains public book metadata and the official cover route', () {
    const id = '955fd28ba9f94805ae52cc51f82226f1';
    final page = parseCnpereadingCatalogue(
      jsonEncode({
        'currentPage': 1,
        'perPageRows': 20,
        'numberFound': 21,
        'records': [
          {
            'contentId': id,
            'productType': '1',
            'show': true,
            'contentTitle': '<label>寻找</label>属于自己的句子——陈忠实自述',
            'contentAuthor': '<label>陈忠实</label>著',
            'publisherName': '北京大学出版社',
            'contentCover':
                '/meta/cover/46c0/BK0f22cd46c0/BK0f22cd46c0.jpg?v=123',
            'SISBN': '9787301284001',
          },
          {
            'contentId': id,
            'productType': '1',
            'show': false,
            'contentTitle': 'Hidden',
          },
          {
            'contentId': id,
            'productType': '2',
            'show': true,
            'contentTitle': 'Non-book',
          },
          {
            'contentId': '../other',
            'productType': '1',
            'show': true,
            'contentTitle': 'Invalid',
          },
        ],
      }),
    );
    final book = page.books.single;
    expect(page.hasNext, isTrue);
    expect(book.title, '寻找属于自己的句子——陈忠实自述');
    expect(book.author, '陈忠实著');
    expect(book.isbn, '9787301284001');
    expect(book.page, cnpereadingHome.resolve('bookDetail/$id'));
    expect(
      book.cover?.path,
      '/source/meta/cover/46c0/BK0f22cd46c0/BK0f22cd46c0.jpg',
    );
    expect(book.cover?.hasQuery, isFalse);
    expect(book.hasDownload, isFalse);
  });

  test('JB51 uses the selected book’s published share links', () {
    final book = parseJb51Index('''
      [{"id":"846650","title":"Python 编程","author":"Eric Matthes",
        "cover":"https://img.jbzj.com/do/uploads/litimg/python.jpg"},
       {"id":"../other","title":"Invalid"}]
    ''').single;
    expect(book.author, 'Eric Matthes');
    expect(book.cover?.host, 'img.jbzj.com');
    final page = book.page!;
    final body =
        '''
      <link rel="canonical" href="$page">
      <a href="https://pan.baidu.com/s/outsideArea">Outside the download list</a>
      <div id="download"><ul class="ul_Address">
        <li><a href="https://pan.baidu.com/s/exactShare">Download</a></li>
        <li><a href="https://pan.baidu.com/s/exactShare">Same share</a></li>
        <li><a href="https://pan.baidu.com.example/s/otherShare">Other site</a></li>
        <li><a href="javascript:;">On-site interaction</a></li>
      </ul></div>
    ''';
    final share = parseJb51Resources(page, body).single;
    expect(share.link, Uri.https('pan.baidu.com', '/s/exactShare'));
    expect(
      () => parseJb51Resources(jb51Home.resolve('9885.html'), body),
      throwsA(isA<PublicationFailure>()),
    );
  });

  test('MIT OCW ties downloadable resources to the selected course', () {
    final page = parseMitOcwCatalogue(
      jsonEncode({
        'results': [
          {
            'title': 'Linear Algebra',
            'url': 'https://ocw.mit.edu/courses/linear-algebra/',
            'published': true,
            'resource_type': 'course',
            'platform': {'code': 'ocw'},
            'runs': [
              {
                'semester': 'Fall',
                'year': 2011,
                'instructors': [
                  {'full_name': 'Gilbert Strang'},
                ],
              },
            ],
          },
        ],
        'next': 'https://unrelated.example/ignored',
      }),
    );
    expect(page.hasNext, isTrue);
    final book = page.books.single;
    expect(book.author, 'Gilbert Strang');
    expect(book.edition, 'Fall 2011');
    expect(book.resources.single.link, book.page);
    final resources = parseMitOcwResources(book.page!, '''
      <div class="resource-item">
        <a href="/courses/linear-algebra/note%20set.pdf">download PDF</a>
        <a href="/courses/linear-algebra/unsafe%2Ffile.pdf">different path</a>
        <a href="/courses/other/file.pdf">other course</a>
        <a href="https://unrelated.example/courses/linear-algebra/file.pdf">other host</a>
        <a class="resource-list-title" href="/courses/linear-algebra/resources/note/">Lecture notes</a>
      </div>
    ''');
    expect(resources.single.label, 'Lecture notes');
    expect(resources.single.link.pathSegments.last, 'note set.pdf');
    expect(resources.single.format, PublicationFormat.pdf);
  });

  test(
    'Modern History strips highlights and uses the official detail route',
    () {
      final page = parseModernHistoryCatalogue(
        jsonEncode({
          'code': '200',
          'result': {
            'dataList': [
              {
                'fileCode': '9999_ts_08061734',
                'docType': 'ts',
                'originalTitle': '大众集',
                'firstResponsible': ['<em>邹</em><em>韬</em><em>奋</em>'],
              },
              {
                'fileCode': '9999_qk_06021',
                'docType': 'qk',
                'title': '全民<em>抗战</em>',
              },
              {'fileCode': 'bad&next=1', 'docType': 'ts', 'title': 'Bad'},
              {'fileCode': '9999_sp_21', 'docType': 'sp', 'title': 'Video'},
            ],
          },
        }),
      );
      expect(page.books.first.author, '邹韬奋');
      expect(page.books.last.title, '全民抗战');
      expect(page.books.map((book) => book.page!.fragment), [
        '/DocumentDetails_ts_da?fileCode=9999_ts_08061734',
        '/DocumentDetails_qk?fileCode=9999_qk_06021',
      ]);
      expect(page.books.expand((book) => book.candidates), isEmpty);
    },
  );

  test(
    'Tinynews replaces indexed aliases only with verified canonical details',
    () {
      final row = parseTinynewsListing('''
      <input id="ibox">
      <div class="card">
        <div class="card-body"><a href="/books/db_26591661">
          <div class="card-title">国家神道与日本人</div>
        </a></div>
      </div>
    ''').books.single;
      expect(row.page!.path, '/books/26591661');
      expect(
        confirmTinynewsBook(row, '<link rel="canonical" href="/">'),
        isNull,
      );
      final verified = confirmTinynewsBook(row, '''
      <link rel="canonical" href="${row.page}">
      <div class="col-md-8">
        <h1>国家神道与日本人 epub 电子书 下载</h1>
        <div><span style="background-color:#EBEEF3"><a>简体网页</a></span></div>
        <div><span style="background-color:#EBEEF3">岛薗进</span></div>
      </div>
    ''');
      expect(verified?.author, '岛薗进');
      expect(verified?.resources, isEmpty);
    },
  );

  test('EbookList keeps published shares only for the requested free book', () {
    String payload(bool paid) => jsonEncode([
      {'data': 1},
      ['ShallowReactive', 2],
      {'book-141': 3},
      {'id': 4, 'isPaid': 5, 'netDiskLinks': 6},
      141,
      paid,
      [7, 11],
      {'url': 8, 'password': 9, 'fileFormat': 10},
      'https://pan.quark.cn/s/fake1234',
      'AB12',
      'epub',
      {'url': 12},
      'https://other.example/s/fake1234',
    ]);
    final resource = parseEbookListResources(payload(false), 141).single;
    expect(resource.canListFiles, isTrue);
    expect(resource.code, 'AB12');
    expect(resource.format, PublicationFormat.epub);
    expect(parseEbookListResources(payload(true), 141), isEmpty);
    expect(
      () => parseEbookListResources(payload(false), 142),
      throwsA(isA<PublicationFailure>()),
    );
  });

  test('Science Reading ties the cover and credits to one official book', () {
    const id = 'B42D4A3503B1111A0E063010B0A0AC44E000';
    final listing = parseScienceReadingCatalogue('''
      <form id="bookListForm">
        <input name="showQueryModel.nameIsbnAuthor">
        <div class="book_content">
          <div class="book_detail_title">
            <a href="/shop/book/Booksimple/show.do?id=$id">
              <b class="kc_title">认识数学 4</b>
            </a>
          </div>
          <span class="kc_author">席南华 主编</span>
          <span class="kc_ISBN">9787030832030</span>
          <img src="/kxwk4/bookImages/$id/cover.jpg" alt="">
        </div>
        <div class="pagination"><a onclick="nextPage();">下一页</a></div>
      </form>
    ''');
    final book = listing.books.single;
    expect(listing.hasNext, isTrue);
    expect(book.author, '席南华 主编');
    expect(book.isbn, '9787030832030');
    expect(book.page!.queryParameters['id'], id);
    expect(book.cover!.host, book.page!.host);
  });
}
