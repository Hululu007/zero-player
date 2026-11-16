import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/aoaostar_book_catalog.dart';
import 'package:zero_player/features/books/domain/book.dart';

import '../test_support/verified_temp_directory.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'bundled QQ Reading source searches and reads an available chapter',
    (tester) async {
      final temporary = await VerifiedTempDirectory.create('zero-qq-reading-');
      final root = temporary.directory;
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
              'd6238338a2720edc88eb06d920d7438c69fab9f7f25cb61a0beff9a49ebfeba4',
        );
        final token = CancellationToken();
        expect((await services.books.importSources([source])).added, 1);
        await services.books.saveSource(source, {'enabled': true});
        final found = await services.books.find(
          BookKind.text,
          '三国演义',
          token,
          sourceId: source.id,
        );
        final book = found.books.firstWhere(
          (item) => item.uri.path == '/book-detail/29855984',
        );
        expect(book.title, '三国演义');
        expect(book.author, '(明)罗贯中');
        final details = await services.books.details(book, token);
        expect(details.author, '(明)罗贯中');
        expect(Uri.parse(details.cover).scheme, 'https');
        final chapters = await services.books.chapters(
          details,
          token,
          refresh: true,
        );
        expect(chapters.length, greaterThan(100));
        final first = chapters.firstWhere(
          (item) => item.uri.path == '/book-read/29855984/8',
        );
        final text = await services.books.readText(details, first, token);
        expect(text.length, greaterThan(2000));
        debugPrint(
          'QQ Reading Legado: ${found.books.length} search results, '
          '${chapters.length} chapters, ${text.length} characters',
        );
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
