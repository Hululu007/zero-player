import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_download_plan.dart';
import 'package:zero_player/features/books/presentation/book_download_management_page.dart';

import '../../test_support/book_fixture_source.dart';
import '../../test_support/mobile_app_fixture.dart';

void main() {
  testWidgets(
    'download manager retains failure details with a retry action after reopening',
    (tester) async {
      final f = MobileAppFixture();
      await tester.runAsync(f.initialize);
      addTearDown(() => f.finish(tester));
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final source = bookFixtureSource('failure-report.example');
        await f.services.books.importSources([source]);
        final book = Book(
          source.id,
          BookKind.text,
          '失败章节测试',
          '作者',
          source.endpoint.resolve('/book'),
        );
        final chapters = List.generate(
          1000,
          (i) => BookChapter('章节 ${i + 1}', source.endpoint.resolve('/$i')),
        );
        await f.services.books.store.saveBook(book, chapters: chapters);
        await f.services.books.store.write(
          'books_download:${book.id}',
          const BookDownloadPlan(1, 1000, false).toJson(),
        );
        await f.services.books.store.write(
          'books_download_failures:${book.id}',
          {chapters.last.id: '下载失败，请检查来源或网络'},
        );
      });
      await tester.pumpWidget(
        MaterialApp(home: BookDownloadManagementPage(services: f.services)),
      );
      for (
        var i = 0;
        i < 40 && find.textContaining('下载失败 1 章').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.textContaining('下载失败 1 章'), findsOneWidget);
      await tester.tap(find.byTooltip('管理下载'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('失败章节与重试'));
      await tester.pumpAndSettle();
      expect(find.text('第1000章 · 章节 1000'), findsOneWidget);
      expect(find.text('重试未完成章节'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
    },
  );
}
