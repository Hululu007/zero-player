import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_download_coordinator.dart';
import 'package:zero_player/features/books/data/books_repository.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_download_plan.dart';

import '../../test_support/book_fixture_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('pausing a retry retains prior chapter failures', _pauseRetry);
  test(
    'resume retains missing target IDs until the catalog restores them',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      f.fail = false;
      final ids = f.chapters.take(2).map((chapter) => chapter.id).toList();
      final task = f.manager.start(f.book, [
        f.chapters.first,
        f.chapters.last,
      ], BookDownloadPlan(1, 2, false, chapterIds: ids));
      await task.done;
      expect(task.status, BookDownloadStatus.partial);
      expect(task.savedChapterIds, {ids.first});
      expect(task.failedChapters, isEmpty);
      expect(task.missingChapterIds, {ids.last});
      expect(f.calls, ['第一章']);
      final saved = BookDownloadPlan.fromJson(
        await f.books.store.read('books_download:${f.book.id}'),
      )!;
      expect(saved.chapterIds, ids);
      f.calls.clear();
      final retry = f.manager.start(f.book, f.chapters, saved);
      await retry.done;
      expect(retry.status, BookDownloadStatus.completed);
      expect(f.calls, ['第二章']);
      expect(await f.books.store.read('books_download:${f.book.id}'), isNull);
    },
  );
  test(
    'partial download survives repository restart and retries only missing chapters',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final first = f.manager.start(f.book, f.chapters, f.plan);
      await first.done;
      expect(first.status, BookDownloadStatus.partial);
      expect(first.failures, 1);
      expect(first.savedChapterIds, hasLength(2));
      expect(first.failedChapters.keys, [f.chapters[1].id]);
      expect(await f.books.store.read('books_download_failures:${f.book.id}'), {
        f.chapters[1].id: '下载失败，请检查来源或网络',
      });
      final plan = BookDownloadPlan.fromJson(
        await f.books.store.read('books_download:${f.book.id}'),
      )!;
      await f.manager.close();
      await f.books.close();
      f.fail = false;
      f.calls.clear();
      f.openRepository();
      final retry = f.manager.start(f.book, f.chapters, plan);
      await retry.done;
      expect(retry.status, BookDownloadStatus.completed);
      expect(retry.total, 1);
      expect(f.calls, ['第二章']);
      expect(await f.books.store.read('books_download:${f.book.id}'), isNull);
      expect(
        await f.books.store.read('books_download_failures:${f.book.id}'),
        isEmpty,
      );
      expect(await f.books.store.provenChapters('text', f.book), hasLength(3));
    },
  );

  test(
    'failed terminal status write keeps resume plan and marks task failed',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      f.fail = false;
      await f.services.db.customStatement(
        "CREATE TRIGGER reject_result BEFORE INSERT ON app_meta WHEN NEW.key LIKE 'books_download_failures:%' BEGIN SELECT RAISE(ABORT,'controlled result failure'); END",
      );
      final task = f.manager.start(f.book, f.chapters, f.plan);
      await task.done;
      expect(task.status, BookDownloadStatus.failed);
      expect(task.error, contains('状态未保存'));
      expect(
        await f.books.store.read('books_download:${f.book.id}'),
        isNotNull,
      );
      expect(await f.books.store.provenChapters('text', f.book), hasLength(3));
      await f.services.db.customStatement('DROP TRIGGER reject_result');
      f.calls.clear();
      final retry = f.manager.start(f.book, f.chapters, f.plan);
      await retry.done;
      expect(retry.status, BookDownloadStatus.completed);
      expect(f.calls, isEmpty);
    },
  );
}

Future<void> _pauseRetry() async {
  final f = await _Fixture.create();
  addTearDown(f.close);
  final first = f.manager.start(f.book, f.chapters, f.plan);
  await first.done;
  final retry = f.manager.start(f.book, f.chapters, f.plan);
  retry.pause();
  await retry.done;
  expect(retry.status, BookDownloadStatus.paused);
  expect(await f.books.store.read('books_download_failures:${f.book.id}'), {
    f.chapters[1].id: '下载失败，请检查来源或网络',
  });
  expect(await f.books.store.read('books_download:${f.book.id}'), isNotNull);
}

class _Fixture {
  late Directory root;
  late AppServices services;
  late BooksRepository books;
  late BookDownloadCoordinator manager;
  late Book book;
  late List<BookChapter> chapters;
  bool fail = true;
  final calls = <String>[];
  final plan = const BookDownloadPlan(1, 3, false);

  static Future<_Fixture> create() async {
    final f = _Fixture();
    f.root = await Directory.systemTemp.createTemp('partial-book-');
    f.services = AppServices.scoped(f.root, AppDatabase.memory());
    await f.services.settings.load();
    await f.services.supervision.load();
    f.openRepository();
    final source = bookFixtureSource('partial.example');
    await f.books.importSources([source]);
    await f.books.saveSource(source, {'enabled': true});
    f.book = Book(
      source.id,
      BookKind.text,
      '部分失败测试',
      '作者',
      source.endpoint.resolve('/book'),
    );
    f.chapters = [
      for (final title in ['第一章', '第二章', '第三章'])
        BookChapter(title, source.endpoint.resolve('/chapter/$title')),
    ];
    return f;
  }

  void openRepository() {
    books = BooksRepository(
      services.db,
      root,
      services.offline,
      services.contentPolicy,
      (_, _, _) async {},
      downloadText: (_, _, chapter, _) async {
        calls.add(chapter.title);
        if (fail && chapter.title == '第二章') {
          throw const SocketException('controlled');
        }
        return '正文 ${chapter.title}';
      },
    );
    manager = BookDownloadCoordinator(books);
  }

  Future<void> close() async {
    await manager.close();
    await books.close();
    await services.close();
    await root.delete(recursive: true);
  }
}
