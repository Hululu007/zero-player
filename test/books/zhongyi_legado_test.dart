import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/data/legado/legado_request.dart';
import 'package:zero_player/features/books/data/legado/legado_worker.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_search.dart';
import 'package:zero_player/features/books/domain/zhongyi_legacy_source_fix.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map raw;
  setUpAll(() async {
    final bytes = await File(
      'assets/catalogs/books/legado/catalog.json.bz2',
    ).readAsBytes();
    final catalog =
        jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(bytes))) as Map;
    raw = (catalog['records'] as List)[1431] as Map;
  });

  test('only the reviewed full source rules get the current search URL', () {
    final imported = parseBookSourceRecord(raw);
    expect(
      imported.id,
      '83c8aed9fc6c4574a027a64d25988ced39ac5c8b7b3caa524217c2bf3c4dc70a',
    );
    expect(
      imported.legado!.search,
      '/books/search?keyword={{key}}&page={{page}}',
    );
    final saved = _oldConfig(imported, raw);
    final legacy = saved['legado'] as Map;
    expect(legacy['search'], '/books/search/{{key}}/page_{{page}}.html');
    final repaired = repairZhongyiLegadoSource(saved, legacy);
    expect(repaired['search'], '/books/search?keyword={{key}}&page={{page}}');
    final restored = BookSource.fromJson(saved);
    expect(restored.id, imported.id);
    expect(restored.legado!.search, repaired['search']);
    expect(restored.legado!.rules, imported.legado!.rules);

    final changedRules = Map.of(legacy['rules'] as Map);
    changedRules['content'] = '${changedRules['content']}##custom';
    final customized = {...legacy, 'rules': changedRules};
    expect(
      repairZhongyiLegadoSource(saved, customized)['search'],
      legacy['search'],
    );
    expect(
      BookSource.fromJson({...saved, 'legado': customized}).legado!.search,
      legacy['search'],
    );
    expect(
      repairZhongyiLegadoSource(saved, {
        ...legacy,
        'search': '/custom/{{key}}',
      })['search'],
      '/custom/{{key}}',
    );
    expect(
      repairZhongyiLegadoSource({
        ...saved,
        'url': 'https://other.example',
      }, legacy)['search'],
      legacy['search'],
    );
    expect(
      repairZhongyiLegadoSource(saved, {
        ...legacy,
        'library': 'custom',
      })['search'],
      legacy['search'],
    );
    expect(
      () =>
          restored.requestTarget(Uri.parse('https://other.example/books/1073')),
      throwsFormatException,
    );
  });

  test(
    'two terms and pages stay on the source and produce distinct valid results',
    () async {
      final imported = parseBookSourceRecord(raw);
      final saved = _oldConfig(imported, raw);
      final fixed = BookSource.fromJson({
        ...saved,
        'legado': repairZhongyiLegadoSource(saved, saved['legado'] as Map),
      });
      final token = CancellationToken();
      final scenarios = [
        (term: '三国', page: 1, id: '1073', title: '重生三国，做最强军师', author: '跳绳'),
        (term: '重生', page: 1, id: '1727', title: '重生到死对头十八岁那年', author: '蠢蠢欲动'),
        (term: '重生', page: 2, id: '1484', title: '重生归来：王妃又茶又飒', author: '不吃野菜'),
      ];
      final ids = <String>{};
      for (final scenario in scenarios) {
        final request = LegadoRequest.parse(
          fixed,
          fixed.endpoint,
          fixed.legado!.search,
          key: scenario.term,
          page: scenario.page,
        );
        expect(request.uri.scheme, 'https');
        expect(request.uri.host, 'www.zhongyi6.com');
        expect(request.uri.path, '/books/search');
        expect(request.uri.queryParameters['keyword'], scenario.term);
        expect(request.uri.queryParameters['page'], '${scenario.page}');
        final result = await runLegadoJob(
          LegadoJob(
            fixed,
            request.uri,
            LegadoOperation.books,
            input: _searchPage(scenario.id, scenario.title, scenario.author),
          ),
          token,
        );
        final book = result.books.single;
        expect(book.title, scenario.title);
        expect(book.author, scenario.author);
        expect(book.uri.path, '/books/bookinfo/${scenario.id}');
        expect(
          BookSearchQuery(scenario.term, BookSearchField.all).rank(book),
          isNotNull,
        );
        expect(ids.add(book.id), isTrue);
      }
    },
  );
}

String _searchPage(String id, String title, String author) =>
    '''
<ul class="clearfix2 r_hot_list hover_box">
  <li class="clearfix2 box transition_a round_s">
    <div class="fl pic hover_pic"><a href="/books/bookinfo/$id"><img src="/cover.jpg"></a></div>
    <div class="r_cell t_r">
      <div class="t_c">1000字</div>
      <div class="r_cell t_r_l">
        <h5><a href="/books/bookinfo/$id">$title</a></h5>
        <div class="t_t"><a href="/books/bookinfo/$id"><span class="text_m">$author</span></a>
          <span class="m_l_b">已完结</span><a href="/books/bookinfo/$id">历史</a></div>
        <div class="t_c"><p>普通作品简介</p></div>
      </div>
    </div>
  </li>
</ul>''';

Map<String, Object?> _oldConfig(BookSource source, Map raw) => {
  ...source.toJson(),
  'legado': {...source.legado!.toJson(), 'search': raw['searchUrl']},
};
