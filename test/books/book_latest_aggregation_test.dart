import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/books/data/book_latest_aggregation.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_download_plan.dart';

Book _book(
  String source, {
  String author = '作者',
  BookKind kind = BookKind.text,
}) => Book(source, kind, '同一本书', author, Uri.https('$source.example', '/book'));

List<BookChapter> _catalog(String host, List<String> titles) => [
  for (var i = 0; i < titles.length; i++)
    BookChapter(titles[i], Uri.https('$host.example', '/chapter/$i')),
];

void main() {
  final target = _book('target');
  final current = _catalog('target', ['第一章 起点', '第二章 相遇']);
  final origin = _book('origin');
  final newer = _catalog('origin', ['第一章 起点', '第二章 相遇', '第三章 出发']);

  test('extends a matching tail, preserving original chapters and routing', () {
    final result = planBookLatestChapters(target, current, [
      (book: origin, chapters: newer),
    ]);
    expect(result, hasLength(1));
    expect(result.single.chapter, same(newer.last));
    expect(result.single.origin, same(origin));
    expect(result.single.target.title, '第三章 出发');
    expect(BookLatestAggregation.isAggregated(result.single.target), isTrue);
    expect(result.single.target.uri.host, target.uri.host);
    expect(current, hasLength(2));
  });

  test('chains different channels without duplicating shared chapters', () {
    final later = _book('later');
    final result = planBookLatestChapters(target, current, [
      (
        book: later,
        chapters: _catalog('later', ['第二章 相遇', '第三章 出发', '第四章 归来']),
      ),
      (book: origin, chapters: newer),
    ]);
    expect(result.map((c) => c.target.title), ['第三章 出发', '第四章 归来']);
    expect(result.map((c) => c.origin.sourceId), ['origin', 'later']);
    expect(result.map((c) => c.target.id).toSet(), hasLength(2));
    expect(
      planBookLatestChapters(
        target,
        [...current, ...result.map((c) => c.target)],
        [
          (
            book: later,
            chapters: _catalog('later', ['第二章 相遇', '第三章 出发', '第四章 归来']),
          ),
          (book: origin, chapters: newer),
        ],
      ),
      isEmpty,
    );
  });

  test('rejects different or missing authors and non-text editions', () {
    for (final other in [
      _book('origin', author: '另一个作者'),
      _book('origin', author: ''),
      _book('origin', kind: BookKind.comic),
      target,
    ]) {
      expect(
        planBookLatestChapters(target, current, [
          (book: other, chapters: newer),
        ]),
        isEmpty,
      );
    }
    expect(
      planBookLatestChapters(_book('target', author: ''), current, [
        (book: origin, chapters: newer),
      ]),
      isEmpty,
    );
  });

  test(
    'rejects ambiguous boundaries, repeated titles and broken continuity',
    () {
      for (final titles in [
        ['第一章 起点', '第三章 出发', '第四章 归来'],
        ['第一章 起点', '第二章 相遇', '第二章 相遇', '第三章 出发'],
        ['第一章 起点', '第二章 相遇', '第三章 出发', '第三章 出发'],
        ['第一章 起点', '第二章 相遇', '第一章 起点'],
        ['前言', '第二章 相遇', '第三章 出发'],
      ]) {
        expect(
          planBookLatestChapters(target, current, [
            (book: origin, chapters: _catalog('origin', titles)),
          ]),
          isEmpty,
          reason: titles.toString(),
        );
      }
    },
  );

  _planTests();
}

void _planTests() {
  test(
    'download plans retain full-book aggregation and selected chapter IDs',
    () {
      const plan = BookDownloadPlan(
        1,
        4,
        false,
        fullBook: true,
        aggregateLatest: true,
        chapterIds: ['a', 'b'],
      );
      final restored = BookDownloadPlan.fromJson(plan.toJson())!;
      expect(restored.fullBook, isTrue);
      expect(restored.aggregateLatest, isTrue);
      expect(restored.chapterIds, ['a', 'b']);
      final previous = BookDownloadPlan.fromJson({
        'first': 1,
        'last': 2,
        'fallback': true,
      })!;
      expect(previous.aggregateLatest, isFalse);
      expect(previous.fullBook, isFalse);
    },
  );
}
