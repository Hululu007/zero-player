import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/reading_marks_store.dart';
import 'package:zero_player/features/books/domain/reading_mark.dart';
import 'package:zero_player/features/books/presentation/epub_html_viewport.dart';
import 'package:zero_player/features/books/presentation/reader_curl.dart';
import 'package:zero_player/features/books/presentation/reader_style.dart';
import 'package:zero_player/features/books/presentation/rich_reader_page.dart';
import 'package:zero_player/features/books/presentation/vertical_book_text.dart';

import '../../test_support/local_book_fixtures.dart';

void main() {
  testWidgets(
    'EPUB retains its source position across modes, type and reopen',
    (tester) async {
      tester.view.physicalSize = const Size(440, 660);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'epub-reading-modes-',
        );
        final services = AppServices.scoped(root, AppDatabase.memory());
        await services.settings.load();
        await services.supervision.load();
        final file = await File(
          '${root.path}/modes.epub',
        ).writeAsBytes(_modeFixture());
        final book = await services.books.importLocal(file);
        final store = services.books.store;
        await store.write(
          'books_reader_preferences',
          const ReaderPreferences(immersive: false).toJson(),
        );
        final key = 'rich_position_${book.id}';
        await store.write(key, {'index': 0, 'horizontal': true, 'offset': 0.0});
        addTearDown(() async {
          await services.close();
          await root.delete(recursive: true);
        });
        return (
          key: key,
          store: store,
          digest: book.uri.path,
          marks: ReadingMarksStore(store, book, () => true),
          reader: MaterialApp(
            home: RichReaderPage(
              repository: services.books,
              book: book,
              file: services.books.documentFile(book, 'epub'),
            ),
          ),
        );
      }))!;

      final viewport = find.byType(EpubHtmlViewport);
      await _open(tester, fixture.reader, viewport);
      final scroll = find
          .descendant(of: viewport, matching: find.byType(Scrollable))
          .first;
      double pixels() => tester.state<ScrollableState>(scroll).position.pixels;
      final start = pixels();
      expect(
        tester.state<ScrollableState>(scroll).position.maxScrollExtent,
        greaterThan(900),
      );
      await tester.dragFrom(const Offset(377, 270), const Offset(-220, 0));
      await _settle(tester);
      expect(pixels(), greaterThan(start));

      await tester.tapAt(const Offset(225, 240));
      await _settle(tester);
      expect(find.byTooltip('章节目录'), findsOneWidget);
      await tester.tap(find.byTooltip('章节目录'));
      await _settle(tester);
      expect(find.widgetWithText(ListTile, '第一章'), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await _settle(tester);
      await tester.tap(find.byTooltip('收起阅读菜单'));
      await _settle(tester);
      expect(find.byTooltip('章节目录'), findsNothing);

      await _changeMode(tester, '仿真翻页');
      expect(find.byType(ReaderCurl), findsOneWidget);
      final beforeCurl = pixels();
      await tester.dragFrom(const Offset(380, 290), const Offset(-225, 0));
      await _settle(tester);
      expect(pixels(), greaterThan(beforeCurl));

      await _changeMode(tester, '纵向分页');
      final beforeVerticalPage = pixels();
      await tester.dragFrom(const Offset(220, 420), const Offset(0, -210));
      await _settle(tester);
      expect(pixels(), greaterThan(beforeVerticalPage));

      await _changeMode(tester, '连续滚动');
      final beforeScroll = pixels();
      await tester.dragFrom(const Offset(220, 420), const Offset(0, -155));
      await _settle(tester);
      expect(pixels(), greaterThan(beforeScroll));
      Future<int> storedOffset() async {
        await tester.pump(const Duration(seconds: 4));
        return (await tester.runAsync(() async {
          final position = (await fixture.store.read(fixture.key)) as Map;
          return position['sourceOffset'] as int;
        }))!;
      }

      final source = await storedOffset();
      expect(source, greaterThan(0));
      final canonical = tester.widget<EpubHtmlViewport>(viewport).source.text;
      final paragraph = RegExp(
        r'段落 \d+',
      ).allMatches(canonical.substring(0, source + 8)).last.group(0)!;
      final markedStart = canonical.indexOf(paragraph);
      await tester.runAsync(
        () => fixture.marks.save(
          ReadingMark(
            digest: fixture.digest,
            section: 0,
            range: (start: markedStart, end: markedStart + paragraph.length),
            quote: paragraph,
            style: ReadingMarkStyle.highlight,
            bookmark: true,
          ),
        ),
      );
      void expectOriginalParagraph() {
        final original = find.textContaining('$paragraph ', findRichText: true);
        expect(original, findsOneWidget);
        expect(tester.getBottomLeft(original).dy, greaterThan(0));
        expect(tester.getTopLeft(original).dy, lessThan(610));
      }

      await tester.tap(find.byTooltip('阅读菜单'));
      await _settle(tester);
      await tester.tap(find.byTooltip('阅读样式'));
      await _settle(tester);
      await tester.tap(find.byTooltip('增大字号'));
      await _settle(tester);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await _settle(tester);
      expect(await storedOffset(), source);
      expectOriginalParagraph();

      await tester.tap(find.byTooltip('切换横排／竖排'));
      await _settle(tester);
      final columns = find.byType(VerticalBookText);
      expect(columns, findsOneWidget);
      expect(await storedOffset(), source);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);

      await _open(tester, fixture.reader, columns);
      expect(await storedOffset(), source);
      await tester.tap(find.byTooltip('阅读菜单'));
      await _settle(tester);
      await tester.tap(find.byTooltip('切换横排／竖排'));
      await _settle(tester);
      expect(pixels(), greaterThan(0));
      expect(await storedOffset(), source);
      expectOriginalParagraph();

      await tester.tap(find.byTooltip('阅读菜单'));
      await _settle(tester);
      await tester.tap(find.byTooltip('标注与关联书签'));
      await _settle(tester);
      await tester.tap(find.text(paragraph));
      await _settle(tester);
      expect(await storedOffset(), markedStart);
      expectOriginalParagraph();

      final position = tester.state<ScrollableState>(scroll).position;
      position.jumpTo(position.maxScrollExtent);
      await _settle(tester);
      await tester.dragFrom(const Offset(220, 432), const Offset(0, -210));
      await _settle(tester);
      expect(find.text('第二章', findRichText: true), findsOneWidget);
      await tester.dragFrom(const Offset(220, 246), const Offset(0, 210));
      await _settle(tester);
      expect(
        pixels(),
        closeTo(
          tester.state<ScrollableState>(scroll).position.maxScrollExtent,
          1,
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Future<void> _open(WidgetTester tester, Widget reader, Finder target) async {
  await tester.pumpWidget(reader);
  for (var i = 0; i < 250 && target.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(
    target,
    findsOneWidget,
    reason: tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .join(', '),
  );
  await _settle(tester);
}

Future<void> _changeMode(WidgetTester tester, String mode) async {
  await tester.tap(find.byTooltip('阅读菜单'));
  await _settle(tester);
  await tester.tap(find.byTooltip('阅读样式'));
  await _settle(tester);
  await tester.tap(find.text('更多样式'));
  await _settle(tester);
  await tester.tap(find.widgetWithText(ChoiceChip, mode));
  await _settle(tester);
  tester.state<NavigatorState>(find.byType(Navigator)).pop();
  await _settle(tester);
  await tester.tap(find.byTooltip('收起阅读菜单'));
  await _settle(tester);
}

List<int> _modeFixture() {
  final archive = ZipDecoder().decodeBytes(sampleEpub(vertical: true));
  final package = archive.findFile('OEBPS/book.opf')!;
  archive.addFile(
    ArchiveFile.string(
      package.name,
      utf8
          .decode(package.content)
          .replaceFirst(
            '</manifest>',
            '<item id="b" href="second.xhtml"/></manifest>',
          )
          .replaceFirst('</spine>', '<itemref idref="b"/></spine>'),
    ),
  );
  archive.addFile(
    ArchiveFile.string(
      'OEBPS/second.xhtml',
      '<html><body><h1>第二章</h1><p>跨章后可读。</p></body></html>',
    ),
  );
  final body = List.generate(
    90,
    (i) => '<p>段落 $i 阅读示例文字，保留章节内的分页及位置。</p>',
  ).join();
  archive.addFile(
    ArchiveFile.string(
      'OEBPS/chapter.xhtml',
      '<html><head><link rel="stylesheet" href="style.css"/></head>'
          '<body><h1>第一章</h1>$body</body></html>',
    ),
  );
  return ZipEncoder().encode(archive);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 40));
    if (!tester.binding.hasScheduledFrame) return;
    if (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
  }
  expect(
    tester.binding.hasScheduledFrame,
    isFalse,
    reason: "Reader never settled",
  );
}
