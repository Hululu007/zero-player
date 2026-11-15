import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/data/legado/legado_worker.dart';
import 'package:zero_player/features/books/domain/book.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _importTest();
  _imageRuleTest();
  _imageReplacementRuleTest();
  _mappedSourceTest();
  _xinmanhuaTest();
  _manmanVariantsTest();
}

void _manmanVariantsTest() {
  test('older Manman variants retain the mapped search and image CDN', () async {
    for (final contentRule in ['class.man_img@html', '.man_img@html']) {
      final source = parseBookSourceRecord({
        'bookSourceName': '漫漫漫画旧规则',
        'bookSourceUrl': 'https://www.manmanapp.com',
        'bookSourceType': 2,
        'searchUrl': 'https://www.manmanapp.com/search/word-{{key}}.html',
        'ruleSearch': {
          'bookList': 'class.classification',
          'name': 'class.title@text',
          'bookUrl': 'tag.a.0@href',
        },
        'ruleToc': {
          'chapterList': r'$.data',
          'chapterName': r'$.title',
          'chapterUrl': r'https://www.manmanapp.com/comic/detail-{{$.id}}.html',
        },
        'ruleContent': {'content': contentRule},
      });
      for (final current in [source, BookSource.fromJson(source.toJson())]) {
        expect(
          current.legado!.search,
          'https://www.manmanapp.com/search/index.html?keyword={{key}}',
        );
        expect(current.mediaHosts, contains('images.tmanga.com'));
        final result = await runLegadoJob(
          LegadoJob(
            current,
            Uri.parse('https://www.manmanapp.com/comic/detail-1572470.html'),
            LegadoOperation.images,
            input:
                '<div><img class="man_img" src="https://images.tmanga.com/comic/small/1.jpg-cs1080"></div>',
          ),
          CancellationToken(),
        );
        expect(result.links, [
          'https://images.tmanga.com/comic/small/1.jpg-cs1080',
        ], reason: contentRule);
      }
    }
  });
}

void _xinmanhuaTest() {
  test('Xinmanhua chapter JSON yields HTTPS images on its declared CDN', () async {
    final source = parseBookSourceRecord({
      'bookSourceName': '🎨新漫画',
      'bookSourceUrl': 'https://xapi.xinmanhua.net',
      'bookSourceType': 2,
      'searchUrl':
          'https://xapi.xinmanhua.net/search/selfdefine?keyword={{key}}',
      'ruleSearch': {
        'bookList': r'$.data.*',
        'name': r'$.attributes.title',
        'bookUrl':
            r'https://xapi.xinmanhua.net/worksinfos/{$.attributes.wid}?include=chapters.digests',
      },
      'ruleToc': {
        'chapterList': r'$.included.*',
        'chapterName': r'$.attributes.title&&$.attributes.intro',
        'chapterUrl': r'https://xapi.xinmanhua.net/chapters/{$.id}/qualitywebs',
      },
      'ruleContent': {
        'content': r'''$.data[*].attributes.url
@js:list=result.split('\n');
list.map(x=>'<img src="'+x+'">').join('\n')''',
      },
    });
    for (final current in [source, BookSource.fromJson(source.toJson())]) {
      expect(current.legado!.rules['content'], r'$.data[*].attributes.url');
      expect(current.mediaHosts, contains('works.xinmanhua.net'));
      expect(
        () => current.resolve(
          current.endpoint,
          'https://other.example.test/page.jpg',
          media: true,
        ),
        throwsFormatException,
      );
      final result = await runLegadoJob(
        LegadoJob(
          current,
          Uri.parse('https://xapi.xinmanhua.net/chapters/4801/qualitywebs'),
          LegadoOperation.images,
          input:
              '{"data":[{"attributes":{"url":"http://works.xinmanhua.net/338860339/2/w/1.jpg"}},{"attributes":{"url":"http://works.xinmanhua.net/338860339/2/w/2.jpg"}}]}',
        ),
        CancellationToken(),
      );
      expect(result.links, hasLength(2));
      expect(
        result.links.map(
          (link) => current
              .resolve(
                Uri.parse(
                  'https://xapi.xinmanhua.net/chapters/4801/qualitywebs',
                ),
                link,
                media: true,
              )
              .toString(),
        ),
        [
          'https://works.xinmanhua.net/338860339/2/w/1.jpg',
          'https://works.xinmanhua.net/338860339/2/w/2.jpg',
        ],
      );
    }
  });
}

void _importTest() {
  test('comic source imports with its own kind and preserves media hosts', () {
    final source = parseBookSourceRecord({
      'bookSourceName': '漫画样本',
      'bookSourceUrl': 'https://comic.example.test',
      'bookSourceType': 2,
      'searchUrl': '/search?key={{key}}',
      'mediaHosts': ['images.example.test'],
      'ruleSearch': {
        'bookList': '.book',
        'name': '.name@text',
        'bookUrl': 'a@href',
      },
      'ruleToc': {
        'chapterList': '.chapter',
        'chapterName': 'a@text',
        'chapterUrl': 'a@href',
      },
      'ruleContent': {'content': '.pages'},
    });
    expect(source.kind, BookKind.comic);
    expect(source.mediaHosts, contains('images.example.test'));
    expect(BookSource.fromJson(source.toJson()).kind, BookKind.comic);
  });
}

void _imageRuleTest() {
  test('comic content rule extracts lazy image addresses in order', () async {
    final source = parseBookSourceRecord({
      'bookSourceName': '漫画样本',
      'bookSourceUrl': 'https://comic.example.test',
      'bookSourceType': 2,
      'searchUrl': '/search?key={{key}}',
      'ruleSearch': {
        'bookList': '.book',
        'name': '.name@text',
        'bookUrl': 'a@href',
      },
      'ruleToc': {
        'chapterList': '.chapter',
        'chapterName': 'a@text',
        'chapterUrl': 'a@href',
      },
      'ruleContent': {'content': '.pages'},
    });
    final result = await runLegadoJob(
      LegadoJob(
        source,
        Uri.parse('https://comic.example.test/chapter'),
        LegadoOperation.images,
        input:
            '<div class="pages"><img data-src="/1.jpg"><img src="/2.jpg"><img src="/1.jpg"></div>',
      ),
      CancellationToken(),
    );
    expect(result.links, ['/1.jpg', '/2.jpg']);
  });

  test('img @html rule reads the selected image element', () async {
    final source = parseBookSourceRecord({
      'bookSourceName': '图片元素规则',
      'bookSourceUrl': 'https://comic.example.test',
      'bookSourceType': 2,
      'searchUrl': '/search?key={{key}}',
      'ruleSearch': {
        'bookList': '.book',
        'name': '.name@text',
        'bookUrl': 'a@href',
      },
      'ruleToc': {
        'chapterList': '.chapter',
        'chapterName': 'a@text',
        'chapterUrl': 'a@href',
      },
      'ruleContent': {'content': 'class.ComicPics@img@html'},
    });
    final result = await runLegadoJob(
      LegadoJob(
        source,
        Uri.parse('https://comic.example.test/chapter'),
        LegadoOperation.images,
        input:
            '<div class="ComicPics"><img data-src="/1.jpg"><img data-src="/2.jpg"></div>',
      ),
      CancellationToken(),
    );
    expect(result.links, ['/1.jpg', '/2.jpg']);
  });
}

void _imageReplacementRuleTest() {
  test(
    'image element rule retains image URLs with Legado replacement',
    () async {
      final source = parseBookSourceRecord({
        'bookSourceName': '图片替换规则',
        'bookSourceUrl': 'https://comic.example.test',
        'bookSourceType': 2,
        'searchUrl': '/search?key={{key}}',
        'ruleContent': {
          'content': 'class.main-container@li@img@html##data-original##src',
        },
      });
      final result = await runLegadoJob(
        LegadoJob(
          source,
          Uri.parse('https://comic.example.test/chapter'),
          LegadoOperation.images,
          input:
              '<div class="main-container"><li>'
              '<img data-original="/1.jpg"><img data-original="/2.jpg">'
              '</li></div>',
        ),
        CancellationToken(),
      );
      expect(result.links, ['/1.jpg', '/2.jpg']);
    },
  );

  test('container replacement still excludes removed images', () async {
    final source = parseBookSourceRecord({
      'bookSourceName': '容器图片替换规则',
      'bookSourceUrl': 'https://comic.example.test',
      'bookSourceType': 2,
      'searchUrl': '/search?key={{key}}',
      'ruleContent': {'content': 'class.pages@html##<img class="ad"[^>]*>##'},
    });
    final result = await runLegadoJob(
      LegadoJob(
        source,
        Uri.parse('https://comic.example.test/chapter'),
        LegadoOperation.images,
        input:
            '<div class="pages"><img class="ad" src="/ad.jpg">'
            '<img src="/page.jpg"></div>',
      ),
      CancellationToken(),
    );
    expect(result.links, ['/page.jpg']);
  });
}

void _mappedSourceTest() {
  test(
    'Manman rule maps the search URL and declared image CDN',
    () async {
      final source = parseBookSourceRecord({
        'bookSourceName': '🎨漫漫漫画',
        'bookSourceUrl': 'https://www.manmanapp.com',
        'bookSourceType': 2,
        'searchUrl': 'https://www.manmanapp.com/search/word-{{key}}.html',
        'ruleSearch': {
          'bookList': 'class.classification',
          'name': 'class.title@text',
          'bookUrl': 'tag.a.0@href',
        },
        'ruleToc': {
          'chapterList': r'$.data',
          'chapterName': r'$.title',
          'chapterUrl': r'https://www.manmanapp.com/comic/detail-{{$.id}}.html',
        },
        'ruleContent': {'content': 'class.man_img@html'},
      });
      expect(source.kind, BookKind.comic);
      expect(
        source.legado!.search,
        'https://www.manmanapp.com/search/index.html?keyword={{key}}',
      );
      expect(source.mediaHosts, contains('images.tmanga.com'));
      final result = await runLegadoJob(
        LegadoJob(
          source,
          Uri.parse('https://www.manmanapp.com/comic/detail-1572470.html'),
          LegadoOperation.images,
          input:
              '<div class="man_img"><img '
              'src="https://images.tmanga.com/comic/small/1.jpg-cs1080"></div>',
        ),
        CancellationToken(),
      );
      expect(result.links, [
        'https://images.tmanga.com/comic/small/1.jpg-cs1080',
      ]);
      expect(
        source
            .resolve(
              Uri.parse('https://www.manmanapp.com/comic/detail-1572470.html'),
              result.links.single,
              media: true,
            )
            .host,
        'images.tmanga.com',
      );
    },
  );
}
