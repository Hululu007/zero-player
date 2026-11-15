import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/aoaostar_book_catalog.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'bundled Dushu Legado source reads a current online chapter',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('zero-dushu-online-');
      final services = AppServices.scoped(root, AppDatabase.memory());
      try {
        await services.settings.load();
        await services.supervision.load();
        await tester.pumpWidget(const SizedBox());
        final catalog = await AoaoStarBookCatalog.load();
        final sources = await catalog.read(packId: 'b778fe6b');
        final source = sources.sources.firstWhere(
          (source) =>
              source.endpoint.host == 'www.dushu.com' &&
              source.endpoint.path == '/xiaoshuo' &&
              source.legado?.rules['content'] == 'class.content_txt@html',
        );
        final token = CancellationToken();
        final client = services.books.client;
        final found = await client.books(source, '三国演义', token);
        final book = found.firstWhere((book) => book.title == '三国演义');
        expect(book.author, isNotEmpty);
        final details = await client.details(source, book, token);
        final chapters = await client.chapters(source, details, token);
        expect(chapters.length, greaterThan(20));
        final text = await client.text(
          source,
          chapters.first,
          token,
          book: details,
        );
        expect(text.length, greaterThan(100));
        debugPrint(
          'Dushu Legado: ${found.length} results, '
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
