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
    'bundled Shubang search and one chapter stay within the chapter',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'zero-shubang-online-',
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
              '981adf7639a1c61e23ad4104e4e11b3553439b9ea22599c1b429881ace889402',
        );
        final token = CancellationToken();
        final changes = await services.books.importSources([source]);
        expect(changes.added, 1);
        await services.books.saveSource(source, {'enabled': true});
        final found = await services.books.find(
          BookKind.text,
          '傲慢',
          token,
          sourceId: source.id,
        );
        final book = found.books.firstWhere(
          (item) => item.uri.path == '/book/209.html',
        );
        expect(book.title, contains('傲慢与偏见'));
        final details = await services.books.details(book, token);
        expect(details.author, contains('奥斯汀'));
        final chapters = await services.books.chapters(
          details,
          token,
          refresh: true,
        );
        expect(chapters.length, greaterThan(40));
        final chapter = chapters.firstWhere(
          (item) => item.uri.path == '/book/209_5934.html',
        );
        final text = await services.books.readText(details, chapter, token);
        expect(text, contains('It is a truth universally acknowledged'));
        expect(text, contains('Mr. Bennet was so odd a mixture'));
        expect(text, isNot(contains('Mr. Bennet was among the earliest')));
        debugPrint(
          'Shubang Legado: ${found.books.length} search, '
          '${chapters.length} chapters, ${text.length} characters in the first chapter',
        );
      } finally {
        await services.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
