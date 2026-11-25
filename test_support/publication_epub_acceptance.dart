import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/features/books/data/reading_marks_store.dart';
import 'package:zero_player/features/books/data/rich_book.dart';
import 'package:zero_player/features/books/domain/reading_mark.dart';
import 'package:zero_player/features/books/presentation/epub_html_viewport.dart';
import 'package:zero_player/features/books/presentation/epub_source.dart';
import 'package:zero_player/features/books/presentation/reader_style.dart';
import 'package:zero_player/features/books/presentation/rich_reader_page.dart';

Future<void> verifyPublicationEpubAcceptance(
  WidgetTester tester,
  AppServices services,
  Future<void> Function() reopen,
) async {
  final reader = tester.widget<RichReaderPage>(find.byType(RichReaderPage));
  final access = reader.document!;
  final book = reader.book;
  final chapter = access.chapters.indexWhere(
    (item) => item.title == 'Introduction',
  );
  expect(chapter, isNonNegative);
  final sections = await readRichEpubOffThread(await reader.file.readAsBytes());
  const paragraph = 'This book aims to characterise';
  final text = EpubSource(sections[chapter].html).text;
  final offset = text.indexOf(paragraph);
  expect(offset, greaterThan(0));
  await _closeRoute(tester);
  await access.savePosition((
    index: chapter,
    horizontal: true,
    verticalPage: 0,
    sourceOffset: offset,
    offset: 0.0,
    fraction: 0.0,
  ));
  await reopen();
  final viewport = find.byType(EpubHtmlViewport);
  EpubHtmlViewport current() => tester.widget<EpubHtmlViewport>(viewport);
  final line = find
      .descendant(
        of: viewport,
        matching: find.textContaining(paragraph, findRichText: true),
      )
      .first;
  await tester.pumpAndSettle();
  _expectRenderedPassage(tester, viewport, line);

  final original = current().preferences;
  await _openReaderMenu(tester);
  await tester.tap(find.byTooltip('阅读样式'));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('增大字号'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('更多样式'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(ChoiceChip, '连续滚动'));
  await tester.pumpAndSettle();
  await _closeRoute(tester);
  expect(current().preferences.fontSize, greaterThan(original.fontSize));
  expect(current().preferences.mode, ReaderTurnMode.scroll);
  _expectRenderedPassage(tester, viewport, line);
  await _closeRoute(tester);
  await reopen();
  await tester.pumpAndSettle();
  _expectRenderedPassage(tester, viewport, line);
  expect((await access.loadPosition())?.sourceOffset, offset);

  final render = tester.renderObject<RenderParagraph>(line);
  final firstWord = render
      .getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: 4))
      .first
      .toRect()
      .center;
  await tester.longPressAt(render.localToGlobal(firstWord));
  await tester.pumpAndSettle();
  await tester.tap(find.text('添加标注'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('波浪线'));
  await tester.tap(find.text('关联书签'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('保存标注'));
  await tester.pumpAndSettle();

  final marks = ReadingMarksStore(services.books.store, book, access.isAllowed);
  final mark = (await marks.load(digest: book.uri.path)).single;
  expect(mark.section, chapter);
  expect(mark.bookmark, isTrue);
  expect(mark.style, ReadingMarkStyle.wave);
  expect(text.substring(mark.range.start, mark.range.end), mark.quote);
  await _closeRoute(tester);
  final module = services.publications;
  final backup = await File(
    '${services.root.path}/acceptance-backup.json',
  ).writeAsString(await module.output.backup.encode());
  await marks.delete(mark);
  await module.store.db.write(
    'DELETE FROM publication_positions WHERE digest=?',
    [book.uri.path],
  );
  expect(await access.loadPosition(), isNull);
  expect(await marks.load(digest: book.uri.path), isEmpty);
  await module.output.backup.restore(backup);
  expect((await access.loadPosition())?.sourceOffset, offset);
  expect((await marks.load(digest: book.uri.path)).single.range, mark.range);
  await reopen();
  await tester.pumpAndSettle();
  await _openReaderMenu(tester);
  await tester.tap(find.byTooltip('标注与关联书签'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(mark.quote));
  await tester.pumpAndSettle();
  _expectRenderedPassage(tester, viewport, line);
  debugPrint(
    'Publication ${Platform.operatingSystem} EPUB position and mark restored',
  );
}

Future<void> _openReaderMenu(WidgetTester tester) async {
  final menu = find.byTooltip('阅读菜单');
  if (menu.evaluate().isEmpty) return;
  await tester.tap(menu);
  await tester.pumpAndSettle();
}

Future<void> _closeRoute(WidgetTester tester) async {
  tester.state<NavigatorState>(find.byType(Navigator).first).pop();
  await tester.pumpAndSettle();
}

void _expectRenderedPassage(WidgetTester tester, Finder viewport, Finder line) {
  expect(line, findsOneWidget);
  expect(tester.getRect(viewport).overlaps(tester.getRect(line)), isTrue);
}
