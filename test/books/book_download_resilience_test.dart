import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/document_client.dart';
import 'package:zero_player/features/books/data/book_download_coordinator.dart';
import 'package:zero_player/features/books/data/book_download_retry.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/data/legado/legado_worker.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_download_plan.dart';

import '../../test_support/book_editions_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('recovers transient failures with three default retries', () async {
    final fixture = await BookEditionsFixture.create(
      serveTargetChapters: true,
      targetTransientFailures: const {
        1: [503, 429, 504],
      },
    );
    addTearDown(fixture.close);
    final repo = fixture.services.books;
    final catalog = await repo.chapters(fixture.book, CancellationToken());
    final plan = BookDownloadPlan.fromJson({
      'first': 1,
      'last': 3,
      'fallback': false,
    })!;
    final task = fixture.services.bookDownloads.start(
      fixture.book,
      catalog,
      plan,
    );
    await task.done;
    expect(task.status, BookDownloadStatus.completed);
    expect(fixture.targetAttempts, {0: 1, 1: 4, 2: 1});
    expect(await repo.store.savedText(fixture.book), hasLength(3));
  });

  test('cancellation interrupts the retry delay', () async {
    final token = CancellationToken();
    final first = Completer<void>();
    var requests = 0;
    final task = retryBookChapter(token, 3, () async {
      requests++;
      first.complete();
      throw const RemoteFailure(FailureKind.network, 'disconnected');
    });
    final result = expectLater(task, throwsA(isA<RequestCancelled>()));
    await first.future;
    token.cancel();
    await result;
    expect(requests, 1);
  });

  test('a disabled retry count sends one attempt', () async {
    var attempts = 0;
    await expectLater(
      retryBookChapter(CancellationToken(), 0, () async {
        attempts++;
        throw const RemoteFailure(FailureKind.http, 'busy', status: 503);
      }),
      throwsA(isA<RemoteFailure>()),
    );
    expect(attempts, 1);
  });

  test('parses a 6205 chapter single-page Legado catalog in order', () async {
    final source = parseBookSourceRecord({
      'bookSourceName': '长目录测试',
      'bookSourceUrl': 'https://books.example',
      'searchUrl': '/search?key={{key}}',
      'ruleSearch': {
        'bookList': '.book',
        'name': 'a@text',
        'bookUrl': 'a@href',
      },
      'ruleToc': {
        'chapterList': '.catalog@a',
        'chapterName': '@text',
        'chapterUrl': '@href',
      },
      'ruleContent': {'content': '.content'},
    });
    final book = Book(source.id, BookKind.text, '测试长目录', '', source.endpoint);
    final html = StringBuffer('<div class="catalog">');
    for (var i = 1; i <= 6205; i++) {
      html.write('<a href="/chapter/$i">第$i章</a>');
    }
    html.write('</div>');
    final result = await runLegadoJob(
      LegadoJob(
        source,
        book.uri,
        LegadoOperation.toc,
        input: html.toString(),
        book: book,
      ),
      CancellationToken(),
    );
    expect(result.chapters, hasLength(6205));
    expect(result.chapters.first.uri.path, '/chapter/1');
    expect(result.chapters.last.uri.path, '/chapter/6205');
  });

  test(
    'downloads and reads the tail of a saved 6205 chapter catalog',
    () async {
      final fixture = await BookEditionsFixture.create(
        targetChapterCount: 6205,
        serveTargetChapters: true,
      );
      addTearDown(fixture.close);
      final repo = fixture.services.books;
      final catalog = await repo.chapters(fixture.book, CancellationToken());
      expect(catalog, hasLength(6205));
      final task = fixture.services.bookDownloads.start(
        fixture.book,
        catalog,
        const BookDownloadPlan(6204, 6205, false),
      );
      await task.done;
      expect(task.status, BookDownloadStatus.completed, reason: task.error);
      expect(
        task.savedChapterIds,
        catalog.skip(6203).map((item) => item.id).toSet(),
      );
      expect((await repo.store.entry(fixture.book))!.chapters, hasLength(6205));
      expect(
        await repo.readText(fixture.book, catalog.last, CancellationToken()),
        isNotEmpty,
      );
      expect(fixture.targetChapterRequests, 2);
    },
  );
}
