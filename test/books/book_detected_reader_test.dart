import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/book_reader_page.dart';

import '../../test_support/mobile_app_fixture.dart';

void main() {
  testWidgets('the reader resumes after setting automatic replacement', (
    tester,
  ) async {
    final fixture = MobileAppFixture();
    final book = Book(
      'local',
      BookKind.text,
      '试读作品',
      '',
      Uri.parse('book:redaction'),
    );
    final chapter = BookChapter('第一章', book.uri.replace(fragment: '1'));
    await tester.runAsync(() async {
      await fixture.initialize();
      final store = fixture.services.books.store;
      await store.saveBook(book, chapters: [chapter]);
      await store.saveText(book, chapter, '保留开篇。某处出现色・情标签。保留结尾。');
    });
    addTearDown(() => fixture.finish(tester));
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
    final edit = find.text('设置替换并继续阅读');
    await fixture.waitFor(tester, () => edit.evaluate().isNotEmpty);
    await tester.tap(edit);
    await fixture.waitFor(
      tester,
      () => find.text('自动替换检测到的内容').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).last, '已隐藏');
    await tester.tap(find.text('保存并应用'));
    await fixture.waitFor(
      tester,
      () => find
          .textContaining('保留开篇。某处出现已隐藏标签。保留结尾。', findRichText: true)
          .evaluate()
          .isNotEmpty,
    );
    expect(find.textContaining('色・情', findRichText: true), findsNothing);
  });
}
