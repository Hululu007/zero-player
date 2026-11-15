import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/data/legado/legado_request.dart';
import 'package:zero_player/features/books/data/legado/legado_worker.dart';
import 'package:zero_player/features/books/domain/book.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Dushu search uses the current rd query parameter', () async {
    final rows =
        jsonDecode(
              await rootBundle.loadString(
                'assets/catalogs/books/verified.json',
              ),
            )
            as List;
    final source = BookSource.fromJson(
      rows.cast<Map>().firstWhere((row) => row['name'] == '读书网 · 国学古籍'),
    );
    final target = source.resolve(
      source.endpoint,
      source.search.replaceAll('{key}', Uri.encodeQueryComponent('汉书')),
    );
    expect(target.queryParameters['rd'], '汉书');
    expect(target.queryParameters, isNot(contains('qd')));
  });

  test(
    'old Legado Dushu rules search, resolve chapters and read content',
    () async {
      final imported = _legacySource();
      final old = imported.toJson();
      final oldLegado = Map<String, Object?>.from(old['legado'] as Map);
      oldLegado['search'] =
          'https://www.dushu.com/search.aspx?wd={{key}}&f=0&r=3&t=0&p={{page}}';
      old['legado'] = oldLegado;
      for (final source in [imported, BookSource.fromJson(old)]) {
        await _verifyLegadoReading(source);
      }
      final changed = Map<String, Object?>.from(old);
      changed['url'] = 'https://unrelated.example/';
      expect(BookSource.fromJson(changed).legado!.search, contains('?wd='));
      final customized = Map<String, Object?>.from(oldLegado);
      customized['rules'] = {
        ...oldLegado['rules'] as Map,
        'searchAuthor': '.custom-author@text',
      };
      final saved = Map<String, Object?>.from(old)..['legado'] = customized;
      expect(
        BookSource.fromJson(saved).legado!.rules['searchAuthor'],
        '.custom-author@text',
      );
    },
  );
}

BookSource _legacySource() => parseBookSourceRecord({
  'bookSourceName': '读书网旧版',
  'bookSourceUrl': 'https://www.dushu.com/xiaoshuo',
  'searchUrl':
      'https://www.dushu.com/search.aspx?wd={{key}}&f=0&r=3&t=0&p={{page}}',
  'ruleSearch': {
    'bookList': 'class.searchlist@tag.li',
    'name': 'tag.h3@tag.a@text',
    'author': 'tag.p.0@tag.em@text',
    'bookUrl': 'tag.h3@tag.a@href',
  },
  'ruleBookInfo': {
    'name': 'class.book-title@h1@text',
    'author': 'class.book-details@tag.tr.0@tag.a@text',
  },
  'ruleToc': {
    'chapterList': 'class.booklist-table@tag.td',
    'chapterName': 'tag.a@text',
    'chapterUrl': 'tag.a@href',
  },
  'ruleContent': {'content': 'class.content_txt@html'},
});

Future<void> _verifyLegadoReading(BookSource source) async {
  final request = LegadoRequest.parse(
    source,
    source.endpoint,
    source.legado!.search,
    key: '三国演义',
  );
  expect(request.uri.queryParameters['rd'], '三国演义');
  expect(request.uri.queryParameters.containsKey('wd'), isFalse);
  final token = CancellationToken();
  final results = await runLegadoJob(
    LegadoJob(
      source,
      request.uri,
      LegadoOperation.books,
      input:
          '<div class="searchlist"><ul><li><div class="book-info">'
          '<h3><a href="/showbook/100004/">三国演义</a></h3>'
          '<p>罗贯中</p></div></li></ul></div>',
    ),
    token,
  );
  final book = results.books.single;
  expect(book.author, '罗贯中');
  final details = await runLegadoJob(
    LegadoJob(
      source,
      book.uri,
      LegadoOperation.details,
      book: book,
      input:
          '<div class="book-title"><h1>三国演义</h1></div>'
          '<div class="book-details-left"><table><tr>'
          '<td>作者</td><td>罗贯中</td></tr></table></div>',
    ),
    token,
  );
  expect(details.books.single.author, '罗贯中');
  final toc = await runLegadoJob(
    LegadoJob(
      source,
      book.uri,
      LegadoOperation.toc,
      book: book,
      input:
          '<table class="booklist-table"><tr><td>'
          '<a href="/showbook/100004/1000324.html">第一回</a>'
          '</td></tr></table>',
    ),
    token,
  );
  final chapter = toc.chapters.single;
  final body = await runLegadoJob(
    LegadoJob(
      source,
      chapter.uri,
      LegadoOperation.content,
      book: book,
      chapter: chapter,
      input: '<div class="content_txt">正文第一段。<br>正文第二段。</div>',
    ),
    token,
  );
  expect(body.content, contains('正文第一段'));
}
