import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/book_download_management_page.dart';

import '../../test_support/verified_temp_directory.dart';

void main() {
  testWidgets(
    'retained offline catalogs stay reachable only in their own space',
    (tester) async {
      final temp = (await tester.runAsync(
        () => VerifiedTempDirectory.create('vault-manager-'),
      ))!;
      final services = AppServices.scoped(temp.directory, AppDatabase.memory());
      final store = services.books.store;
      final public = Book(
        'local',
        BookKind.text,
        '保留的公开离线书',
        '',
        Uri.parse('book:public'),
      );
      final private = Book(
        'local',
        BookKind.text,
        '保留的私密离线书',
        '',
        Uri.parse('book:private'),
      );
      final chapter = BookChapter('第一章', Uri.parse('book:chapter'));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await services.close();
          await temp.delete();
        });
      });
      await tester.runAsync(() async {
        await services.settings.load();
        await services.supervision.load();
        for (final book in [public, private]) {
          await store.saveBook(book, chapters: [chapter]);
          await store.saveText(book, chapter, '保留正文');
        }
        await store.vault.create('secret-123');
        await store.moveToVault(private);
        for (final book in [public, private]) {
          await store.removeFromShelf(book, clearOffline: false);
        }
      });
      await tester.pumpWidget(
        MaterialApp(home: BookDownloadManagementPage(services: services)),
      );
      await _wait(tester, () => find.text(public.title).evaluate().isNotEmpty);
      expect(find.text(private.title), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          home: BookDownloadManagementPage(services: services, private: true),
        ),
      );
      await _wait(tester, () => find.text(private.title).evaluate().isNotEmpty);
      expect(find.text(public.title), findsNothing);
      store.vault.lock();
      await tester.pump();
      expect(find.text(private.title), findsNothing);
    },
  );
}

Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(ready(), isTrue);
}
