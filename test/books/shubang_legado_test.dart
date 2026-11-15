import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/data/legado/legado_worker.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/shubang_legacy_source_fix.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map raw;
  setUpAll(() async {
    final bytes = await File(
      'assets/catalogs/books/legado/catalog.json.bz2',
    ).readAsBytes();
    final catalog =
        jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(bytes))) as Map;
    raw = (catalog['records'] as List)[1056] as Map;
  });

  test('only the audited source and full old rule set are repaired', () {
    final imported = parseBookSourceRecord(raw);
    expect(
      imported.id,
      '981adf7639a1c61e23ad4104e4e11b3553439b9ea22599c1b429881ace889402',
    );
    expect(imported.legado!.rules['searchLink'], 'href');
    expect(imported.legado!.rules.containsKey('nextContent'), isFalse);
    final saved = _oldConfig(imported, raw);
    final oldLegacy = saved['legado'] as Map;
    final repaired = repairShubangLegadoSource(saved, oldLegacy);
    expect((repaired['rules'] as Map)['searchLink'], 'href');
    expect((repaired['rules'] as Map).containsKey('nextContent'), isFalse);
    final restored = BookSource.fromJson(saved);
    expect(restored.id, imported.id);
    expect(restored.legado!.rules, imported.legado!.rules);

    final changedRules = Map.of(oldLegacy['rules'] as Map);
    changedRules['content'] = '${changedRules['content']}##custom';
    final custom = {...oldLegacy, 'rules': changedRules};
    expect(
      (repairShubangLegadoSource(saved, custom)['rules'] as Map)['searchLink'],
      'a@href',
    );
    expect(
      BookSource.fromJson({
        ...saved,
        'legado': custom,
      }).legado!.rules['nextContent'],
      'class.pagebar@a.-1@href',
    );
    expect(
      (repairShubangLegadoSource({
            ...saved,
            'url': 'https://other.example',
          }, oldLegacy)['rules']
          as Map)['searchLink'],
      'a@href',
    );
    expect(
      (repairShubangLegadoSource(saved, {
            ...oldLegacy,
            'library': 'custom',
          })['rules']
          as Map)['searchLink'],
      'a@href',
    );
    expect(
      () => restored.requestTarget(
        Uri.parse('https://other.example/book/209.html'),
      ),
      throwsFormatException,
    );
  });

  test(
    'search uses each row link and content stops before the next chapter',
    () async {
      final source = parseBookSourceRecord(raw);
      final token = CancellationToken();
      final search = await runLegadoJob(
        LegadoJob(
          source,
          Uri.parse('https://www.shubang.net/book/?q=%E5%82%B2%E6%85%A2'),
          LegadoOperation.books,
          input: '''
        <div class="mcon"><a class="book" href="/book/209.html">
          <div class="cover"><img src="/img/book/209.jpg"></div>
          <h3>傲慢与偏见 (Pride and Prejudice)</h3>
          <div class="cont"><p>作者：简·奥斯汀</p>书籍介绍</div>
        </a></div>''',
        ),
        token,
      );
      final book = search.books.single;
      expect(book.title, '傲慢与偏见 (Pride and Prejudice)');
      expect(book.uri.toString(), 'https://www.shubang.net/book/209.html');
      final chapter = BookChapter(
        '第一章',
        Uri.parse('https://www.shubang.net/book/209_5934.html'),
      );
      const html = '''
      <div class="line_en">First chapter first sentence.</div>
      <div class="line_cn" title="第一章第一句"></div>
      <div class="line_en">First chapter final sentence.</div>
      <div class="line_cn" title="第一章最后一句"></div>
      <div class="pagebar"><a href="209.html">上一章</a><a href="209.html">回目录</a>
        <a href="209_5935.html">下一章</a></div>''';
      final body = await runLegadoJob(
        LegadoJob(
          source,
          chapter.uri,
          LegadoOperation.content,
          input: html,
          book: book,
          chapter: chapter,
        ),
        token,
      );
      expect(body.content, contains('First chapter first sentence.'));
      expect(body.content, contains('第一章最后一句'));
      expect(body.links, isEmpty);

      final saved = _oldConfig(source, raw);
      final oldLegacy = saved['legado'] as Map;
      final unchanged = Map.of(oldLegacy['rules'] as Map);
      unchanged['infoTitle'] = '${unchanged['infoTitle']}##custom';
      final old = BookSource.fromJson({
        ...saved,
        'legado': {...oldLegacy, 'rules': unchanged},
      });
      final previous = await runLegadoJob(
        LegadoJob(
          old,
          chapter.uri,
          LegadoOperation.content,
          input: html,
          book: book,
          chapter: chapter,
        ),
        token,
      );
      expect(previous.links, ['209_5935.html']);
    },
  );
}

Map<String, Object?> _oldConfig(BookSource source, Map raw) => {
  ...source.toJson(),
  'legado': {
    ...source.legado!.toJson(),
    'rules': {
      ...source.legado!.rules,
      'searchLink': (raw['ruleSearch'] as Map)['bookUrl'],
      'nextContent': (raw['ruleContent'] as Map)['nextContentUrl'],
    },
  },
};
