import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/widgets.dart';
import 'package:zero_player/features/books/presentation/reader_pagination.dart';
import 'package:zero_player/features/books/presentation/reader_style.dart';
import 'package:zero_player/features/books/presentation/book_reader_page.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/book_text_policy_dialog.dart';
import 'package:zero_player/features/settings/presentation/settings_page.dart';
import '../../test_support/mobile_app_fixture.dart';

void main() {
  _repeatKeyTest();
  _blankLineTests();
  _retainedFutureTest();
  _choiceFailureTest();
  _corruptRulesEditorTest();
}

void _corruptRulesEditorTest() {
  testWidgets('password-authorized editor can repair corrupt chapter rules', (
    tester,
  ) async {
    final fixture = MobileAppFixture();
    await tester.runAsync(() async {
      await fixture.initialize();
      final guard = fixture.services.supervision;
      await guard.saveCredentials(
        await guard.prepareCredentials('test-password'),
      );
      await fixture.services.books.store.write('books_chapter_policy:v1', {
        'rules': [42],
        'exceptions': [],
      });
    });
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showBookTextReplacements(context, fixture.services.books),
                child: const Text('管理规则'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('管理规则'));
      await fixture.settle(tester);
      await tester.enterText(find.byType(TextField), 'test-password');
      await tester.tap(find.text('验证并继续'));
      await fixture.waitFor(
        tester,
        () => find.text('重新保存规则').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('重新保存规则'));
      await fixture.waitFor(
        tester,
        () => find.text('添加替换规则').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('保存'));
      await fixture.settle(tester);
      expect(
        await tester.runAsync(
          () => fixture.services.books.store.read('books_chapter_policy:v1'),
        ),
        {'rules': [], 'exceptions': []},
      );
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.finish(tester);
    }
  });
}

void _blankLineTests() {
  testWidgets('blank-line page boundaries always render positive line counts', (
    tester,
  ) async {
    for (final mode in [ReaderTurnMode.slide, ReaderTurnMode.scroll]) {
      final key = GlobalKey<ReaderViewportState>();
      final text = '\n\n标题\n\n${'正文\n\n' * 30}';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: SizedBox(
                  width: 180,
                  height: 48,
                  child: ReaderViewport(
                    key: key,
                    text: text,
                    titleLength: 0,
                    style: const TextStyle(fontSize: 21, height: 1.5),
                    palette: ReaderPaper.white.palette(
                      Theme.of(context).colorScheme,
                    ),
                    mode: mode,
                    animate: false,
                    texture: false,
                    margin: 0,
                    initial: readerProgress(0),
                    onProgress: (_) {},
                    canCross: (_) => false,
                    onBoundary: (_) {},
                    onSelection: (_) {},
                    onAnnotate: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < 15; i++) {
        expect(tester.takeException(), isNull);
        for (final widget in tester.widgetList<Text>(find.byType(Text))) {
          expect(widget.maxLines == null || widget.maxLines! > 0, isTrue);
        }
        key.currentState!.turn(1);
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox());
    }
  });
}

void _retainedFutureTest() {
  testWidgets(
    'LoadView retains list state and scroll while a replacement future waits',
    (tester) async {
      Future<List<int>> future = Future.value(List.generate(100, (i) => i));
      late StateSetter refresh;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) {
                refresh = update;
                return LoadView(
                  future: future,
                  builder: (items) => ListView(
                    children: [
                      for (final i in items) ListTile(title: Text('来源 $i')),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -800));
      await tester.pumpAndSettle();
      final state = tester.state<ScrollableState>(find.byType(Scrollable));
      final pixels = state.position.pixels;
      expect(pixels, greaterThan(0));
      final pending = Completer<List<int>>();
      refresh(() {
        future = pending.future;
      });
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester.state<ScrollableState>(find.byType(Scrollable)),
        same(state),
      );
      expect(state.position.pixels, pixels);
      pending.complete(List.generate(101, (i) => i));
      await tester.pumpAndSettle();
      expect(state.position.pixels, pixels);
    },
  );
}

void _choiceFailureTest() {
  testWidgets('rejected settings choice keeps the committed value visible', (
    tester,
  ) async {
    final fixture = MobileAppFixture();
    await tester.runAsync(() async {
      await fixture.initialize();
      await fixture.services.db.customStatement(
        "CREATE TRIGGER reject_choice BEFORE INSERT ON settings WHEN NEW.key='searchConcurrency' "
        "BEGIN SELECT RAISE(ABORT,'fixture write failure'); END",
      );
    });
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SettingsPage(services: fixture.services)),
        ),
      );
      final choice = find.byKey(const ValueKey('searchConcurrency/8'));
      await tester.scrollUntilVisible(choice, 500);
      await tester.pumpAndSettle();
      await tester.tap(choice.first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('16 路').last);
      await fixture.settle(tester);
      expect(tester.widget<DropdownButton<String>>(choice.first).value, '8');
      expect(fixture.services.settings.value.searchConcurrency, 8);
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.finish(tester);
    }
  });
}

void _repeatKeyTest() {
  testWidgets('reader advances once for a held direction or page key', (
    tester,
  ) async {
    final fixture = MobileAppFixture();
    final book = Book(
      'local',
      BookKind.text,
      '书',
      '',
      Uri.parse('book:repeat'),
    );
    final chapter = BookChapter('第一章', Uri.parse('book:repeat#1'));
    await tester.runAsync(() async {
      await fixture.initialize();
      await fixture.services.books.store.saveText(
        book,
        chapter,
        '正文内容。\n' * 500,
      );
    });
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: BookReaderPage(
            repository: fixture.services.books,
            book: book,
            chapters: [chapter],
            initial: chapter,
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final key in [
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.pageDown,
      ]) {
        await tester.sendKeyDownEvent(key);
        await tester.pumpAndSettle();
        final label = tester
            .widget<Text>(find.textContaining(RegExp(r'\d+ / \d+')))
            .data;
        for (var i = 0; i < 3; i++) {
          await tester.sendKeyRepeatEvent(key);
          await tester.pumpAndSettle();
          expect(
            tester.widget<Text>(find.textContaining(RegExp(r'\d+ / \d+'))).data,
            label,
          );
        }
        await tester.sendKeyUpEvent(key);
      }
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.finish(tester);
    }
  });
}
