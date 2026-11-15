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
    'bundled Kuwo text sources discover and read a free chapter',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('zero-kuwo-online-');
      final services = AppServices.scoped(root, AppDatabase.memory());
      try {
        await services.settings.load();
        await services.supervision.load();
        await tester.pumpWidget(const SizedBox());
        final catalog = await AoaoStarBookCatalog.load();
        final parsed = await catalog.read();
        const ids = {
          'e00ecd2dabff09c8b470cdec1aa7650f08b73902db2cc62a0e05272c3cf9dcbb',
          '12fb0618aded46ae1fb0fe2eef5e1c6735ca42442448f0b962b8fc023fe50d42',
        };
        final sources = parsed.sources
            .where((source) => ids.contains(source.id))
            .toList();
        expect(sources, hasLength(2));
        for (final source in sources) {
          final token = CancellationToken();
          final changes = await services.books.importSources([source]);
          expect(changes.added, 1);
          await services.books.saveSource(source, {'enabled': true});
          final categories = await services.books.categories(
            BookKind.text,
            source.id,
            token,
          );
          expect(categories.length, 26);
          final fantasy = categories.firstWhere(
            (entry) => entry.title == '玄幻' && entry.group == '男生',
          );
          final listing = await services.books.discover(
            BookKind.text,
            source.id,
            token,
            category: fantasy,
          );
          expect(listing.books, isNotEmpty);
          final found = await services.books.find(
            BookKind.text,
            '三国',
            token,
            sourceId: source.id,
          );
          final book = found.books.firstWhere(
            (entry) => entry.title == '三国之仲谋天下',
          );
          expect(book.author, isNotEmpty);
          final details = await services.books.details(book, token);
          final chapters = await services.books.chapters(
            details,
            token,
            refresh: true,
          );
          expect(chapters.length, greaterThan(100));
          final chapter = chapters.firstWhere(
            (entry) => entry.uri.path.endsWith('/96825218742211052'),
          );
          final text = await services.books.readText(details, chapter, token);
          expect(text.length, greaterThan(100));
          debugPrint(
            'Kuwo Legado ${source.id.substring(0, 12)}: ${categories.length} categories, '
            '${listing.books.length} discovery, ${found.books.length} search, '
            '${chapters.length} chapters, ${text.length} characters',
          );
        }
      } finally {
        await services.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
