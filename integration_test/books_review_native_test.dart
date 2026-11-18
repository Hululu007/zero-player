import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/book_reader_page.dart';
import 'package:zero_player/features/books/presentation/book_image_chapter.dart';
import 'package:zero_player/features/books/presentation/reader_style.dart';

import '../test_support/book_fixture_source.dart';
import '../test_support/comic_source_authorization.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'offline comic decodes, pages, zooms and retains settings on Windows',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'books-review-native-',
      );
      final services = AppServices.scoped(root, AppDatabase.memory());
      try {
        await services.settings.load();
        await services.supervision.load();
        final (book, chapter) = await _seed(services);
        await tester.pumpWidget(
          MaterialApp(
            home: BookReaderPage(
              repository: services.books,
              book: book,
              chapters: [chapter],
              initial: chapter,
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (var i = 0; i < 60 && find.byType(Image).evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(find.byType(BookImageChapter), findsOneWidget);
        expect(find.byType(Image), findsWidgets);
        final page = tester.widget<PageView>(find.byType(PageView));
        expect(page.scrollDirection, Axis.horizontal);
        final rect = tester.getRect(find.byType(PageView));
        await tester.tapAt(Offset(rect.right - 12, rect.center.dy));
        await tester.pumpAndSettle();
        expect(page.controller!.page, 1);
        await tester.tapAt(rect.center);
        await tester.pumpAndSettle();
        expect(find.byTooltip('阅读样式'), findsOneWidget);
        expect(find.byType(InteractiveViewer), findsNothing);
        await tester.tapAt(rect.center);
        await tester.pumpAndSettle();
        await tester.longPressAt(rect.center);
        await tester.pumpAndSettle();
        expect(find.byType(InteractiveViewer), findsOneWidget);
        await tester.tap(find.byTooltip('关闭图片'));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pumpAndSettle();
        expect(page.controller!.page, 0);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await services.books.store.clearHistory([book]);
        final entry = (await services.books.store.entry(book))!;
        expect(entry.last, isNull);
        expect(entry.favorite, isTrue);
        expect(
          await services.books.store.savedImages(book),
          contains(chapter.id),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await services.close();
        await root.delete(recursive: true);
      }
    },
  );
}

Future<(Book, BookChapter)> _seed(AppServices services) async {
  final source = bookFixtureSource('comic-native.test', kind: BookKind.comic);
  await authorizeComicFixture(services, source);
  await services.books.importSources([source]);
  final book = Book(
    source.id,
    BookKind.comic,
    '受控漫画回归',
    '',
    source.endpoint.resolve('/book'),
  );
  final chapter = BookChapter('第一话', source.endpoint.resolve('/chapter'));
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4z8DwH4QZYAwAR8oH+WdZbrcAAAAASUVORK5CYII=',
  );
  await services.books.store.saveOfflineImages(book, chapter, {
    source.endpoint.resolve('/one.png'): png,
    source.endpoint.resolve('/two.png'): png,
  }, () async {});
  await services.books.store.saveBook(
    book,
    chapters: [chapter],
    favorite: true,
  );
  await services.books.store.write(
    'books_reader_preferences',
    const ReaderPreferences(
      mode: ReaderTurnMode.slide,
      paper: ReaderPaper.ink,
      animate: false,
    ).toJson(),
  );
  return (book, chapter);
}
