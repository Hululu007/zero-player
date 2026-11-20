import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/books/presentation/book_detail_page.dart';
import 'package:zero_player/features/books/presentation/book_edition_panel.dart';

import '../../test_support/book_editions_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _incrementalSwitchTest();
  _revokedResultsTest();
  _detailsActionsTest();
  _largeCatalogTest();
}

void _incrementalSwitchTest() {
  testWidgets(
    'detail shows and switches a checked channel while a slower one is pending at 320px',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = (await tester.runAsync(BookEditionsFixture.create))!;
      addTearDown(() async {
        await tester.runAsync(f.close);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: BookDetailPage(services: f.services, initial: f.book),
        ),
      );
      await _until(
        tester,
        () =>
            find.text('检测各渠道最新章节').evaluate().isNotEmpty &&
            find.text('开始阅读').evaluate().isNotEmpty,
      );
      await tester.ensureVisible(find.text('检测各渠道最新章节'));
      await tester.tap(find.text('检测各渠道最新章节'));
      await _until(
        tester,
        () =>
            find
                .textContaining('当前检测最新')
                .evaluate()
                .any((e) => (e.widget as Text).data!.contains('fast 渠道')) &&
            f.slowWaiting,
      );
      expect(f.slowReleased, isFalse);
      expect(find.textContaining('第5章 标题4'), findsWidgets);
      final row = find.widgetWithText(ListTile, 'fast 渠道');
      expect(find.text('failed 渠道'), findsNothing);
      await tester.ensureVisible(find.textContaining('显示全部渠道'));
      await tester.tap(find.textContaining('显示全部渠道'));
      await tester.pump();
      expect(find.text('failed 渠道'), findsOneWidget);
      await tester.tap(find.text('仅显示有书渠道'));
      await tester.pump();
      await tester.ensureVisible(row);
      await tester.tap(find.text('fast 渠道'));
      await tester.pump();
      expect(tester.widget<ListTile>(row).selected, isTrue);
      final jump = find.descendant(of: row, matching: find.text('跳转'));
      await tester.ensureVisible(jump);
      await tester.tap(jump);
      await _until(
        tester,
        () =>
            find
                .byType(BookEditionPanel)
                .evaluate()
                .any(
                  (e) =>
                      (e.widget as BookEditionPanel).book.sourceId ==
                      f.sources['fast']!.id,
                ) &&
            find
                .widgetWithText(FilledButton, '开始阅读')
                .evaluate()
                .any((e) => (e.widget as FilledButton).onPressed != null),
      );
      f.releaseSlow();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();
      expect(find.textContaining('第7章 标题6'), findsNothing);
      expect(find.text('收起渠道结果'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.runAsync(f.close);
    },
  );
}

void _revokedResultsTest() {
  testWidgets('source changes discard checked results and late updates', (
    tester,
  ) async {
    final f = (await tester.runAsync(BookEditionsFixture.create))!;
    addTearDown(() async {
      await tester.runAsync(f.close);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: BookEditionPanel(
              repository: f.services.books,
              book: f.book,
              busy: false,
              onSelected: (_) => fail('No channel was selected'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('检测各渠道最新章节'));
    await _until(
      tester,
      () => f.slowWaiting && find.text('fast 渠道').evaluate().isNotEmpty,
    );
    await tester.runAsync(
      () => f.services.books.saveSource(f.sources['fast']!, {'enabled': false}),
    );
    await tester.pump();
    expect(find.text('fast 渠道'), findsNothing);
    f.releaseSlow();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(find.textContaining('第7章 标题6'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.runAsync(f.close);
  });
}

void _detailsActionsTest() {
  testWidgets('disabling a source immediately offers another edition', (
    tester,
  ) async {
    final f = (await tester.runAsync(BookEditionsFixture.create))!;
    addTearDown(() => tester.runAsync(f.close));
    f.releaseSlow();
    await tester.pumpWidget(
      MaterialApp(
        home: BookDetailPage(services: f.services, initial: f.book),
      ),
    );
    await _until(tester, () => find.byTooltip('停用当前渠道').evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('停用当前渠道'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('停用并查找其他渠道'));
    await _until(
      tester,
      () =>
          find.text('选择其他可用渠道').evaluate().isNotEmpty &&
          find.text('fast 渠道').evaluate().isNotEmpty,
    );
    final disabled = await tester.runAsync(
      () => f.services.books.sourceEntry(f.book.kind, f.book.sourceId),
    );
    expect(disabled?.enabled, isFalse);
    expect(find.text('target 渠道（当前）'), findsNothing);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(f.close);
  });
}

void _largeCatalogTest() {
  testWidgets('chapter navigation jumps across pages and back to chapter one', (
    tester,
  ) async {
    final f = (await tester.runAsync(
      () => BookEditionsFixture.create(targetChapterCount: 160),
    ))!;
    addTearDown(() => tester.runAsync(f.close));
    await tester.pumpWidget(
      MaterialApp(
        home: BookDetailPage(services: f.services, initial: f.book),
      ),
    );
    await _until(tester, () => find.byTooltip('跳转章节').evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('跳转章节'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '125',
    );
    await tester.pump();
    await tester.tap(find.text('定位'));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
    expect(find.text('第125章 标题124').hitTestable(), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(FloatingActionButton),
        matching: find.byIcon(Icons.vertical_align_top),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('目录回到开头'));
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);
    expect(find.text('第1章 标题0').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(f.close);
  });
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 300; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    });
    await tester.pump(const Duration(milliseconds: 10));
    if (ready()) return;
  }
  fail('Timed out waiting for detail channel UI');
}
