import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/data/legado/legado_worker.dart';
import 'package:zero_player/features/books/data/legado/yuque_book_list.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/yuque_legacy_source_fix.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map raw;
  setUpAll(() async {
    final bytes = await File(
      'assets/catalogs/books/legado/catalog.json.bz2',
    ).readAsBytes();
    final catalog =
        jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(bytes))) as Map;
    raw = (catalog['records'] as List)[4083] as Map;
  });

  test('only the exact imported or saved legacy rule is repaired', () {
    final imported = parseBookSourceRecord(raw);
    expect(
      imported.id,
      'b6d2bbf620cb376b60bbadd9814c0a466f554b704b017dbeda592dcb31114b06',
    );
    expect(isRepairedYuqueBookList(imported), isTrue);
    final old = _oldVersion(imported, raw);
    final restored = BookSource.fromJson(old);
    expect(restored.id, imported.id);
    expect(isRepairedYuqueBookList(restored), isTrue);
    expect(restored.legado!.comment, isEmpty);

    final oldLegacy = Map.of(old['legado'] as Map);
    final changedRules = Map.of(oldLegacy['rules'] as Map);
    changedRules['content'] = '${changedRules['content']}\n// custom';
    final customized = BookSource.fromJson({
      ...old,
      'legado': {...oldLegacy, 'rules': changedRules},
    });
    expect(isRepairedYuqueBookList(customized), isFalse);
    expect(customized.legado!.rules['content'], changedRules['content']);
    final changedHost = BookSource.fromJson({
      ...old,
      'url': 'https://other.example/list',
    });
    expect(isRepairedYuqueBookList(changedHost), isFalse);
    final changedCategory = BookSource.fromJson({
      ...old,
      'legado': {
        ...oldLegacy,
        'explore': [
          {'title': '自定义', 'url': yuqueBookListUrl},
        ],
      },
    });
    expect(isRepairedYuqueBookList(changedCategory), isFalse);
  });

  test('book data is bounded and only public reviewed slug shapes survive', () {
    final value = jsonDecode(normalizeYuqueBookList(_html(_book()))) as Map;
    final book = value['book'] as Map;
    expect(book['name'], '书单互享');
    expect(book['author'], '作者');
    expect(book['url'], yuqueBookListUrl);
    expect(book['docs'], [
      {'title': '无限流', 'slug': 'gohhxv'},
    ]);

    final invalid = <String>[
      'window.appData = JSON.parse(decodeURIComponent(alert(1)))',
      'window.appData = JSON.parse(decodeURIComponent("%zz"))',
      _html(_book()) + _html(_book()),
      _html({..._book(), 'id': 99}),
      _html({..._book(), 'id': 32273288.0}),
      _html({
        ..._book(),
        'docs': [
          {'slug': '../evil', 'title': 'x', 'status': 1, 'public': 1},
        ],
      }),
      _html({
        ..._book(),
        'docs': [
          {'slug': 'same', 'title': 'x', 'status': 1, 'public': 1},
          {'slug': 'same', 'title': 'y', 'status': 1, 'public': 1},
        ],
      }),
      _html({
        ..._book(),
        'docs': [
          {'slug': 'private', 'title': 'x', 'status': 1, 'public': 0},
        ],
      }),
      ' ' * (2 * 1024 * 1024 + 1),
    ];
    for (final html in invalid) {
      expect(() => normalizeYuqueBookList(html), throwsFormatException);
    }
  });

  test(
    'safe projected data runs discovery, details, contents and plain text rules',
    () async {
      final source = parseBookSourceRecord(raw);
      final token = CancellationToken();
      final body = normalizeYuqueBookList(_html(_book()));
      final found = await runLegadoJob(
        LegadoJob(
          source,
          source.endpoint,
          LegadoOperation.books,
          input: body,
          discovery: true,
        ),
        token,
      );
      final book = found.books.single;
      expect(book.title, '书单互享');
      expect(book.author, '作者');
      expect(book.uri.toString(), yuqueBookListUrl);
      final details = await runLegadoJob(
        LegadoJob(
          source,
          source.endpoint,
          LegadoOperation.details,
          input: body,
          book: book,
        ),
        token,
      );
      expect(details.books.single.title, '书单互享');
      final toc = await runLegadoJob(
        LegadoJob(
          source,
          source.endpoint,
          LegadoOperation.toc,
          input: body,
          book: book,
        ),
        token,
      );
      final chapter = toc.chapters.single;
      expect(chapter.title, '无限流');
      expect(
        chapter.uri.toString(),
        'https://www.yuque.com/api/docs/gohhxv?book_id=32273288',
      );
      final text = await runLegadoJob(
        LegadoJob(
          source,
          chapter.uri,
          LegadoOperation.content,
          input: jsonEncode({
            'data': {'content': '<p>第一本书</p><p>第二本书</p>'},
          }),
          book: book,
          chapter: chapter,
        ),
        token,
      );
      expect(text.content, contains('第一本书'));
      expect(text.content, contains('第二本书'));
      expect(text.content, isNot(contains('<p>')));
      expect(
        () =>
            source.requestTarget(Uri.parse('https://other.example/api/docs/x')),
        throwsFormatException,
      );
    },
  );
}

Map<String, Object> _book() => {
  'id': yuqueBookId,
  'name': '书单互享',
  'description': '推荐书单',
  'contributors': [
    {'name': '作者'},
  ],
  'docs': [
    {'slug': 'gohhxv', 'title': '无限流', 'public': 1, 'status': 1},
    {'slug': 'private', 'title': '私有', 'public': 0, 'status': 1},
  ],
};

String _html(Map<String, Object> book) =>
    '<script>window.appData = JSON.parse(decodeURIComponent(${jsonEncode(Uri.encodeComponent(jsonEncode({'book': book})))}));</script>';

Map<String, Object?> _oldVersion(BookSource source, Map raw) {
  final oldRules = <String, String>{};
  void put(String key, Object? value) {
    if (value is String && value.trim().isNotEmpty) {
      oldRules[key] = value.trim();
    }
  }

  void list(String prefix, Map value) {
    const names = {
      'List': 'bookList',
      'Title': 'name',
      'Link': 'bookUrl',
      'Author': 'author',
      'Cover': 'coverUrl',
      'Category': 'kind',
      'Description': 'intro',
      'WordCount': 'wordCount',
      'Latest': 'lastChapter',
      'Updated': 'updateTime',
      'Rank': 'rank',
    };
    for (final entry in names.entries) {
      put('$prefix${entry.key}', value[entry.value]);
    }
  }

  list('search', raw['ruleSearch'] as Map);
  list('explore', raw['ruleExplore'] as Map);
  final info = raw['ruleBookInfo'] as Map;
  for (final entry in const {
    'infoInit': 'init',
    'infoTitle': 'name',
    'infoAuthor': 'author',
    'infoDescription': 'intro',
    'infoCover': 'coverUrl',
    'infoCategory': 'kind',
    'infoWordCount': 'wordCount',
    'infoLatest': 'lastChapter',
    'infoUpdated': 'updateTime',
    'toc': 'tocUrl',
  }.entries) {
    put(entry.key, info[entry.value]);
  }
  final toc = raw['ruleToc'] as Map;
  for (final entry in const {
    'chapters': 'chapterList',
    'chapterTitle': 'chapterName',
    'chapterUrl': 'chapterUrl',
    'chapterVolume': 'isVolume',
    'nextToc': 'nextTocUrl',
  }.entries) {
    put(entry.key, toc[entry.value]);
  }
  final content = raw['ruleContent'] as Map;
  put('content', content['content']);
  put('nextContent', content['nextContentUrl']);
  put('replaceContent', content['replaceRegex']);
  return {
    ...source.toJson(),
    'legado': {
      ...source.legado!.toJson(),
      'search': raw['searchUrl'],
      'comment': raw['bookSourceComment'],
      'rules': oldRules,
    },
  };
}
