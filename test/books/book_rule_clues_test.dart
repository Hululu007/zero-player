import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_rule_clues.dart';
import 'package:zero_player/features/books/domain/book_site_audit_clues.dart';

void main() {
  test('dynamic evaluation in executable fields is an advisory clue', () {
    for (final legacy in [
      {
        'rules': {'content': '@js: eval(String(result))'},
      },
      {'search': '@js: new Function(result)()'},
      {'library': 'const decode = x => eval(x);'},
      {
        'explore': [
          {'title': '分类', 'url': '@js: eval(result)'},
        ],
      },
    ]) {
      final source = _source(legacy);
      expect(bookSourceHasDynamicCode(source), isTrue, reason: '$legacy');
    }
  });

  test('metadata alone and ordinary functions are not reported as eval', () {
    final source = _source({
      'comment': '示例：eval(result)',
      'rules': {'content': '@js: function clean(x) { return x.trim(); }'},
    });
    expect(bookSourceHasDynamicCode(source), isFalse);
    final staticAddress = _source({
      'search': 'https://books.example/eval(test)',
      'rules': {'content': 'p@text'},
    });
    expect(bookSourceHasDynamicCode(staticAddress), isFalse);
    final caller = _source({
      'comment': 'function decode(x) { return x; }',
      'rules': {'content': '@js: eval(String(source.bookSourceComment))'},
    });
    expect(bookSourceHasDynamicCode(caller), isTrue);
  });

  test('a changed version of the same source is checked independently', () {
    final original = _source({
      'rules': {'content': 'p@text'},
    });
    final updated = _source({
      'rules': {'content': '@js: eval(result)'},
    });
    expect(updated.id, original.id);
    expect(bookSourceHasDynamicCode(original), isFalse);
    expect(bookSourceHasDynamicCode(updated), isTrue);
  });

  test(
    'historical homepage finding applies only to the checked exact host',
    () {
      BookSource forHost(String host) => BookSource.fromJson({
        ..._source(const {}).toJson(),
        'url': 'https://$host/feed',
      });
      expect(bookSourceHasHistoricalAmsiClue(forHost('m.nshkedu.com')), isTrue);
      expect(
        bookSourceHasHistoricalAmsiClue(forHost('www.nshkedu.com')),
        isFalse,
      );
      expect(bookSourceHasHistoricalAmsiClue(forHost('nshkedu.com')), isFalse);
    },
  );
}

BookSource _source(Map<String, Object> legado) => BookSource.fromJson({
  'name': '示例源',
  'kind': 'text',
  'format': 'feed',
  'url': 'https://books.example/feed',
  'legado': legado,
});
