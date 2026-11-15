import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/aoaostar_book_catalog.dart';
import 'package:zero_player/features/books/data/book_image_payload.dart';
import 'package:zero_player/features/books/domain/book.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'published comic source resolves a decodable chapter image',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('zero-comic-online-');
      final services = AppServices.scoped(root, AppDatabase.memory());
      try {
        await services.settings.load();
        await services.supervision.load();
        await tester.pumpWidget(const SizedBox());
        final catalog = await AoaoStarBookCatalog.load();
        final imported = await catalog.read(packId: 'b778fe6b');
        final source = imported.sources.firstWhere(
          (item) =>
              item.kind == BookKind.comic &&
              item.endpoint.host == 'xapi.xinmanhua.net' &&
              item.name == '🎨新漫画',
        );
        final client = services.books.client;
        final token = CancellationToken();
        final results = await client.books(source, '镖人', token);
        expect(results, isNotEmpty);
        final work = results.firstWhere(
          (book) => book.title.contains('镖人'),
          orElse: () => results.first,
        );
        final details = await client.details(source, work, token);
        final chapters = await client.chapters(source, details, token);
        expect(chapters.length, greaterThan(10));
        final readable = chapters.where(
          (chapter) => chapter.uri.host == 'xapi.xinmanhua.net',
        );
        expect(readable, isNotEmpty);
        final chapter = readable.first;
        final images = await client.chapterImages(
          source,
          chapter,
          token,
          book: details,
        );
        expect(images, isNotEmpty);
        expect(images.first.host, 'works.xinmanhua.net');
        final payload = await client.fetch(
          source,
          images.first,
          token,
          media: true,
          maxBytes: 4 * 1024 * 1024,
        );
        expect(payload.bytes.length, greaterThan(1024));
        await validateReadableBookImage(images.first, payload.bytes);
        debugPrint(
          'comic ${source.name}: ${results.length} search results, '
          '${chapters.length} chapters, ${images.length} images, '
          '${payload.bytes.length} image bytes',
        );
      } finally {
        await services.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
