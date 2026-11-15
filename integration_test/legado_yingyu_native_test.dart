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
    'bundled English source reads bilingual and plain English books',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('zero-yingyu-online-');
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
              'd4deb7207faa8e5a38459520f6444b13647e7864e65deb83e155362fda135d56',
        );
        final token = CancellationToken();
        final changes = await services.books.importSources([source]);
        expect(changes.added, 1);
        await services.books.saveSource(source, {'enabled': true});
        final found = await services.books.find(
          BookKind.text,
          'Pride',
          token,
          sourceId: source.id,
        );
        final bilingual = found.books.firstWhere(
          (item) => item.uri.path == '/book/2c527ddefc34d4bb',
        );
        expect(bilingual.title, contains('Pride and Prejudice'));
        expect(bilingual.author, '简·奥斯汀');
        expect(bilingual.description, isNotEmpty);
        final details = await services.books.details(bilingual, token);
        expect(details.author, '简·奥斯汀');
        final chapters = await services.books.chapters(
          details,
          token,
          refresh: true,
        );
        expect(chapters.length, greaterThan(10));
        final first = chapters.firstWhere(
          (item) => item.uri.path == '/book/2c527ddefc34d4bb/chapter/0',
        );
        final bilingualText = await services.books.readText(
          details,
          first,
          token,
        );
        expect(bilingualText.length, greaterThan(10000));

        final english = found.books.firstWhere(
          (item) => item.uri.path == '/book/0c563d84a469185b',
        );
        final englishDetails = await services.books.details(english, token);
        final englishChapters = await services.books.chapters(
          englishDetails,
          token,
          refresh: true,
        );
        expect(englishChapters.length, greaterThan(40));
        final englishFirst = englishChapters.firstWhere(
          (item) => item.uri.path == '/book/0c563d84a469185b/chapter/0',
        );
        final englishText = await services.books.readText(
          englishDetails,
          englishFirst,
          token,
        );
        expect(englishText.length, greaterThan(1000));
        debugPrint(
          'English Legado: ${found.books.length} search, '
          '${chapters.length}/${englishChapters.length} chapters, '
          '${bilingualText.length}/${englishText.length} characters',
        );
      } finally {
        await services.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
