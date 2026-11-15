import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/audiobook_player_page.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  testWidgets(
    'audiobook continues after leaving page and resumes from mini bar',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'zero-audio-background-',
      );
      final services = AppServices.scoped(root, AppDatabase.memory());
      try {
        await services.settings.load();
        await services.supervision.load();
        final source =
            (await services.books.sources(BookKind.audio, enabledOnly: true))
                .singleWhere(
                  (entry) => entry.source.format == BookFormat.lit2go,
                )
                .source;
        final token = CancellationToken();
        final work = (await services.books.client.books(
          source,
          'Alice',
          token,
        )).firstWhere((entry) => entry.uri.path.startsWith('/lit2go/1/'));
        final chapters = await services.books.chapters(work, token);
        await services.books.download(work, chapters.first, token);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: AudiobookMiniPlayer(services: services)),
          ),
        );
        final context = tester.element(find.byType(AudiobookMiniPlayer));
        unawaited(
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => AudiobookPlayerPage(
                services: services,
                book: work,
                chapters: chapters,
                initial: chapters.first,
              ),
            ),
          ),
        );
        for (
          var i = 0;
          i < 100 && services.audiobookPlayer.snapshot.position.inSeconds < 2;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(services.audiobookPlayer.playing, isTrue);
        Navigator.of(context).pop();
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byType(AudiobookMiniPlayer), findsOneWidget);
        final first = services.audiobookPlayer.snapshot.position;
        for (var i = 0; i < 25; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(services.audiobookPlayer.snapshot.position, greaterThan(first));
        expect(services.audiobookPlayer.playing, isTrue);
        await tester.tap(find.byTooltip('暂停听书'));
        await tester.pump(const Duration(milliseconds: 200));
        expect(services.audiobookPlayer.playing, isFalse);
        await tester.tap(find.byTooltip('播放听书'));
        await tester.pump(const Duration(milliseconds: 200));
        expect(services.audiobookPlayer.playing, isTrue);
        await tester.tap(find.byTooltip('展开听书播放器'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(AudiobookPlayerPage), findsOneWidget);
        Navigator.of(context).pop();
        await tester.pump(const Duration(milliseconds: 400));
        await services.audiobookPlayer.stop();
        await tester.pump(const Duration(milliseconds: 200));
        expect(services.audiobookPlayer.active, isFalse);
      } finally {
        await services.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
