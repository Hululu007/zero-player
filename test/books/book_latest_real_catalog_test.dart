import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/books/data/book_latest_aggregation.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_chapter_alignment.dart';

void main() {
  test(
    'observed Ye Wujiang 68 chapter catalogue extends beyond 949 entries',
    () {
      final data =
          jsonDecode(
                File(
                  'test/fixtures/books/yewujiang_catalogs.json',
                ).readAsStringSync(),
              )
              as Map;
      List<BookChapter> catalog(String key) => [
        for (final (index, title) in (data[key]['titles'] as List).indexed)
          BookChapter(title as String, Uri.https('$key.example', '/$index')),
      ];
      final current = catalog('target'), newer = catalog('origin');
      final target = Book(
        'target',
        BookKind.text,
        '夜无疆',
        '辰东',
        Uri.https('target.example', '/book'),
      );
      final origin = Book(
        'origin',
        BookKind.text,
        '夜无疆',
        '辰东',
        Uri.https('origin.example', '/book'),
      );
      expect(current, hasLength(68));
      expect(current.last.title, '第68章');
      expect(newer.where((c) => c.title == '第68章 重回白昼世界'), hasLength(1));
      final additions = planBookLatestChapters(target, current, [
        (book: origin, chapters: newer),
      ]);
      expect(current.length + additions.length, greaterThanOrEqualTo(949));
      expect(additions.first.chapter.title, '第69章 无比期待');
      expect(additions.last.chapter, same(newer.last));
      expect(
        additions.map((c) => c.target.id).toSet(),
        hasLength(additions.length),
      );
    },
  );

  test(
    'number-only boundary requires two named consecutive anchors and no ambiguity',
    () {
      List<BookChapter> c(List<String> titles) => [
        for (final (i, title) in titles.indexed)
          BookChapter(title, Uri.https('test.example', '/$i')),
      ];
      final current = c(['第66章 从此只为自己活', '第67章 掌上明猪', '第68章']);
      final valid = c([
        '第66章 从此只为自己活',
        '第67章 掌上明猪',
        '第68章 重回白昼世界',
        '第69章 无比期待',
      ]);
      expect(bookChapterTailBoundary(current, valid), 2);
      expect(bookChapterTailBoundary(current.sublist(1), valid), isNull);
      expect(bookChapterTailBoundary(current, [...valid, ...valid]), isNull);
      expect(
        bookChapterTailBoundary(
          current,
          c(['第66章 其他', '第67章 掌上明猪', '第68章 重回白昼世界']),
        ),
        isNull,
      );
      expect(
        bookChapterTailBoundary(
          c(['第66章 从此只为自己活', '第67章 掌上明猪', '第68章 别的内容']),
          valid,
        ),
        isNull,
      );
      expect(
        bookChapterTailBoundary(
          current,
          c(['第66章 从此只为自己活', '第67章 掌上明猪', '第68章 重回白昼世界【上】', '第68章 重回白昼世界【下】']),
        ),
        isNull,
      );
    },
  );
}
