import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/features/books/data/book_download_coordinator.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_download_plan.dart';

import '../../test_support/book_editions_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a refusal after twenty chapters preserves the rest for fallback resume',
    () async {
      final f = await BookEditionsFixture.create(
        targetChapterCount: 30,
        fastChapterCount: 30,
        serveTargetChapters: true,
        denyTargetFrom: 20,
      );
      addTearDown(f.close);
      f.releaseSlow();
      final books = f.services.books;
      final manager = f.services.bookDownloads;
      final catalog = await books.chapters(f.book, CancellationToken());
      final task = manager.start(
        f.book,
        catalog,
        const BookDownloadPlan(
          1,
          30,
          false,
          fullBook: true,
          aggregateLatest: true,
        ),
      );
      await task.done.timeout(const Duration(seconds: 8));
      expect(task.status, BookDownloadStatus.paused);
      expect(task.error, contains('HTTP 403'));
      expect(await books.store.savedText(f.book), hasLength(20));
      expect(task.failures, inInclusiveRange(2, 5));
      final plan = BookDownloadPlan.fromJson(
        await books.store.readBookValue(f.book, 'books_download:${f.book.id}'),
      )!;
      expect(plan.fallback, isFalse);
      expect(plan.chapterIds, hasLength(30));
      final resumed = manager.start(f.book, task.chapters, plan.withFallback());
      await resumed.done.timeout(const Duration(seconds: 8));
      expect(
        resumed.status,
        BookDownloadStatus.completed,
        reason: resumed.error,
      );
      expect(resumed.total, 10);
      expect(await books.store.savedText(f.book), hasLength(30));
      expect(f.targetChapterRequests, lessThan(30));
      final recovered = await books.store.provenText(f.book, catalog[20]);
      expect(recovered?.evidence.origin.sourceId, f.sources['fast']!.id);
    },
  );

  test(
    'one chapter-specific refusal does not open the source circuit',
    () async {
      final f = await BookEditionsFixture.create(
        targetChapterCount: 3,
        serveTargetChapters: true,
        denyTargetFrom: 2,
      );
      addTearDown(f.close);
      final books = f.services.books;
      final catalog = await books.chapters(f.book, CancellationToken());
      final task = f.services.bookDownloads.start(
        f.book,
        catalog,
        const BookDownloadPlan(1, 3, false),
      );
      await task.done.timeout(const Duration(seconds: 8));
      expect(task.status, BookDownloadStatus.partial);
      expect(task.savedChapterIds, hasLength(2));
      expect(task.failedChapters.values.single, contains('HTTP 403'));
    },
  );

  test('a rate limit pauses the batch and reports the server wait', _rateLimit);
  test(
    'fallback skips a missing announcement and aligns shifted chapters',
    _shiftedFallback,
  );
}

Future<void> _rateLimit() async {
  final f = await BookEditionsFixture.create(
    targetChapterCount: 20,
    denyTargetFrom: 0,
    denyTargetStatus: 429,
  );
  addTearDown(f.close);
  final books = f.services.books;
  final catalog = await books.chapters(f.book, CancellationToken());
  final task = f.services.bookDownloads.start(
    f.book,
    catalog,
    const BookDownloadPlan(1, 20, false),
  );
  await task.done.timeout(const Duration(seconds: 8));
  expect(task.status, BookDownloadStatus.paused);
  expect(task.error, contains('HTTP 429'));
  expect(task.error, contains('12 秒'));
  expect(f.targetChapterRequests, inInclusiveRange(1, 4));
}

Future<void> _shiftedFallback() async {
  final f = await BookEditionsFixture.create(denyTargetFrom: 0);
  addTearDown(f.close);
  final books = f.services.books;
  final alternate = Book(
    f.sources['fast']!.id,
    BookKind.text,
    f.book.title,
    f.book.author,
    Uri.https('fast.example', '/book'),
  );
  final announcement = BookChapter(
    '春节公告',
    Uri.https('target.example', '/chapter/0'),
  );
  final catalog = [
    for (var i = 1; i <= 7; i++) ...[
      if (i == 3) announcement,
      BookChapter('第$i章 标题$i', Uri.https('target.example', '/chapter/$i')),
    ],
  ];
  final shifted = [
    for (var i = 1; i <= 7; i++)
      BookChapter(
        '第${i < 3 ? i : i + 1}章 标题$i',
        Uri.https('fast.example', '/chapter/$i'),
      ),
  ];
  final manager = BookDownloadCoordinator(
    books,
    loadLatestEditions: (_, _) async => [(book: alternate, chapters: shifted)],
    maxConcurrency: 1,
  );
  addTearDown(manager.close);
  final task = manager.start(
    f.book,
    catalog,
    BookDownloadPlan(
      1,
      catalog.length,
      true,
      fullBook: true,
      aggregateLatest: true,
    ),
  );
  await task.done.timeout(const Duration(seconds: 8));
  expect(task.status, BookDownloadStatus.partial);
  expect(
    task.savedChapterIds,
    catalog.where((c) => c != announcement).map((c) => c.id).toSet(),
  );
  final proof = await books.store.provenText(f.book, catalog[3]);
  expect(proof?.evidence.originChapter.title, shifted[2].title);
  expect(task.failedChapters, {announcement.id: '可用书源中没有可核对的对应章节'});
  expect(f.targetChapterRequests, 2);
}
