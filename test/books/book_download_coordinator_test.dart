import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/persistence/installation_metadata.dart';
import 'package:zero_player/features/books/data/book_download_coordinator.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_download_plan.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

void main() {
  test(
    'paused download resumes with bounded per-kind concurrency and cleans up',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final root = await Directory.systemTemp.createTemp('book-download-task-');
      final services = AppServices.scoped(root, AppDatabase.memory());
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      await services.settings.load();
      await services.supervision.load();
      final book = Book(
        'source',
        BookKind.text,
        '后台下载测试',
        '作者',
        Uri.parse('https://fixture.test/book'),
      );
      final chapters = List.generate(
        6,
        (index) => BookChapter(
          '第${index + 1}章',
          Uri.parse('https://fixture.test/${index + 1}'),
        ),
      );
      var active = 0, peak = 0, started = 0;
      var gate = Completer<void>();
      var firstThree = Completer<void>();
      final coordinator = BookDownloadCoordinator(
        services.books,
        downloadChapter: (book, chapter, token) async {
          active++;
          started++;
          if (active > peak) peak = active;
          if (started == 3 && !firstThree.isCompleted) firstThree.complete();
          try {
            await gate.future;
            token.check();
            await services.books.store.saveText(book, chapter, chapter.title);
          } finally {
            active--;
          }
        },
      );
      addTearDown(coordinator.close);
      const plan = BookDownloadPlan(1, 6, false);
      final immediate = coordinator.start(book, chapters, plan);
      immediate.pause();
      await immediate.done;
      expect(immediate.status, BookDownloadStatus.paused);
      expect(immediate.error, isNull);
      expect(
        await services.books.store.read('books_download:${book.id}'),
        isNotNull,
      );

      final first = coordinator.start(book, chapters, plan);
      await firstThree.future.timeout(const Duration(seconds: 5));
      expect(coordinator.active(book), same(first));
      expect(peak, 4);
      first.pause();
      services.contentPolicy.refresh();
      gate.complete();
      await first.done;
      expect(first.status, BookDownloadStatus.paused);
      expect(first.error, isNull);
      expect(coordinator.active(book), isNull);
      expect(
        await services.books.store.read('books_download:${book.id}'),
        isNotNull,
      );

      gate = Completer<void>()..complete();
      firstThree = Completer<void>();
      started = 0;
      final resumed = coordinator.start(book, chapters, plan);
      await resumed.done.timeout(const Duration(seconds: 5));
      expect(resumed.status, BookDownloadStatus.completed);
      expect(resumed.failures, 0);
      expect(resumed.finished, 6);
      expect(peak, 4);
      expect(await services.books.store.savedText(book), hasLength(6));
      expect(
        await services.books.store.read('books_download:${book.id}'),
        isNull,
      );
      expect(coordinator.active(book), isNull);
    },
  );

  test('explicit concurrency cap bounds parallel chapter fetches', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final root = await Directory.systemTemp.createTemp('book-download-cap-');
    final services = AppServices.scoped(root, AppDatabase.memory());
    addTearDown(() async {
      await services.close();
      await root.delete(recursive: true);
    });
    await services.settings.load();
    await services.supervision.load();
    final book = Book(
      'source',
      BookKind.text,
      '并发上限测试',
      '作者',
      Uri.parse('https://fixture.test/capped'),
    );
    final chapters = List.generate(
      5,
      (index) => BookChapter(
        '第${index + 1}章',
        Uri.parse('https://fixture.test/capped/${index + 1}'),
      ),
    );
    var active = 0, peak = 0;
    final coordinator = BookDownloadCoordinator(
      services.books,
      maxConcurrency: 2,
      downloadChapter: (book, chapter, token) async {
        active++;
        if (active > peak) peak = active;
        try {
          await Future<void>.delayed(const Duration(milliseconds: 15));
          token.check();
          await services.books.store.saveText(book, chapter, chapter.title);
        } finally {
          active--;
        }
      },
    );
    addTearDown(coordinator.close);
    final task = coordinator.start(
      book,
      chapters,
      const BookDownloadPlan(1, 5, false),
    );
    await task.done.timeout(const Duration(seconds: 5));
    expect(task.status, BookDownloadStatus.completed);
    expect(task.finished, 5);
    expect(peak, 2);
  });

  test(
    'policy revocation identifies the pause without changing user pause',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final root = await Directory.systemTemp.createTemp('book-policy-pause-');
      final services = AppServices.scoped(root, AppDatabase.memory());
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      await services.db.write('INSERT OR REPLACE INTO app_meta VALUES(?,?)', [
        installationAccessKey,
        upgradedInstallationAccess,
      ]);
      await services.settings.load();
      await services.supervision.load();
      final book = Book(
        'source',
        BookKind.text,
        '测试',
        '作者',
        Uri.parse('https://fixture.test/book'),
      );
      final chapter = BookChapter('第一章', Uri.parse('https://fixture.test/1'));
      final started = Completer<void>();
      final release = Completer<void>();
      final coordinator = BookDownloadCoordinator(
        services.books,
        downloadChapter: (_, _, token) async {
          started.complete();
          await release.future;
          token.check();
        },
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await coordinator.close();
      });
      final task = coordinator.start(book, [
        chapter,
      ], const BookDownloadPlan(1, 1, false));
      await started.future.timeout(const Duration(seconds: 5));
      await services.settings.update({
        'filterAdult': !services.settings.value.filterAdult,
      });
      release.complete();
      await task.done.timeout(const Duration(seconds: 5));
      expect(task.status, BookDownloadStatus.paused);
      expect(task.error, '内容策略已改变，下载已暂停');
      expect(await services.books.store.text(book, chapter), isNull);
    },
  );

  test(
    'a blocked worker keeps the policy reason when another is cancelled',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final root = await Directory.systemTemp.createTemp(
        'book-concurrent-block-',
      );
      final services = AppServices.scoped(root, AppDatabase.memory());
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      await services.settings.load();
      await services.supervision.load();
      final book = Book(
        'source',
        BookKind.text,
        '测试',
        '作者',
        Uri.parse('https://fixture.test/book'),
      );
      final chapters = [
        BookChapter('受限', Uri.parse('https://fixture.test/1')),
        BookChapter('并发', Uri.parse('https://fixture.test/2')),
      ];
      final bothStarted = Completer<void>();
      var count = 0;
      final visited = <String>[];
      final coordinator = BookDownloadCoordinator(
        services.books,
        downloadChapter: (_, chapter, token) async {
          visited.add(chapter.title);
          if (++count == 2) bothStarted.complete();
          await bothStarted.future;
          if (chapter.title == '受限') throw const ContentBlocked();
          final cancelled = Completer<void>();
          final unlink = token.listen(() => cancelled.complete());
          try {
            await cancelled.future;
            token.check();
          } finally {
            unlink();
          }
        },
      );
      addTearDown(() async {
        if (!bothStarted.isCompleted) bothStarted.complete();
        await coordinator.close();
      });
      final task = coordinator.start(
        book,
        chapters,
        const BookDownloadPlan(1, 2, true),
      );
      await task.done.timeout(const Duration(seconds: 5));
      expect(task.status, BookDownloadStatus.paused);
      expect(task.error, '内容策略已改变，下载已暂停');
      expect(visited, containsAll(['受限', '并发']));
      expect(visited, hasLength(2));
    },
  );

  test('closing the download service does not report a policy block', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final root = await Directory.systemTemp.createTemp('book-close-pause-');
    final services = AppServices.scoped(root, AppDatabase.memory());
    addTearDown(() async {
      await services.close();
      await root.delete(recursive: true);
    });
    await services.settings.load();
    await services.supervision.load();
    final book = Book(
      'source',
      BookKind.text,
      '测试',
      '作者',
      Uri.parse('https://fixture.test/book'),
    );
    final chapter = BookChapter('第一章', Uri.parse('https://fixture.test/1'));
    final started = Completer<void>();
    final release = Completer<void>();
    final coordinator = BookDownloadCoordinator(
      services.books,
      downloadChapter: (_, _, token) async {
        started.complete();
        await release.future;
        token.check();
      },
    );
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await coordinator.close();
    });
    final task = coordinator.start(book, [
      chapter,
    ], const BookDownloadPlan(1, 1, false));
    await started.future.timeout(const Duration(seconds: 5));
    final closing = coordinator.close();
    release.complete();
    await closing.timeout(const Duration(seconds: 5));
    expect(task.status, BookDownloadStatus.paused);
    expect(task.error, isNull);
  });
}
