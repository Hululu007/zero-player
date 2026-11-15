import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/data/legado/legado_worker.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_search.dart';
import 'package:zero_player/features/books/domain/yingyu_legacy_source_fix.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map raw;
  setUpAll(() async {
    final bytes = await File(
      'assets/catalogs/books/legado/catalog.json.bz2',
    ).readAsBytes();
    final catalog =
        jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(bytes))) as Map;
    raw = (catalog['records'] as List)[4036] as Map;
  });

  test('only the audited imported or saved rule set is repaired', () {
    final imported = parseBookSourceRecord(raw);
    expect(
      imported.id,
      'd4deb7207faa8e5a38459520f6444b13647e7864e65deb83e155362fda135d56',
    );
    expect(imported.legado!.rules['chapterUrl'], 'href');
    expect(
      imported.legado!.rules['content'],
      '@css:.text-content1 .c-en@text||@css:.text-content1@text',
    );
    final saved = _oldConfig(imported, raw);
    final oldLegacy = saved['legado'] as Map;
    final repaired = repairYingyuLegadoSource(saved, oldLegacy);
    final restored = BookSource.fromJson(saved);
    expect(restored.id, imported.id);
    expect(restored.legado!.rules, imported.legado!.rules);
    expect((repaired['rules'] as Map)['chapterUrl'], 'href');

    final changedRules = Map.of(oldLegacy['rules'] as Map);
    changedRules['content'] = '${changedRules['content']}##custom';
    final custom = {...oldLegacy, 'rules': changedRules};
    expect(
      (repairYingyuLegadoSource(saved, custom)['rules'] as Map)['chapterUrl'],
      'class.text-danger@href',
    );
    expect(
      BookSource.fromJson({
        ...saved,
        'legado': custom,
      }).legado!.rules['chapterUrl'],
      'class.text-danger@href',
    );
    expect(
      (repairYingyuLegadoSource({
            ...saved,
            'url': 'https://other.example',
          }, oldLegacy)['rules']
          as Map)['chapterUrl'],
      'class.text-danger@href',
    );
    expect(
      (repairYingyuLegadoSource(saved, {
            ...oldLegacy,
            'library': 'custom',
          })['rules']
          as Map)['chapterUrl'],
      'class.text-danger@href',
    );
    expect(
      () => restored.requestTarget(Uri.parse('https://other.example/book/x')),
      throwsFormatException,
    );
  });

  test(
    'search, details and directory preserve titles, authors and links',
    () async {
      final source = parseBookSourceRecord(raw);
      final token = CancellationToken();
      final search = await runLegadoJob(
        LegadoJob(
          source,
          Uri.parse('https://www.yingyuxiaoshuo.com/search/Pride'),
          LegadoOperation.books,
          input: '''
        <div class="main-list-container"><div class="flex h-36">
          <div><a href="/book/example"><img src="/cover"></a></div>
          <div class="grow"><div><h2><a href="/book/example">傲慢与偏见</a></h2>
            <h2><a href="/book/example">Pride and Prejudice</a></h2></div>
            <div>简·奥斯汀</div><div>作品简介</div>
            <div><span>类型：经典</span><span>难度：高中</span></div>
          </div>
        </div></div>''',
        ),
        token,
      );
      final book = search.books.single;
      expect(book.title, '傲慢与偏见 Pride and Prejudice');
      expect(book.author, '简·奥斯汀');
      expect(book.description, '作品简介');
      expect(book.category, '类型：经典');
      expect(
        BookSearchQuery('Pride', BookSearchField.title).rank(book),
        isNotNull,
      );

      const detail = '''
      <div class="listshadow1"><div><img src="/cover"></div>
        <div><div class="text-danger"><h2>傲慢与偏见</h2><h2>Pride and Prejudice</h2></div>
          <div class="text-danger">作者：简·奥斯汀</div><div class="text-danger">语言：双语</div>
          <div class="text-danger">类型：经典</div><div class="text-danger">难度：高中</div>
        </div><span class="text-intro1">作品简介</span>
      </div>
      <div class="shadow-listshadow1"><div class="grid">
        <a class="text-danger" href="/book/example/chapter/0">Chapter 1</a>
        <a class="text-danger" href="/book/example/chapter/1">Chapter 2</a>
      </div></div>''';
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
      expect(details.books.single.author, '简·奥斯汀');
      expect(details.books.single.category, '语言：双语 类型：经典 难度：高中');
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
      expect(toc.chapters.map((c) => c.title), ['Chapter 1', 'Chapter 2']);
      expect(toc.chapters.first.uri.path, '/book/example/chapter/0');
    },
  );

  test(
    'bilingual and plain English pages retain every English paragraph',
    () async {
      final source = parseBookSourceRecord(raw);
      final token = CancellationToken();
      final uri = Uri.parse(
        'https://www.yingyuxiaoshuo.com/book/example/chapter/0',
      );
      final bilingual = await runLegadoJob(
        LegadoJob(
          source,
          uri,
          LegadoOperation.content,
          input: '''
        <div class="text-content1"><div class="c-en">First English paragraph.</div>
          <div class="c-cn">第一段译文</div><div class="c-en">Second English paragraph.</div>
          <div class="c-cn">第二段译文</div><div class="c-en">Third English paragraph.</div></div>''',
        ),
        token,
      );
      expect(bilingual.content, contains('First English paragraph.'));
      expect(bilingual.content, contains('Second English paragraph.'));
      expect(bilingual.content, contains('Third English paragraph.'));
      expect(bilingual.content, isNot(contains('译文')));
      final english = await runLegadoJob(
        LegadoJob(
          source,
          uri,
          LegadoOperation.content,
          input:
              '<div class="text-content1"><p>Plain English first.</p><p>Plain English last.</p></div>',
        ),
        token,
      );
      expect(english.content, contains('Plain English first.'));
      expect(english.content, contains('Plain English last.'));
    },
  );
}

Map<String, Object?> _oldConfig(BookSource source, Map raw) {
  final search = raw['ruleSearch'] as Map;
  final info = raw['ruleBookInfo'] as Map;
  final toc = raw['ruleToc'] as Map;
  final content = raw['ruleContent'] as Map;
  return {
    ...source.toJson(),
    'legado': {
      ...source.legado!.toJson(),
      'rules': {
        ...source.legado!.rules,
        'searchTitle': search['name'],
        'searchAuthor': search['author'],
        'searchDescription': search['intro'],
        'searchCategory': search['kind'],
        'infoAuthor': info['author'],
        'infoCategory': info['kind'],
        'chapterTitle': toc['chapterName'],
        'chapterUrl': toc['chapterUrl'],
        'content': content['content'],
      },
    },
  };
}
