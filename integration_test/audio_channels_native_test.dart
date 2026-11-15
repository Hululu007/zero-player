import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/domain/book.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  testWidgets(
    'Chinese audio sources search, download and decode offline',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'zero-audio-channels-',
      );
      final services = AppServices.scoped(root, AppDatabase.memory());
      try {
        await services.settings.load();
        await services.supervision.load();
        await tester.pumpWidget(const SizedBox());
        final books = services.books;
        final token = CancellationToken();
        final entries = await books.sources(BookKind.audio, enabledOnly: true);
        for (final (format, query, minimum) in [
          (BookFormat.shuyin, '西游记', 100),
          (BookFormat.bookan, '三国演义', 2),
          (BookFormat.ximalaya, '三国演义', 2),
          (BookFormat.lit2go, 'Alice', 2),
        ]) {
          final source = entries
              .singleWhere((entry) => entry.source.format == format)
              .source;
          final categories = await books.client.categories(source, token);
          expect(categories, isNotEmpty, reason: source.name);
          final discovery = await books.client.discover(
            source,
            token,
            category: categories.first,
          );
          expect(discovery.books, isNotEmpty, reason: source.name);
          final found = await books.client.books(source, query, token);
          expect(found, isNotEmpty, reason: source.name);
          final work = format == BookFormat.ximalaya
              ? found.firstWhere(
                  (entry) => entry.uri.queryParameters['albumId'] == '20665610',
                )
              : format == BookFormat.lit2go
              ? found.firstWhere(
                  (entry) => entry.uri.path.startsWith('/lit2go/1/'),
                )
              : found.first;
          final details = await books.details(work, token);
          expect(details.title, isNotEmpty);
          final chapters = await books.chapters(work, token);
          expect(chapters.length, greaterThanOrEqualTo(minimum));
          await books.download(work, chapters.first, token);
          final session = await books.audioFiles.open(work, chapters.first);
          final engine = services.createAudiobookEngine();
          try {
            await engine.open(session.uri);
            for (
              var i = 0;
              i < 80 && engine.snapshot.position.inSeconds < 2;
              i++
            ) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(engine.snapshot.duration.inSeconds, greaterThan(2));
            expect(engine.snapshot.position.inSeconds, greaterThanOrEqualTo(2));
          } finally {
            await engine.dispose();
            session.close();
          }
        }
      } finally {
        await services.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
