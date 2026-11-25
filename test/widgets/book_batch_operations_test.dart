import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/books/data/book_shelf_lists.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_download_plan.dart';
import 'package:zero_player/features/books/presentation/book_download_management_page.dart';
import 'package:zero_player/features/books/presentation/book_shelf_view.dart';

import '../../test_support/mobile_app_fixture.dart';

void main() {
  final books = [
    for (var i = 1; i <= 2; i++)
      Book(
        'local',
        BookKind.text,
        '书架批量测试 $i',
        '作者',
        Uri.parse('book:batch-test-$i'),
        documentFormat: 'txt',
      ),
  ];
  final chapters = [
    for (final book in books)
      BookChapter('第一章', book.uri.replace(fragment: '1')),
  ];

  Future<MobileAppFixture> setup(WidgetTester tester) async {
    final f = MobileAppFixture();
    await tester.runAsync(() async {
      await f.initialize();
      final store = f.services.books.store;
      for (final (i, book) in books.indexed) {
        await store.saveBook(book, chapters: [chapters[i]], favorite: true);
        await store.saveText(book, chapters[i], '已缓存的正文');
        await store.writeBookValue(
          book,
          'books_download:${book.id}',
          const BookDownloadPlan(1, 1, false).toJson(),
        );
      }
    });
    addTearDown(() => f.finish(tester));
    return f;
  }

  testWidgets(
    'download batch changes retry counts and removes plans independently',
    (tester) async {
      final f = await setup(tester);
      await tester.pumpWidget(
        MaterialApp(home: BookDownloadManagementPage(services: f.services)),
      );
      await f.waitFor(
        tester,
        () => find.text(books.last.title).evaluate().isNotEmpty,
      );
      await selectAll(tester);
      await selectBatchAction(tester, '修改重试次数');
      await tester.tap(find.text('5 次'));
      await f.waitFor(
        tester,
        () => find.textContaining('已处理 2 项').evaluate().isNotEmpty,
      );
      await tester.runAsync(() async {
        final store = f.services.books.store;
        for (final book in books) {
          final data = await store.readBookValue(
            book,
            'books_download:${book.id}',
          );
          expect(BookDownloadPlan.fromJson(data)?.retryCount, 5);
        }
      });

      await selectAll(tester);
      await selectBatchAction(tester, '移除下载计划');
      await tester.tap(find.text('确认'));
      await f.waitFor(
        tester,
        () => find.textContaining('已离线 1 章').evaluate().length == 2,
      );
      await tester.runAsync(() async {
        final store = f.services.books.store;
        for (final (i, book) in books.indexed) {
          expect(
            await store.readBookValue(book, 'books_download:${book.id}'),
            isNull,
          );
          expect(await store.text(book, chapters[i]), '已缓存的正文');
        }
      });
    },
  );

  testWidgets('shelf offers export and can place two books into one group', (
    tester,
  ) async {
    final f = await setup(tester);
    final store = f.services.books.store;
    final lists = BookShelfLists(store, BookKind.text);
    late List<BookShelfEntry> entries;
    await tester.runAsync(() async {
      await lists.save('测试分组', ShelfListKind.group);
      entries = await store.shelf();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookShelfView(
            repository: f.services.books,
            kind: BookKind.text,
            entries: entries,
            onOpen: (_) {},
            onFollowChanged: () {},
            onRefresh: () async {},
            onCheckUpdates: (_) async {},
            checking: false,
          ),
        ),
      ),
    );
    await f.waitFor(
      tester,
      () => find.byTooltip('书架操作').evaluate().length == 2,
    );
    await tester.tap(find.byTooltip('书架操作').first);
    await tester.pumpAndSettle();
    expect(find.text('导出离线章节'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await selectAll(tester);
    await selectBatchAction(tester, '归入同一书架列表');
    await f.waitFor(
      tester,
      () => find.text('分组 · 测试分组').evaluate().length == 1,
    );
    await tester.tap(find.text('分组 · 测试分组'));
    await f.waitFor(
      tester,
      () => find.textContaining('已处理 2 项').evaluate().isNotEmpty,
    );
    await tester.runAsync(() async {
      expect(
        (await lists.load()).single.books,
        books.map((book) => book.id).toSet(),
      );
    });
  });
}

Future<void> selectAll(WidgetTester tester) async {
  await tester.tap(find.text('多选'));
  await tester.pump();
  await tester.tap(find.text('全选当前结果'));
  await tester.pump();
  expect(find.text('已选 2 项'), findsOneWidget);
}

Future<void> selectBatchAction(WidgetTester tester, String label) async {
  await tester.tap(find.text('批量操作'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}
