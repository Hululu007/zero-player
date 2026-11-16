import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/application/book_category_policy.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/data/legado/legado_worker.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/legado_source.dart';
import 'package:zero_player/features/books/domain/legado_source_fingerprint.dart';
import 'package:zero_player/features/books/domain/sfwx_legacy_source_fix.dart';
import 'package:zero_player/features/settings/application/settings_controller.dart';
import 'package:zero_player/features/supervision/application/content_policy.dart';
import 'package:zero_player/features/supervision/application/supervision_controller.dart';

const _sourceId =
    '0723af128aa8adacd3e3a9efe03b622fa660d2f78a21b72cbe2bfe7d32ce8b75';
const _oldDigest =
    'b91ea60260f819a4d31198672593d844caaaee381918419a46888814190ad411';
const _otherSourceId =
    '9f004a19d12200c68d88fd5bafd4d34615b347d27e26322dbfa26142983cd295';
const _otherOldDigest =
    '338b1507f045152f1795bbfb75b95f68bca074ea40f39ccb42cb08cbed5e238a';

late Map _raw;
late Map _otherRaw;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final archive = await File(
      'assets/catalogs/books/legado/catalog.json.bz2',
    ).readAsBytes();
    final catalog =
        jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive))) as Map;
    final records = catalog['records'] as List;
    _raw = records[4760] as Map;
    _otherRaw = records[3984] as Map;
  });

  _registerIdentityTests();
  _registerReadingTests();
  _registerCategoryTests();
}

void _registerIdentityTests() {
  test('unrelated endpoints skip Legado fingerprint evaluation', () {
    final malformed = {'rules': 'not a rule map'};
    final result = repairSfwxLegadoSource({
      'kind': 'text',
      'format': 'html',
      'url': 'https://unrelated.example/',
    }, malformed);
    expect(identical(result, malformed), isTrue);
  });

  test(
    'repairs the original import and its previously saved configuration',
    () {
      final imported = parseBookSourceRecord(_raw);
      final saved = _oldConfiguration(imported, _raw);
      final old = LegadoSource.fromJson(saved['legado'] as Map);
      expect(imported.id, _sourceId);
      expect(legadoSourceFingerprint(old), _oldDigest);
      expect(old.rules['infoInit'], startsWith('@put:'));
      expect(old.rules['nextContent'], 'text.下一章@href');

      final restored = BookSource.fromJson(saved);
      expect(restored.id, _sourceId);
      expect(restored.legado!.rules, imported.legado!.rules);
      expect(restored.legado!.rules['infoInit'], isEmpty);
      expect(
        restored.legado!.rules['infoTitle'],
        r'[property$=book_name]@content',
      );
      expect(restored.legado!.rules['nextContent'], isEmpty);
      expect(restored.legado!.search, old.search);
      expect(restored.legado!.categories.length, old.categories.length);
      final disabled = BookSource.fromJson({...saved, 'defaultEnabled': false});
      expect(disabled.defaultEnabled, isFalse);
      expect(disabled.legado!.rules['infoInit'], isEmpty);
      expect(disabled.legado!.rules['nextContent'], isEmpty);
    },
  );

  test('preserves same-ID custom rules, headers, categories and settings', () {
    for (final entry in [(_raw, _sourceId), (_otherRaw, _otherSourceId)]) {
      _expectCustomVariants(entry.$1, entry.$2);
    }
  });

  test('same-host fingerprints cannot be applied to the other ID', () {
    final tagged = parseBookSourceRecord(_raw);
    final untagged = parseBookSourceRecord(_otherRaw);
    final taggedOld = _oldConfiguration(tagged, _raw);
    final untaggedOld = _oldConfiguration(untagged, _otherRaw);
    expect(untagged.id, _otherSourceId);
    expect(
      legadoSourceFingerprint(
        LegadoSource.fromJson(untaggedOld['legado'] as Map),
      ),
      _otherOldDigest,
    );
    expect(untagged.legado!.rules['infoInit'], isEmpty);
    expect(untagged.legado!.rules['nextContent'], isEmpty);
    final disabled = BookSource.fromJson({
      ...untaggedOld,
      'defaultEnabled': false,
    });
    expect(disabled.defaultEnabled, isFalse);
    expect(disabled.legado!.rules['infoInit'], isEmpty);
    expect(disabled.legado!.rules['nextContent'], isEmpty);
    final wrongTagged = BookSource.fromJson({
      ...taggedOld,
      'legado': untaggedOld['legado'],
    });
    final wrongUntagged = BookSource.fromJson({
      ...untaggedOld,
      'legado': taggedOld['legado'],
    });
    expect(wrongTagged.id, _sourceId);
    expect(wrongUntagged.id, _otherSourceId);
    expect(wrongTagged.legado!.rules['infoInit'], startsWith('@put:'));
    expect(wrongUntagged.legado!.rules['infoInit'], startsWith('@put:'));
  });
}

void _expectCustomVariants(Map raw, String expectedId) {
  final imported = parseBookSourceRecord(raw);
  final saved = _oldConfiguration(imported, raw);
  final legacy = saved['legado'] as Map;
  final changedRules = {...legacy['rules'] as Map, 'content': '.custom@text'};
  final variants = <Map<String, Object?>>[
    {
      ...saved,
      'legado': {...legacy, 'rules': changedRules},
    },
    {
      ...saved,
      'legado': {
        ...legacy,
        'headers': {'X-Example': 'custom'},
      },
    },
    {
      ...saved,
      'legado': {...legacy, 'library': '// custom'},
    },
    {
      ...saved,
      'legado': {...legacy, 'explore': []},
    },
    {
      ...saved,
      'legado': {...legacy, 'enabledExplore': false},
    },
    {
      ...saved,
      'discoveryCategories': [
        {'title': '自定义分类', 'url': '/custom'},
      ],
    },
    {...saved, 'url': 'https://www.sfwx.com/custom'},
  ];
  for (final variant in variants) {
    final source = BookSource.fromJson(variant);
    expect(source.id, expectedId);
    expect(source.legado!.rules['infoInit'], startsWith('@put:'));
    expect(source.legado!.rules['nextContent'], 'text.下一章@href');
  }
}

void _registerReadingTests() {
  test(
    'real engine reads a synthetic chapter without joining the next',
    () async {
      for (final raw in [_raw, _otherRaw]) {
        final source = parseBookSourceRecord(raw);
        final token = CancellationToken();
        final searchUri = Uri.parse('https://www.sfwx.com/search.php?q=test');
        final search = await runLegadoJob(
          LegadoJob(
            source,
            searchUri,
            LegadoOperation.books,
            input:
                '<div class="col-12"><dl><h3><a href="/fixture/">'
                '样例作品</a></h3><span>作者甲</span></dl></div>',
          ),
          token,
        );
        final book = search.books.single;
        expect(book.title, '样例作品');
        expect(book.author, '作者甲');
        const detail =
            '<meta property="og:novel:book_name" content="样例作品">'
            '<meta property="og:novel:author" content="作者甲">'
            '<meta property="og:novel:category" content="高H">'
            '<meta property="og:novel:status" content="连载">'
            '<div class="book_list2"><ul><li><a href="/fixture/1.html">第一章'
            '</a></li><li><a href="/fixture/2.html">第二章</a></li></ul></div>';
        final details = await runLegadoJob(
          LegadoJob(
            source,
            book.uri,
            LegadoOperation.details,
            input: detail,
            book: book,
          ),
          token,
        );
        expect(details.books.single.title, book.title);
        expect(details.books.single.author, book.author);
        expect(details.books.single.category, '高H');
        final toc = await runLegadoJob(
          LegadoJob(
            source,
            book.uri,
            LegadoOperation.toc,
            input: detail,
            book: book,
          ),
          token,
        );
        expect(toc.chapters, hasLength(2));
        const chapterPage =
            '<div class="font_max">本章正文。</div>'
            '<a href="/fixture/2.html">下一章</a>';
        final content = await runLegadoJob(
          LegadoJob(
            source,
            toc.chapters.first.uri,
            LegadoOperation.content,
            input: chapterPage,
            book: book,
            chapter: toc.chapters.first,
          ),
          token,
        );
        expect(content.content, contains('本章正文'));
        expect(content.links, isEmpty);
        final saved = _oldConfiguration(source, raw);
        final legacy = saved['legado'] as Map;
        final rules = Map.of(legacy['rules'] as Map);
        rules['infoTitle'] = '${rules['infoTitle']}##custom';
        final unrepaired = BookSource.fromJson({
          ...saved,
          'legado': {...legacy, 'rules': rules},
        });
        final previous = await runLegadoJob(
          LegadoJob(
            unrepaired,
            toc.chapters.first.uri,
            LegadoOperation.content,
            input: chapterPage,
            book: book,
            chapter: toc.chapters.first,
          ),
          token,
        );
        expect(previous.content, content.content);
        expect(previous.links, ['/fixture/2.html']);
      }
    },
  );
}

void _registerCategoryTests() {
  test('synthetic detail categories retain supervision boundaries', () async {
    final source = parseBookSourceRecord(_raw);
    final other = parseBookSourceRecord(_otherRaw);
    final uri = Uri.parse('https://www.sfwx.com/fixture/');
    final book = Book(source.id, source.kind, '样例作品', '作者甲', uri);
    final otherBook = Book(other.id, other.kind, '样例作品', '作者甲', uri);
    final token = CancellationToken();
    final highH = await _categoryFor(source, book, token, '高H');
    final adult = await _categoryFor(source, book, token, '成人小说');
    final ordinary = await _categoryFor(source, book, token, '科幻小说');
    final nonAdult = await _categoryFor(source, book, token, '非成人小说');
    final otherHighH = await _categoryFor(other, otherBook, token, '高H');
    final otherAdult = await _categoryFor(other, otherBook, token, '成人小说');
    final otherOrdinary = await _categoryFor(other, otherBook, token, '科幻小说');
    expect(highH, '高H');
    expect(adult, '成人小说');
    expect(ordinary, '科幻小说');
    expect(nonAdult, '非成人小说');
    expect(otherHighH, '高H');
    expect(otherAdult, '成人小说');
    expect(otherOrdinary, '科幻小说');

    final db = AppDatabase.memory();
    final settings = SettingsController(db);
    final supervision = SupervisionController(db);
    final policy = ContentPolicy(settings, supervision);
    try {
      expect(policy.filterAdult, isTrue);
      expect(bookCategoryTextAllowed(policy, highH), isFalse);
      expect(bookCategoryTextAllowed(policy, adult), isFalse);
      expect(bookCategoryTextAllowed(policy, ordinary), isTrue);
      // Existing source-label policy conservatively matches this substring.
      expect(bookCategoryTextAllowed(policy, nonAdult), isFalse);
      expect(bookCategoryTextAllowed(policy, otherHighH), isFalse);
      expect(bookCategoryTextAllowed(policy, otherAdult), isFalse);
      expect(bookCategoryTextAllowed(policy, otherOrdinary), isTrue);
      expect(bookCategoryTextAllowed(policy, '成人小说日排行'), isFalse);
      expect(policy.textAllowed('成人小说'), isTrue);
      expect(policy.textAllowed('这里讨论成人小说的分类方式'), isTrue);
      await settings.update({'filterAdult': false});
      expect(policy.filterAdult, isFalse);
      expect(bookCategoryTextAllowed(policy, adult), isTrue);
    } finally {
      policy.dispose();
      await settings.close();
      await supervision.close();
      await db.close();
    }
  });
}

Future<String> _categoryFor(
  BookSource source,
  Book book,
  CancellationToken token,
  String category,
) async {
  final result = await runLegadoJob(
    LegadoJob(
      source,
      book.uri,
      LegadoOperation.details,
      input:
          '<meta property="og:novel:book_name" content="样例作品">'
          '<meta property="og:novel:author" content="作者甲">'
          '<meta property="og:novel:category" content="$category">'
          '<meta property="og:novel:status" content="连载">',
      book: book,
    ),
    token,
  );
  return result.books.single.category;
}

Map<String, Object?> _oldConfiguration(BookSource source, Map raw) {
  final info = raw['ruleBookInfo'] as Map;
  final content = raw['ruleContent'] as Map;
  return {
    ...source.toJson(),
    'legado': {
      ...source.legado!.toJson(),
      'rules': {
        ...source.legado!.rules,
        'infoInit': info['init'],
        'infoTitle': info['name'],
        'infoAuthor': info['author'],
        'infoDescription': info['intro'],
        'infoCover': info['coverUrl'],
        'infoCategory': info['kind'],
        'infoLatest': info['lastChapter'],
        'nextContent': content['nextContentUrl'],
      },
    },
  };
}
