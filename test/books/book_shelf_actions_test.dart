import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/book_shelf_view.dart';

import '../../test_support/verified_temp_directory.dart';

void main() {
  testWidgets('shelf actions offer removal and deletion with cache choice', (
    tester,
  ) async {
    late VerifiedTempDirectory temp;
    late AppServices services;
    late Book book;
    late BookChapter chapter;
    late BookShelfEntry entry;

    await tester.runAsync(() async {
      temp = await VerifiedTempDirectory.create('book-shelf-actions-');
      services = AppServices.scoped(temp.directory, AppDatabase.memory());
      book = Book(
        'local',
        BookKind.text,
        '书架操作测试',
        '作者',
        Uri.parse('https://fixture.test/action'),
      );
      chapter = BookChapter('第一章', Uri.parse('https://fixture.test/1'));
      await services.books.store.saveBook(book, chapters: [chapter]);
      await services.books.store.saveText(book, chapter, '正文内容');
      entry = (await services.books.store.entry(book))!;
    });
    addTearDown(() => _close(tester, services, temp));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookShelfView(
            repository: services.books,
            kind: BookKind.text,
            entries: [entry],
            onOpen: (_) {},
            onFollowChanged: () {},
            onRefresh: () async {},
            onCheckUpdates: (_) async {},
            checking: false,
            cancelDownload: (_) async {},
          ),
        ),
      ),
    );
    await _waitFor(tester, () => find.byTooltip('书架操作').evaluate().isNotEmpty);

    await _tapLabel(tester, find.byTooltip('书架操作'));
    await _waitFor(tester, () => find.text('从书架移除').evaluate().isNotEmpty);
    expect(find.text('从书架移除'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);

    await _tapLabel(tester, find.text('删除'));
    await _waitFor(
      tester,
      () => find.text('删除《书架操作测试》？').evaluate().isNotEmpty,
    );
    expect(find.text('同时删除缓存与离线文件'), findsOneWidget);
    await _tapLabel(tester, find.text('取消'));
    await _waitFor(
      tester,
      () => find.text('删除《书架操作测试》？').evaluate().isEmpty,
    );

    await _tapLabel(tester, find.byTooltip('书架操作'));
    await _waitFor(tester, () => find.text('从书架移除').evaluate().isNotEmpty);
    await _tapLabel(tester, find.text('从书架移除'));
    await _waitFor(
      tester,
      () => find.text('从书架移除《书架操作测试》？').evaluate().isNotEmpty,
    );
    expect(find.text('同时删除离线文件与阅读缓存'), findsOneWidget);

    await _tapLabel(tester, find.text('移除'));
    await _waitFor(
      tester,
      () => find.text('已从书架移除').evaluate().isNotEmpty,
    );
    await tester.runAsync(() async {
      expect(await services.books.store.entry(book), isNull);
      expect(await services.books.store.text(book, chapter), '正文内容');
    });
    expect(tester.takeException(), isNull);
  });
}

Future<void> _tapLabel(WidgetTester tester, Finder finder) async {
  // Route transitions keep the barrier absorbing pointers for a few frames;
  // settle them before tapping so the hit test lands on the label itself.
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  await tester.tap(finder.last);
  await tester.pump(const Duration(milliseconds: 20));
}

Future<void> _waitFor(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 400 && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(condition(), isTrue, reason: '本地异步操作应完成');
}

Future<void> _close(
  WidgetTester tester,
  AppServices services,
  VerifiedTempDirectory temp,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  var closed = false;
  final closing = services.close().whenComplete(() => closed = true);
  await _waitFor(tester, () => closed);
  await closing;
  await tester.runAsync(temp.delete);
}
