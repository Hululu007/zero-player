import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/catalog/domain/catalog_item.dart';
import 'package:zero_player/features/downloads/domain/download_task.dart';
import 'package:zero_player/features/downloads/presentation/downloads_page.dart';
import 'package:zero_player/features/playback/application/playback_controller.dart';
import '../../test_support/fake_player_engine.dart';

final item = CatalogItem(
  sourceId: 'source',
  id: 'work',
  title: 'Movie',
  category: 'Drama',
  lines: [
    PlayLine('original-line', [
      Episode('EP1', Uri.parse('https://media.test/1.mp4')),
      Episode('EP2', Uri.parse('https://media.test/2.mp4')),
    ]),
  ],
);

void main() {
  testWidgets(
    'unverifiable legacy task remains deletable without exposing content',
    (tester) async {
      final f = (await tester.runAsync(_Fixture.create))!;
      try {
        await tester.runAsync(
          () => f.services.db.write(
            'UPDATE downloads SET work_json=NULL WHERE id=?',
            [f.id],
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: DownloadsPage(services: f.services)),
          ),
        );
        await _settle(tester);
        expect(find.text('受限或无法校验的离线任务'), findsOneWidget);
        expect(find.textContaining('Movie'), findsNothing);
        expect(find.text('离线播放'), findsNothing);
        expect(find.text('导出 MP4'), findsNothing);
        await tester.tap(find.text('删除'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('确认'));
        await _settle(tester);
        expect(
          await tester.runAsync(() => f.services.downloads.find(f.id)),
          isNull,
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(f.close);
      }
    },
  );
  _resumeTest();
  _progressTest();
}

void _resumeTest() {
  testWidgets(
    'download page restores the exact episode and saves original identity',
    (tester) async {
      final fixture = (await tester.runAsync(_Fixture.create))!;
      final requests = <PlaybackRequest>[];
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) =>
                Scaffold(body: DownloadsPage(services: fixture.services)),
          ),
          GoRoute(
            path: '/player',
            builder: (_, state) {
              final request = state.extra! as PlaybackRequest;
              if (!requests.contains(request)) requests.add(request);
              return const Scaffold(body: Text('Player'));
            },
          ),
        ],
      );
      try {
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await _settle(tester);
        await tester.runAsync(() => tester.tap(find.text('离线播放')));
        await _settle(tester);
        expect(
          requests,
          hasLength(1),
          reason: tester
              .widgetList<Text>(find.byType(Text))
              .map((w) => w.data)
              .join(' | '),
        );
        final request = requests.single;
        expect(request.item.title, 'Movie');
        expect(request.item.category, 'Drama');
        expect(request.item.lines.single.name, 'original-line');
        expect(request.item.lines.single.episodes.single.label, 'EP1');
        expect(request.position, const Duration(seconds: 6));
        await tester.runAsync(() async {
          final engine = FakePlayerEngine();
          final player = PlaybackController(fixture.services, engine);
          try {
            await player.open(request);
            await player.seek(const Duration(seconds: 14));
            await Future<void>.delayed(Duration.zero);
            await player.save();
            final saved = await fixture.services.history.episodeEntry(
              'source',
              'work',
              'original-line',
              'EP1',
            );
            expect(saved!.position, const Duration(seconds: 14));
          } finally {
            await player.close();
          }
        });
        router.pop();
        await _settle(tester);
        await tester.runAsync(() => tester.tap(find.text('离线播放')));
        await _settle(tester);
        expect(requests.last.position, const Duration(seconds: 14));
      } finally {
        for (final request in requests) {
          request.offline!.close();
        }
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
        await tester.runAsync(fixture.close);
      }
    },
  );
}

void _progressTest() {
  testWidgets('known download counts show a determinate progress bar', (
    tester,
  ) async {
    final fixture = (await tester.runAsync(_Fixture.create))!;
    try {
      await tester.runAsync(() async {
        await fixture.services.downloads.status(
          fixture.id,
          DownloadStatus.running,
        );
        await fixture.services.downloads.progress(fixture.id, 3, 4, 1024);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DownloadsPage(services: fixture.services)),
        ),
      );
      await _settle(tester);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .75,
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.close);
    }
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

final class _Fixture {
  _Fixture(this.root, this.services, this.id);
  final Directory root;
  final AppServices services;
  final String id;
  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp(
      'download-resume-review-',
    );
    final services = AppServices.scoped(root, AppDatabase.memory());
    await services.settings.load();
    await services.supervision.load();
    final line = item.lines.single;
    final id = await services.downloads.create(
      item,
      line,
      line.episodes.first,
      {},
    );
    final directory = (await services.downloads.find(id))!.directory;
    final bytes = [1, 2, 3, 4];
    await File('$directory/video.mp4').writeAsBytes(bytes);
    await File('$directory/integrity.json').writeAsString(
      jsonEncode({
        'bytes': bytes.length,
        'digest': sha256.convert(bytes).toString(),
      }),
    );
    await services.downloads.complete(id, 'video.mp4');
    for (var i = 0; i < 2; i++) {
      await services.history.save(
        item,
        line,
        line.episodes[i],
        Duration(seconds: i == 0 ? 6 : 17),
        const Duration(seconds: 30),
      );
    }
    return _Fixture(root, services, id);
  }

  Future<void> close() async {
    await services.close();
    await root.delete(recursive: true);
  }
}
