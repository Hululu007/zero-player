import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/books/data/book_chapter_policy.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/book_text_policy_dialog.dart';
import 'package:zero_player/features/books/presentation/book_blocked_chapters_dialog.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';
import '../../test_support/mobile_app_fixture.dart';

void main() {
  testWidgets('verified replacement editor saves paragraph rules on a phone', (
    tester,
  ) async {
    final fixture = MobileAppFixture();
    await tester.runAsync(() async {
      await fixture.initialize();
      final guard = fixture.services.supervision;
      await guard.saveCredentials(
        await guard.prepareCredentials('fixture-password'),
      );
    });
    addTearDown(() => fixture.finish(tester));
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 740);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final books = fixture.services.books;
    var saved = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                await showBookTextReplacements(context, books);
                saved = true;
              },
              child: const Text('管理替换'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('管理替换'));
    await fixture.settle(tester);
    await tester.enterText(find.byType(TextField), 'fixture-password');
    await tester.tap(find.text('验证并继续'));
    await fixture.waitFor(
      tester,
      () => find.text('添加替换规则').evaluate().isNotEmpty,
    );
    await tester.ensureVisible(find.text('添加替换规则'));
    await tester.tap(find.text('添加替换规则'));
    await fixture.settle(tester);
    await tester.enterText(find.byType(TextField).at(0), '待替换');
    await tester.enterText(find.byType(TextField).at(1), '已处理');
    await tester.ensureVisible(find.byType(SwitchListTile));
    await tester.tap(find.byType(SwitchListTile));
    await tester.tap(find.text('添加').last);
    await fixture.settle(tester);
    expect(find.text('待替换'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await fixture.waitFor(tester, () => saved);
    BookTextReplacement? savedRule;
    final checking = fixture.services.supervision.execute(
      SensitiveOperation.supervision,
      () async {
        savedRule = books.chapterPolicy.rulesForReview().single;
      },
      password: 'fixture-password',
    );
    await fixture.waitFor(tester, () => savedRule != null);
    await checking;
    expect(savedRule!.paragraph, isTrue);
    expect(savedRule!.apply('前文\n含待替换文字\n后文'), '前文\n已处理\n后文');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'large blocked chapter report stays lazy and scrolls in landscape',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(640, 320);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      var reviewed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showBlockedChaptersDialog(
                  context,
                  chapters: [
                    for (var i = 1; i <= 1000; i++)
                      (
                        position: i,
                        reason: '成人正文规则命中',
                        review: () => reviewed = true,
                      ),
                  ],
                  replacements: () {},
                ),
                child: const Text('报告'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('报告'));
      await tester.pumpAndSettle();
      expect(find.byType(ListTile).evaluate().length, lessThan(20));
      await tester.scrollUntilVisible(
        find.text('目录第 2 章'),
        60,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.ensureVisible(find.text('目录第 2 章'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('目录第 2 章'));
      expect(reviewed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'phone diagnostics require password and disappear on revocation',
    (tester) async {
      final fixture = MobileAppFixture();
      await tester.runAsync(() async {
        await fixture.initialize();
        final guard = fixture.services.supervision;
        await guard.saveCredentials(
          await guard.prepareCredentials('fixture-password'),
        );
        await fixture.services.books.chapterPolicy.load();
      });
      addTearDown(() => fixture.finish(tester));
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 740);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final books = fixture.services.books;
      final book = Book(
        'local',
        BookKind.text,
        '测试',
        '',
        Uri.parse('file:///test.txt'),
      );
      final chapter = BookChapter('一', Uri.parse('file:///1'));
      late ChapterContentBlocked block;
      try {
        books.chapterPolicy.prepare(book, chapter, '包含色情的普通上下文');
      } on ChapterContentBlocked catch (error) {
        block = error;
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  Text(block.message),
                  TextButton(
                    onPressed: () =>
                        reviewBlockedChapter(context, books, block),
                    child: const Text('验证复核'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('色情'), findsNothing);
      await tester.tap(find.text('验证复核'));
      await fixture.settle(tester);
      expect(find.text('验证监管密码'), findsOneWidget);
      expect(find.textContaining('命中关键词'), findsNothing);
      await tester.enterText(find.byType(TextField), 'fixture-password');
      await tester.tap(find.text('验证并继续'));
      for (
        var i = 0;
        i < 30 && find.textContaining('命中关键词').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(find.textContaining('命中关键词：色情'), findsOneWidget);
      expect(tester.takeException(), isNull);
      fixture.services.supervision.invalidatePermissions();
      fixture.services.contentPolicy.refresh();
      await fixture.settle(tester);
      expect(find.textContaining('命中关键词'), findsNothing);
      expect(find.text('验证已失效'), findsOneWidget);
    },
  );
}
