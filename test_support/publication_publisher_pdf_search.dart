import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/books/presentation/rich_reader_page.dart';

Future<void> verifyPublisherPdfSearch(
  WidgetTester tester,
  Widget publicationApp, {
  required String title,
  required int pages,
  required String query,
  required int hits,
  required int firstPage,
  required int nextPage,
}) async {
  final book = find.text(title).hitTestable();
  final menu = find.byTooltip('阅读菜单').hitTestable();
  final field = find.widgetWithText(TextField, '全文搜索');
  final reached = find.text('$nextPage / $pages');
  await tester.pumpWidget(publicationApp);
  try {
    await _tap(tester, find.text('书库'));
    await _tap(tester, book);
    await _tap(tester, menu);
    await _wait(tester, field);
    final search = Stopwatch()..start();
    await tester.enterText(field, query);
    await _wait(tester, find.text('$hits 项'));
    final searchMs = search.elapsedMilliseconds;

    await _tap(tester, find.byTooltip('下个结果'));
    await _wait(tester, reached);
    Navigator.of(tester.element(find.byType(RichReaderPage))).pop();
    await tester.pumpAndSettle();
    await _tap(tester, book);
    await _wait(tester, reached);
    await _tap(tester, menu);
    await _wait(tester, field);
    await tester.enterText(field, query);
    await _wait(tester, find.text('$hits 项'));
    await _wait(tester, find.text('$firstPage / $pages'));
    debugPrint(
      'Publication press PDF search $hits hits searchMs=$searchMs '
      'resumedPage=$nextPage/$pages backwardMatch=$firstPage/$pages '
      'peak=${ProcessInfo.maxRss}',
    );
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _wait(tester, finder);
  await tester.tap(finder.last);
}

Future<void> _wait(WidgetTester tester, Finder finder) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  expect(finder, findsWidgets);
}
