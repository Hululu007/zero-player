import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/aoaostar_book_catalog.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_search.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'bundled Jingzhi source searches and reads a free chapter',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'zero-jingzhi-online-',
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
              'e48858cda3b048659b3084eeb23ee97018ca2f07d0d4900d2a1ef5eba055773a',
        );
        final token = CancellationToken();
        final changes = await services.books.importSources([source]);
        expect(changes.added, 1);
        await services.books.saveSource(source, {'enabled': true});
        final result = await services.books.find(
          BookKind.text,
          '三国',
          token,
          sourceId: source.id,
        );
        final book = result.books.firstWhere(
          (item) => item.uri.path == '/books/1002',
        );
        expect(book.title, '三国之捣乱天下');
        expect(book.author, '月月月光光');
        expect(book.description.length, greaterThan(20));
        expect(
          BookSearchQuery('三国', BookSearchField.author).rank(book),
          isNull,
        );
        final details = await services.books.details(book, token);
        final chapters = await services.books.chapters(
          details,
          token,
          refresh: true,
        );
        expect(chapters.length, greaterThan(100));
        final chapter = chapters.firstWhere(
          (item) => item.uri.path == '/chapter/read/1002/84359',
        );
        final text = await services.books.readText(details, chapter, token);
        expect(text.length, greaterThan(100));
        debugPrint(
          'Jingzhi Legado: ${result.books.length} search, '
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
