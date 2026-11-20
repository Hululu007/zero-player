import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/features/books/data/book_download_coordinator.dart';
import 'package:zero_player/features/books/data/books_repository.dart';
import 'package:zero_player/features/books/domain/book_download_plan.dart';

import '../../test_support/book_editions_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _retrySelectedChapters();
  _boundedAggregateDownloads();

  test(
    'publishes checked channels before slow searches and isolates failures',
    () async {
      final f = await BookEditionsFixture.create();
      addTearDown(f.close);
      final updates = <BookEditionUpdate>[];
      var finished = false;
      final scan = f.services.books.alternatives(
        f.book,
        CancellationToken(),
        refresh: true,
        includeCurrent: true,
        onProgress: updates.add,
      )..then((_) => finished = true);
      await _until(
        () =>
            f.slowWaiting &&
            updates.any((u) => u.edition?.chapters.length == 5) &&
            updates.any((u) => u.source?.source.id == f.sources['failed']!.id),
      );
      expect(finished, isFalse);
      expect(updates.first.total, 4);
      expect(updates.last.completed, lessThan(4));
      expect(
        updates
            .singleWhere((u) => u.source?.source.id == f.sources['failed']!.id)
            .failed,
        isTrue,
      );
      f.releaseSlow();
      final editions = await scan;
      expect(
        editions.map((e) => e.chapters.length),
        unorderedEquals([3, 5, 7]),
      );
      expect(updates.last.completed, 4);
    },
  );

  test('cancelled scans cannot publish late catalogues', () async {
    final f = await BookEditionsFixture.create();
    addTearDown(f.close);
    final token = CancellationToken();
    final updates = <BookEditionUpdate>[];
    final scan = f.services.books.alternatives(
      f.book,
      token,
      refresh: true,
      onProgress: updates.add,
    );
    final expectation = expectLater(scan, throwsA(isA<RequestCancelled>()));
    await _until(() => f.slowWaiting && updates.any((u) => u.edition != null));
    token.cancel();
    final count = updates.length;
    f.releaseSlow();
    await expectation;
    expect(updates, hasLength(count));
  });

  test(
    'a completed channel revoked during another search is omitted from final editions',
    () async {
      final f = await BookEditionsFixture.create();
      addTearDown(f.close);
      final updates = <BookEditionUpdate>[];
      final scan = f.services.books.alternatives(
        f.book,
        CancellationToken(),
        refresh: true,
        onProgress: updates.add,
      );
      await _until(
        () =>
            f.slowWaiting &&
            updates.any(
              (u) => u.edition?.book.sourceId == f.sources['fast']!.id,
            ),
      );
      await f.services.books.saveSource(f.sources['fast']!, {'enabled': false});
      f.releaseSlow();
      expect(
        (await scan).any((e) => e.book.sourceId == f.sources['fast']!.id),
        isFalse,
      );
    },
  );
}

void _boundedAggregateDownloads() {
  const plan = BookDownloadPlan(
    1,
    3,
    true,
    fullBook: true,
    aggregateLatest: true,
  );
  test('aggregation keeps the verified tail when a catalogue stalls', () async {
    final f = await BookEditionsFixture.create(stallSlowCatalog: true);
    addTearDown(f.close);
    final manager = BookDownloadCoordinator(
      f.services.books,
      aggregationTimeLimit: const Duration(milliseconds: 1200),
    );
    addTearDown(manager.close);
    final books = f.services.books;
    final catalog = await books.chapters(f.book, CancellationToken());
    final task = manager.start(f.book, catalog, plan);
    final stages = <String?>[];
    task.addListener(() => stages.add(task.preparation));
    await task.done.timeout(const Duration(seconds: 8));
    expect(f.slowWaiting, isTrue);
    expect(f.slowReleased, isFalse);
    expect(task.status, BookDownloadStatus.completed, reason: task.error);
    expect(task.aggregationLimited, isTrue);
    expect(task.chapters, hasLength(5));
    expect(task.savedChapterIds, hasLength(5));
    expect(stages, contains('等待已在检查的渠道返回目录'));
    final saved = await books.store.provenText(f.book, task.chapters.last);
    expect(saved?.evidence.origin.sourceId, f.sources['fast']!.id);
  });

  test('pausing a slow aggregate scan persists a resumable plan', () async {
    final f = await BookEditionsFixture.create(serveTargetChapters: true);
    addTearDown(f.close);
    final books = f.services.books;
    final manager = f.services.bookDownloads;
    final catalog = await books.chapters(f.book, CancellationToken());
    final task = manager.start(f.book, catalog, plan);
    await _until(() => f.slowWaiting);
    await manager.pause(f.book).timeout(const Duration(seconds: 3));
    expect(f.slowReleased, isFalse);
    expect(task.status, BookDownloadStatus.paused);
    final saved = BookDownloadPlan.fromJson(
      await books.store.readBookValue(f.book, 'books_download:${f.book.id}'),
    );
    expect(saved?.aggregationPending, isTrue);
    expect(saved?.chapterIds, task.chapters.map((chapter) => chapter.id));
    final pausedCatalog = (await books.store.entry(f.book))!.chapters;
    f.releaseSlow();
    final resumed = manager.start(f.book, pausedCatalog, saved!);
    await resumed.done.timeout(const Duration(seconds: 8));
    expect(resumed.status, BookDownloadStatus.completed, reason: resumed.error);
    expect(resumed.chapters, hasLength(7));
  });

  _parallelAggregateBatches(plan);
}

void _parallelAggregateBatches(BookDownloadPlan plan) {
  test(
    'downloads the base and fast tail before a slower edition returns',
    () async {
      final f = await BookEditionsFixture.create(
        stallSlowCatalog: true,
        serveTargetChapters: true,
      );
      addTearDown(f.close);
      final books = f.services.books;
      final catalog = await books.chapters(f.book, CancellationToken());
      final task = f.services.bookDownloads.start(f.book, catalog, plan);
      await _until(() => f.slowWaiting && task.savedChapterIds.length == 5);
      expect(f.slowReleased, isFalse);
      expect(task.status, BookDownloadStatus.running);
      expect(task.chapters, hasLength(5));
      for (final chapter in catalog) {
        final saved = await books.store.provenText(f.book, chapter);
        expect(saved?.evidence.origin.sourceId, f.book.sourceId);
      }
      f.releaseSlow();
      await task.done.timeout(const Duration(seconds: 8));
      expect(task.status, BookDownloadStatus.completed, reason: task.error);
      expect(task.savedChapterIds, hasLength(7));
      expect(task.finished, 7);
      expect(task.chapters[3].title, '第4章 标题3');
      final fast = await books.store.provenText(f.book, task.chapters[3]);
      final slow = await books.store.provenText(f.book, task.chapters.last);
      expect(fast?.evidence.origin.sourceId, f.sources['fast']!.id);
      expect(slow?.evidence.origin.sourceId, f.sources['slow']!.id);
    },
  );

  test(
    'reserves the current channel and reports the configured scan cap',
    () async {
      final f = await BookEditionsFixture.create(serveTargetChapters: true);
      addTearDown(f.close);
      final books = f.services.books;
      final catalog = await books.chapters(f.book, CancellationToken());
      f.targetChapterCount = 5;
      final manager = BookDownloadCoordinator(books, aggregationSourceLimit: 1);
      addTearDown(manager.close);
      final task = manager.start(f.book, catalog, plan);
      await task.done.timeout(const Duration(seconds: 8));
      expect(task.status, BookDownloadStatus.completed, reason: task.error);
      expect(task.aggregationScope, (eligible: 4, scheduled: 1));
      expect(task.aggregationNotice, contains('本次最多检查 1 个'));
      expect(f.slowWaiting, isFalse);
      expect(task.savedChapterIds, hasLength(5));
      expect(task.chapters.last.uri, f.book.uri.resolve('/chapter/4'));
      final saved = await books.store.provenText(f.book, task.chapters.last);
      expect(saved?.evidence.origin.sourceId, f.book.sourceId);
    },
  );
}

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 400; i++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Timed out waiting for a fixture channel');
}

void _retrySelectedChapters() {
  test(
    'selected failed chapters keep the plan and fall back to a matched edition',
    () async {
      final f = await BookEditionsFixture.create();
      addTearDown(f.close);
      f.releaseSlow();
      final books = f.services.books;
      final token = CancellationToken();
      final catalog = await books.chapters(f.book, token);
      final selected = catalog[1];
      final key = 'books_download:${f.book.id}';
      final original = BookDownloadPlan(1, catalog.length, false);
      await books.store.write(key, original.toJson());
      final manager = f.services.bookDownloads;
      final task = manager.start(
        f.book,
        catalog,
        BookDownloadPlan(1, catalog.length, true, chapterIds: [selected.id]),
        keepPlan: false,
      );
      await task.done;
      expect(task.status, BookDownloadStatus.completed);
      expect(task.savedChapterIds, {selected.id});
      final saved = await books.store.provenText(f.book, selected);
      expect(saved?.body, '替代渠道的正文');
      expect(saved?.evidence.origin.sourceId, f.sources['fast']!.id);
      expect(await books.store.read(key), original.toJson());
    },
  );
}
