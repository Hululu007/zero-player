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
    'bundled Yuque book list opens a current public document',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('zero-yuque-online-');
      final services = AppServices.scoped(root, AppDatabase.memory());
      try {
        await services.settings.load();
        await services.supervision.load();
        await tester.pumpWidget(const SizedBox());
        final catalog = await AoaoStarBookCatalog.load();
        final sources = await catalog.read();
        final source = sources.sources.firstWhere(
          (item) =>
              item.id ==
              'b6d2bbf620cb376b60bbadd9814c0a466f554b704b017dbeda592dcb31114b06',
        );
        final token = CancellationToken();
        final changes = await services.books.importSources([source]);
        expect(changes.added, 1);
        await services.books.saveSource(source, {'enabled': true});
        final categories = await services.books.categories(
          BookKind.text,
          source.id,
          token,
        );
        expect(categories, hasLength(1));
        final discovered = await services.books.discover(
          BookKind.text,
          source.id,
          token,
          category: categories.single,
        );
        expect(discovered.books.single.title, '书单互享');
        final found = await services.books.find(
          BookKind.text,
          '书单',
          token,
          sourceId: source.id,
        );
        final book = found.books.single;
        final details = await services.books.details(book, token);
        expect(details.author, isNotEmpty);
        final chapters = await services.books.chapters(
          details,
          token,
          refresh: true,
        );
        final chapter = chapters.firstWhere((item) => item.title == '无限流');
        final text = await services.books.readText(details, chapter, token);
        expect(text.length, greaterThan(100));
        debugPrint(
          'Yuque Legado: ${discovered.books.length} discovery, '
          '${found.books.length} search, ${chapters.length} public chapters, ${text.length} characters',
        );
      } finally {
        await services.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
