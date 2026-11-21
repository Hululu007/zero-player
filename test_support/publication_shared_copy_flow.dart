import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/book_detail_page.dart';
import 'package:zero_player/features/books/presentation/book_shelf_view.dart';
import 'package:zero_player/features/books/presentation/rich_reader_page.dart';
import 'package:zero_player/features/publications/domain/publication.dart';
import 'package:zero_player/features/publications/presentation/publications_page.dart';

import 'local_book_fixtures.dart';

Future<void> verifyPublicationSharedCopyFlow(
  WidgetTester tester,
  AppServices services,
) async {
  final books = services.books;
  final module = services.publications;
  final fixture = await File(
    '${services.root.path}/Ownership.pdf',
  ).writeAsBytes(samplePdf());
  final book = await books.importLocal(fixture);
  await module.library.attachLegacy(book);
  final oldFile = books.documentFile(book, 'pdf');
  final entry = (await books.store.entry(book))!;
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      home: Builder(
        builder: (context) {
          return Scaffold(
            body: BookShelfView(
              repository: books,
              kind: BookKind.text,
              entries: [entry],
              onOpen: (book) => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      BookDetailPage(services: services, initial: book),
                ),
              ),
              onFollowChanged: () {},
              onRefresh: () async {},
              onCheckUpdates: (_) async {},
              checking: false,
            ),
          );
        },
      ),
    ),
  );
  await _tap(tester, find.text(book.title));
  await _tap(tester, find.text('开始阅读'));
  await _wait(tester, find.byType(RichReaderPage));
  await _wait(tester, find.text('1 / 2'));
  await expectLater(
    books.removeLocalBook(book),
    throwsA(
      isA<PublicationFailure>().having(
        (failure) => failure.problem,
        'problem',
        PublicationProblem.inUse,
      ),
    ),
  );
  expect(await oldFile.exists(), isTrue);

  await tester.pumpAndSettle();
  expect(await navigator.currentState!.maybePop(), isTrue);
  await _wait(tester, find.byType(BookDetailPage));
  await tester.pumpAndSettle();
  expect(await navigator.currentState!.maybePop(), isTrue);
  await _tap(tester, find.byTooltip('书架操作'));
  await _tap(tester, find.text('删除'));
  await _wait(tester, find.text('删除《${book.title}》？'));
  await _tap(tester, find.text('删除'));
  await _wait(tester, find.text('已从旧书库删除作品'));
  expect(await books.store.entry(book), isNull);

  final opened = await module.library.open(
    (await module.library.holdings()).single,
    CancellationToken(),
  );
  try {
    expect(opened.file.path, oldFile.path);
    expect(await opened.file.readAsBytes(), await fixture.readAsBytes());
  } finally {
    await module.space.unlease(opened.lease);
  }
  try {
    await _verifyRemovedCopy(tester, services, fixture, oldFile, book.title);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
  }
}

Future<void> _verifyRemovedCopy(
  WidgetTester tester,
  AppServices services,
  File original,
  File retained,
  String title,
) async {
  final module = services.publications;
  final shelf = find.text('书库');
  final copies = find.text('已移除的副本');
  final copy = find.textContaining('$title · PDF');
  final usage = await module.space.usage();
  final originalBytes = await original.readAsBytes();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PublicationsPage(
          module: module,
          books: services.books,
          platform: services.platform,
        ),
      ),
    ),
  );
  await _tap(tester, shelf);
  await _tap(tester, find.byTooltip('图书操作'));
  await _tap(tester, find.text('从图书书库移除'));
  await _wait(tester, find.text('书库还没有图书。'));
  expect(await retained.readAsBytes(), originalBytes);
  expect((await module.space.usage()).used, usage.used);

  await _tap(tester, copies);
  await _tap(tester, copy);
  await _tap(tester, find.text('取消'));
  expect(await retained.exists(), isTrue);

  await _tap(tester, copies);
  await _tap(tester, copy);
  await _tap(tester, find.text('确认'));
  await _wait(tester, find.text('已删除本地副本'));
  expect(await retained.exists(), isFalse);
  expect(await original.readAsBytes(), originalBytes);
  expect((await module.space.usage()).used, usage.used - originalBytes.length);
  await _tap(tester, copies);
  await _wait(tester, find.text('没有已移除的本地副本'));
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _wait(tester, finder);
  await tester.ensureVisible(finder.last);
  await tester.pump(const Duration(milliseconds: 500));
  await tester.tap(finder.last);
  await tester.pump();
}

Future<void> _wait(WidgetTester tester, Finder finder) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(finder, findsWidgets);
}
