import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/aoaostar_book_catalog.dart';
import 'package:zero_player/features/books/domain/book.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'bundled Zhongyi source searches and reads a free chapter',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'zero-zhongyi-online-',
      );
      final services = AppServices.scoped(root, AppDatabase.memory());
      try {
        await services.settings.load();
        await services.supervision.load();
        await tester.pumpWidget(const SizedBox());
        final catalog = await AoaoStarBookCatalog.load();
        final parsed = await catalog.read();
        final source = parsed.sources.firstWhere(
          (item) =>
              item.id ==
              '83c8aed9fc6c4574a027a64d25988ced39ac5c8b7b3caa524217c2bf3c4dc70a',
        );
        final token = CancellationToken();
        final changes = await services.books.importSources([source]);
        expect(changes.added, 1);
        await services.books.saveSource(source, {'enabled': true});
        final first = await services.books.find(
          BookKind.text,
          '三国',
          token,
          sourceId: source.id,
        );
        final book = first.books.firstWhere(
          (item) => item.uri.path == '/books/bookinfo/1073',
        );
        expect(book.title, '重生三国，做最强军师');
        expect(book.author, '跳绳');
        final pageOne = await services.books.find(
          BookKind.text,
          '重生',
          token,
          sourceId: source.id,
          page: 1,
        );
        final pageTwo = await services.books.find(
          BookKind.text,
          '重生',
          token,
          sourceId: source.id,
          page: 2,
        );
        expect(pageOne.books, isNotEmpty);
        expect(pageTwo.books, isNotEmpty);
        expect(
          pageOne.books
              .map((item) => item.id)
              .toSet()
              .intersection(pageTwo.books.map((item) => item.id).toSet()),
          isEmpty,
        );
        final details = await services.books.details(book, token);
        final chapters = await services.books.chapters(
          details,
          token,
          refresh: true,
        );
        expect(chapters.length, greaterThan(100));
        final chapter = chapters.firstWhere(
          (item) => item.uri.path == '/chapter/read/1073/25062',
        );
        final text = await services.books.readText(details, chapter, token);
        expect(text.length, greaterThan(100));
        debugPrint(
          'Zhongyi Legado: ${first.books.length} search, '
          '${pageOne.books.length}/${pageTwo.books.length} paged search, '
          '${chapters.length} chapters, ${text.length} characters',
        );
      } finally {
        await services.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
