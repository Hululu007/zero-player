import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/aoaostar_book_catalog.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/legado_source_fingerprint.dart';

import '../test_support/verified_temp_directory.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'bundled Bishang source discovers and reads one sampled chapter',
    (tester) async {
      final temporary = await VerifiedTempDirectory.create('zero-bishang-');
      final services = AppServices.scoped(
        temporary.directory,
        AppDatabase.memory(),
      );
      try {
        await services.settings.load();
        await services.supervision.load();
        await tester.pumpWidget(const SizedBox());
        final parsed = await (await AoaoStarBookCatalog.load()).read();
        final source = parsed.sources.firstWhere(
          (item) =>
              item.id ==
              '22fd5687b4cd8b42ce1d69d0701148e989f39833d7d94b1e1dae73795084e242',
        );
        expect(
          legadoSourceFingerprint(source.legado!),
          '5e0ce5b6c43db101d89212f26fab8528e17f91a7c1c2cd82085c62d84e45c43c',
        );
        final token = CancellationToken();
        expect((await services.books.importSources([source])).added, 1);
        await services.books.saveSource(source, {'enabled': true});
        final categories = await services.books.categories(
          BookKind.text,
          source.id,
          token,
        );
        final fantasy = categories.firstWhere((item) => item.title == '玄幻');
        final listing = await services.books.discover(
          BookKind.text,
          source.id,
          token,
          category: fantasy,
        );
        expect(listing.books, isNotEmpty);
        final book = listing.books.first;
        expect(book.title, isNotEmpty);
        final details = await services.books.details(book, token);
        final chapters = await services.books.chapters(
          details,
          token,
          refresh: true,
        );
        expect(chapters, isNotEmpty);
        final text = await services.books.readText(
          details,
          chapters.first,
          token,
        );
        expect(text.length, greaterThan(100));
        final found = await services.books.find(
          BookKind.text,
          book.title,
          token,
          sourceId: source.id,
        );
        final matches = found.books
            .where((item) => item.title == book.title)
            .length;
        debugPrint(
          'Bishang Legado: ${categories.length} categories, '
          '${listing.books.length} discovery results, ${chapters.length} chapters, '
          '${text.length} characters, ${found.books.length} search results, '
          '$matches exact matches',
        );
        expect(matches, greaterThan(0));
      } finally {
        try {
          await services.close();
        } finally {
          await temporary.delete();
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
