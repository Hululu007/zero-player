import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/data/legado/legado_worker.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_search.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map raw;
  setUpAll(() async {
    final bytes = await File(
      'assets/catalogs/books/legado/catalog.json.bz2',
    ).readAsBytes();
    final catalog =
        jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(bytes))) as Map;
    raw = (catalog['records'] as List)[4149] as Map;
  });

  test('only the audited imported or saved old rules are repaired', () {
    final imported = parseBookSourceRecord(raw);
    expect(
      imported.id,
      'e48858cda3b048659b3084eeb23ee97018ca2f07d0d4900d2a1ef5eba055773a',
    );
    expect(
      imported.legado!.rules['searchAuthor'],
      'class.search-info@tag.a.1@text',
    );
    expect(
      imported.legado!.rules['searchDescription'],
      'class.search-sumary@text',
    );
    final old = _oldVersion(imported, raw);
    final restored = BookSource.fromJson(old);
    expect(restored.id, imported.id);
    expect(restored.legado!.rules, imported.legado!.rules);

    final legacy = Map.of(old['legado'] as Map);
    final customRules = Map.of(legacy['rules'] as Map);
    customRules['content'] = '${customRules['content']}##custom';
    final custom = BookSource.fromJson({
      ...old,
      'legado': {...legacy, 'rules': customRules},
    });
    expect(
      custom.legado!.rules['searchAuthor'],
      (raw['ruleSearch'] as Map)['author'],
    );
    expect(
      custom.legado!.rules['searchDescription'],
      (raw['ruleSearch'] as Map)['intro'],
    );
    final otherHost = BookSource.fromJson({
      ...old,
      'url': 'https://other.example',
    });
    expect(
      otherHost.legado!.rules['searchAuthor'],
      (raw['ruleSearch'] as Map)['author'],
    );
  });

  test(
    'search result extracts only the author and summary before author matching',
    () async {
      final source = parseBookSourceRecord(raw);
      final token = CancellationToken();
      final result = await runLegadoJob(
        LegadoJob(
          source,
          Uri.parse(
            'https://www.jingzhi5.com/?s=search&keyword=%E4%B8%89%E5%9B%BD',
          ),
          LegadoOperation.books,
          input: '''
          <ul class="works-list"><li>
            <div class="search-info"><em class="vip"></em>
              <a href="/books/1002" class="title"><b>三国</b>之捣乱天下</a>
              <span class="finish">已完结</span> 作者：
              <a href="/?s=bookself&amp;uid=48761">月月月光光</a>
            </div>
            <p class="search-sumary">第一段作品简介。</p>
          </li></ul>
        ''',
        ),
        token,
      );
      final book = result.books.single;
      expect(book.title, '三国之捣乱天下');
      expect(book.author, '月月月光光');
      expect(book.description, '第一段作品简介。');
      expect(book.uri.toString(), 'https://www.jingzhi5.com/books/1002');
      expect(BookSearchQuery('三国', BookSearchField.author).rank(book), isNull);
      expect(
        BookSearchQuery('月月', BookSearchField.author).rank(book),
        isNotNull,
      );
      expect(
        BookSearchQuery('三国', BookSearchField.title).rank(book),
        isNotNull,
      );
      expect(
        () =>
            source.requestTarget(Uri.parse('https://other.example/books/1002')),
        throwsFormatException,
      );
    },
  );
}

Map<String, Object?> _oldVersion(BookSource source, Map raw) => {
  ...source.toJson(),
  'legado': {
    ...source.legado!.toJson(),
    'rules': {
      ...source.legado!.rules,
      'searchAuthor': (raw['ruleSearch'] as Map)['author'],
      'searchDescription': (raw['ruleSearch'] as Map)['intro'],
    },
  },
};
