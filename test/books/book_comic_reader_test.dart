import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/book_image_chapter.dart';
import 'package:zero_player/features/books/presentation/book_reader_page.dart';

import '../../test_support/book_fixture_source.dart';
import '../../test_support/comic_source_authorization.dart';

void main() {
  testWidgets('offline comic opens a decoded image in the reader', (
    tester,
  ) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('book-comic-reader-'),
    ))!;
    final services = AppServices.scoped(root, AppDatabase.memory());
    addTearDown(() async {
      await tester.runAsync(() async {
        await services.close();
        await root.delete(recursive: true);
      });
    });
    final source = bookFixtureSource('fixture.test', kind: BookKind.comic);
    await tester.runAsync(() async {
      await services.settings.load();
      await services.supervision.load();
      await authorizeComicFixture(services, source);
      await services.books.importSources([source]);
    });
    final book = Book(
      source.id,
      BookKind.comic,
      '测试漫画',
      '作者',
      Uri.parse('https://fixture.test/book'),
    );
    final chapter = BookChapter('第一话', Uri.parse('https://fixture.test/1'));
    final next = BookChapter('第二话', Uri.parse('https://fixture.test/2'));
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4z8DwH4QZYAwAR8oH+WdZbrcAAAAASUVORK5CYII=',
    );
    await tester.runAsync(() async {
      for (final part in [chapter, next]) {
        await services.books.store.saveOfflineImages(book, part, {
          part.uri.resolve('${part.uri.path}-1.png'): bytes,
          part.uri.resolve('${part.uri.path}-2.png'): bytes,
        }, () async {});
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        home: BookReaderPage(
          repository: services.books,
          book: book,
          chapters: [chapter, next],
          initial: chapter,
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BookImageChapter), findsOneWidget);
    final imageView = find.byType(RawImage, skipOffstage: false).first;
    expect(tester.renderObject<RenderImage>(imageView).image, isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      tester.widget<PageView>(find.byType(PageView)).scrollDirection,
      Axis.horizontal,
    );
    final scrollable = find.descendant(
      of: find.byType(BookImageChapter),
      matching: find.byType(Scrollable),
    );
    expect(
      tester.state<ScrollableState>(scrollable).position.pixels,
      greaterThan(0),
    );
    expect(tester.takeException(), isNull);

    await _checkComicNavigationAndRevocation(tester, services, source);
  });
}

Future<void> _checkComicNavigationAndRevocation(
  WidgetTester tester,
  AppServices services,
  BookSource source,
) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
  await _pumpReader(tester);
  PageController pager() =>
      tester.widget<PageView>(find.byType(PageView)).controller!;
  expect(pager().page, 0);
  await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
  await _pumpReader(tester);
  expect(pager().page, 1);
  await tester.tap(find.byTooltip('阅读菜单'));
  await tester.pump();
  expect(find.byTooltip('阅读样式'), findsOneWidget);
  expect(find.byTooltip('章内查找'), findsNothing);
  await tester.tapAt(tester.getCenter(find.byType(PageView)));
  await tester.pump();
  await tester.longPress(find.byType(RawImage).first);
  await tester.pumpAndSettle();
  expect(find.byTooltip('关闭图片'), findsOneWidget);
  await tester.runAsync(
    () => services.books.markSourceRisk(source, adult: true),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  expect(find.byTooltip('关闭图片'), findsNothing);
  expect(find.byType(RawImage), findsNothing);
}

Future<void> _pumpReader(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
  }
  await tester.pump();
}
