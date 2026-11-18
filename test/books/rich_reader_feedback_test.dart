import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/presentation/reader_style.dart';
import 'package:zero_player/features/books/presentation/rich_reader_page.dart';

import '../../test_support/local_book_fixtures.dart';

void main() {
  testWidgets(
    'one-screen EPUB clears old offset and tolerates identical policy notifications',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final setup = await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'rich-reader-feedback-',
        );
        final services = AppServices.scoped(root, AppDatabase.memory());
        await services.settings.load();
        await services.supervision.load();
        final source = await File(
          '${root.path}/sample.epub',
        ).writeAsBytes(sampleEpub());
        final book = await services.books.importLocal(source);
        await services.books.store.write(
          'books_reader_preferences',
          const ReaderPreferences(
            mode: ReaderTurnMode.scroll,
            family: 'system',
            immersive: false,
          ).toJson(),
        );
        await services.books.store.write('rich_position_${book.id}', {
          'index': 0,
          'horizontal': true,
          'offset': 123.0,
        });
        return (root: root, services: services, book: book);
      });
      final fixture = setup!;
      addTearDown(() async {
        await fixture.services.close();
        await fixture.root.delete(recursive: true);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: RichReaderPage(
            repository: fixture.services.books,
            book: fixture.book,
            file: fixture.services.books.documentFile(fixture.book, 'epub'),
          ),
        ),
      );
      for (
        var i = 0;
        i < 80 && find.byType(SingleChildScrollView).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.byType(SingleChildScrollView), findsWidgets);
      await tester.pump();
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      expect(scrollable.position.maxScrollExtent, 0);
      fixture.services.contentPolicy.refresh();
      await tester.pump();
      expect(find.textContaining('内容策略已变更'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        final saved = await fixture.services.books.store.read(
          'rich_position_${fixture.book.id}',
        );
        expect((saved as Map)['offset'], 0.0);
      });
      expect(tester.takeException(), isNull);
    },
  );
}
