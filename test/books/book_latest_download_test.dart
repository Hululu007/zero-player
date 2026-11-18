import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_download_coordinator.dart';
import 'package:zero_player/features/books/data/book_latest_aggregation.dart';
import 'package:zero_player/features/books/data/books_repository.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_download_plan.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

import '../../test_support/book_fixture_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _lifecycleTests();
  _routingSafetyTests();
  _persistentOriginTests();
  _capacityTests();
}

void _lifecycleTests() {
  test(
    'full download appends newer chapters, persists origins and resumes failures',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      f.failLast = true;
      final task = f.manager.start(f.target, f.current, _aggregatePlan);
      await task.done;
      expect(task.status, BookDownloadStatus.completed);
      expect(task.failures, 1);
      expect(task.chapters, hasLength(4));
      final shelf = (await f.books.store.entry(f.target))!;
      expect(shelf.chapters.map((c) => c.title), ['第1章', '第2章', '第3章', '第4章']);
      final extra = shelf.chapters[2];
      final proof = (await f.books.store.provenText(f.target, extra))!.evidence;
      expect(proof.target.sourceId, f.target.sourceId);
      expect(proof.origin.sourceId, f.origin.sourceId);
      expect(
        await f.books.readText(f.target, extra, CancellationToken()),
        '正文 第3章',
      );
      final plan = BookDownloadPlan.fromJson(
        await f.books.store.read('books_download:${f.target.id}'),
      )!;
      expect(plan.aggregateLatest, isTrue);
      expect(plan.chapterIds, hasLength(4));
      f.failLast = false;
      f.calls.clear();
      final resumed = f.manager.start(f.target, shelf.chapters, plan);
      await resumed.done;
      expect(resumed.failures, 0);
      expect(resumed.total, 1);
      expect(f.calls, ['${f.origin.sourceId}:第4章']);
      expect(
        await f.books.store.provenChapters('text', f.target),
        hasLength(4),
      );
      expect(await f.books.store.read('books_download:${f.target.id}'), isNull);
      await f.books.markSourceRisk(f.originSource, quarantine: true);
      await expectLater(
        f.books.readText(f.target, extra, CancellationToken()),
        throwsA(isA<ContentBlocked>()),
      );
    },
  );

  test(
    'aggregation off and range downloads never inspect other editions',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      for (final plan in [
        const BookDownloadPlan(1, 2, false, fullBook: true),
        const BookDownloadPlan(1, 1, false, aggregateLatest: true),
      ]) {
        final task = f.manager.start(f.target, f.current, plan);
        await task.done;
        expect(task.status, BookDownloadStatus.completed);
        expect(task.chapters, hasLength(2));
      }
      expect(f.inspections, 0);
    },
  );
}

void _routingSafetyTests() {
  test(
    'disabled or revised origins cannot supply aggregate downloads',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      await f.books.saveSource(f.originSource, {'enabled': false});
      final stopped = f.manager.start(f.target, f.current, _aggregatePlan);
      await stopped.done;
      expect(stopped.status, BookDownloadStatus.paused);
      expect(f.calls, isEmpty);
      await f.books.saveSource(f.originSource, {'enabled': true});
      final catalog = await BookLatestAggregation(
        f.books.store,
        f.books.downloadGuard,
      ).prepare(f.target, f.current, [f.edition], CancellationToken());
      final revised = BookSource.fromJson({
        ...f.originSource.toJson(),
        'name': '新规则名称',
      });
      await f.books.saveSource(f.originSource, {'source': revised.toJson()});
      await expectLater(
        f.books.download(f.target, catalog.last, CancellationToken()),
        throwsA(isA<ContentBlocked>()),
      );
      expect(f.calls, isEmpty);
    },
  );

  test(
    'cancelled scans do not publish aggregation or start chapter requests',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      f.cancelScan = true;
      final task = f.manager.start(f.target, f.current, _aggregatePlan);
      await task.done;
      expect(task.status, BookDownloadStatus.paused);
      expect(f.calls, isEmpty);
      expect(await f.books.store.entry(f.target), isNull);
    },
  );

  test(
    'missing durable origin fails closed without requesting synthetic URLs',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final chapter = planBookLatestChapters(f.target, f.current, [
        f.edition,
      ]).first.target;
      await expectLater(
        f.books.readText(f.target, chapter, CancellationToken()),
        throwsFormatException,
      );
      expect(f.calls, isEmpty);
    },
  );
}

void _persistentOriginTests() {
  test(
    'repository reconstruction restores offline aggregate routing',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final task = f.manager.start(f.target, f.current, _aggregatePlan);
      await task.done;
      final cached = (await f.books.store.entry(f.target))!.chapters.last;
      await f.manager.close();
      await f.books.close();
      f.books = BooksRepository(
        f.services.db,
        f.root,
        f.services.offline,
        f.services.contentPolicy,
        (file, token, extension) async {},
        downloadText: (source, book, chapter, token) async =>
            throw StateError('An offline aggregate must not refetch'),
      );
      final restored = (await f.books.store.entry(f.target))!.chapters.last;
      expect(restored.id, cached.id);
      expect(
        await f.books.readText(f.target, restored, CancellationToken()),
        '正文 第4章',
      );
      final origin = await BookLatestAggregation(
        f.books.store,
        f.books.downloadGuard,
      ).origin(f.target, restored);
      expect(origin!.origin.sourceId, f.origin.sourceId);
    },
  );
}

void _capacityTests() {
  test(
    'aggregate capacity failure is explicit and keeps the existing catalog',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      f.newer = List.generate(
        4001,
        (i) => BookChapter(
          '第${i + 1}章',
          Uri.https('origin.example', '/chapter/${i + 1}'),
        ),
      );
      final task = f.manager.start(f.target, f.current, _aggregatePlan);
      await task.done;
      expect(task.status, BookDownloadStatus.failed);
      expect(task.error, contains('目录容量不足'));
      expect(task.chapters, hasLength(2));
      expect(f.calls, isEmpty);
      expect(await f.books.store.entry(f.target), isNull);
    },
  );
}

const _aggregatePlan = BookDownloadPlan(
  1,
  2,
  false,
  fullBook: true,
  aggregateLatest: true,
);

class _Fixture {
  late Directory root;
  late AppServices services;
  late BooksRepository books;
  late BookDownloadCoordinator manager;
  late BookSource targetSource, originSource;
  late Book target, origin;
  late List<BookChapter> current, newer;
  final calls = <String>[];
  bool failLast = false, cancelScan = false;
  int inspections = 0;
  BookEdition get edition => (book: origin, chapters: newer);

  static Future<_Fixture> create() async {
    final f = _Fixture();
    f.root = await Directory.systemTemp.createTemp('latest-download-');
    f.services = AppServices.scoped(f.root, AppDatabase.memory());
    await f.services.settings.load();
    await f.services.supervision.load();
    f.books = BooksRepository(
      f.services.db,
      f.root,
      f.services.offline,
      f.services.contentPolicy,
      (file, token, extension) async {},
      downloadText: (source, book, chapter, token) async {
        f.calls.add('${source.id}:${chapter.title}');
        if (f.failLast && chapter.title == '第4章') {
          throw const SocketException('controlled');
        }
        return '正文 ${chapter.title}';
      },
    );
    f.targetSource = bookFixtureSource('target.example');
    f.originSource = bookFixtureSource('origin.example');
    await f.books.importSources([f.targetSource, f.originSource]);
    await f.books.saveSource(f.targetSource, {'enabled': true});
    await f.books.saveSource(f.originSource, {'enabled': true});
    f.target = Book(
      f.targetSource.id,
      BookKind.text,
      '同一本书',
      '作者',
      Uri.https('target.example', '/book'),
    );
    f.origin = Book(
      f.originSource.id,
      BookKind.text,
      '同一本书',
      '作者',
      Uri.https('origin.example', '/book'),
    );
    List<BookChapter> chapters(String host, int count) => List.generate(
      count,
      (i) => BookChapter('第${i + 1}章', Uri.https(host, '/chapter/${i + 1}')),
    );
    f.current = chapters('target.example', 2);
    f.newer = chapters('origin.example', 4);
    f.manager = BookDownloadCoordinator(
      f.books,
      loadLatestEditions: (book, token) async {
        f.inspections++;
        if (f.cancelScan) token.cancel();
        return [f.edition];
      },
    );
    return f;
  }

  Future<void> close() async {
    await manager.close();
    await books.close();
    await services.close();
    await root.delete(recursive: true);
  }
}
