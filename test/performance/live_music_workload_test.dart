import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/diagnostics/performance_counters.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/live/data/live_audit_defaults.dart';
import 'package:zero_player/features/live/presentation/live_page.dart';
import 'package:zero_player/features/playback/domain/player_engine.dart';
import '../../test_support/music_library_workload.dart';

void main() {
  for (final visible in [true, false]) {
    testWidgets('120 music saves with live visible=$visible', (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('live-music-'),
      ))!;
      final services = AppServices.scoped(
        root,
        AppDatabase.memory(),
        channelAuditOverride: LiveAuditDefaults(() async => '{"results":[]}'),
      );
      final previous = PerformanceCounters.enabled;
      addTearDown(() async {
        PerformanceCounters.enabled = previous;
        PerformanceCounters.reset();
        await tester.runAsync(() async {
          await services.close();
          await root.delete(recursive: true);
        });
      });
      String? channelName;
      await tester.runAsync(() async {
        await services.supervision.load();
        await services.settings.load();
        await services.live.importText(
          '测试',
          Uri.parse('https://list.test/a'),
          'CCTV1,https://media.test/a.ts',
          verify: false,
        );
        await seedMusicWorkload(services.db);
        await services.musicLibrary.load();
        channelName = (await services.live.channels()).single.name;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IndexedStack(
              index: visible ? 0 : 1,
              children: [
                LivePage(services: services),
                const SizedBox.shrink(),
              ],
            ),
          ),
        ),
      );
      await _settle(tester);
      PerformanceCounters.enabled = true;
      PerformanceCounters.reset();
      for (var i = 0; i < 120; i++) {
        await tester.runAsync(
          () => services.musicLibrary.record(
            workloadTrack(0),
            PlaybackSnapshot(
              position: Duration(seconds: i),
              duration: const Duration(minutes: 4),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 260));
        await _settle(tester);
      }
      final counts = PerformanceCounters.snapshot();
      expect(counts['live.channels.calls'] ?? 0, 0);
      expect(
        services.musicLibrary.history.first.position,
        const Duration(seconds: 119),
      );
      expect(services.contentPolicy.liveChannel(channelName!), isNotNull);
      stdout.writeln(
        jsonEncode({
          'scenario': 'music-120ticks-live-visible-$visible',
          'counts': counts,
        }),
      );
      await _verifyInvalidations(tester, services, channelName!);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

Future<void> _verifyInvalidations(
  WidgetTester tester,
  AppServices services,
  String name,
) async {
  final channel = services.contentPolicy.liveChannel(name)!;
  Future<void> change(Future<void> Function() action) async {
    PerformanceCounters.reset();
    await tester.runAsync(action);
    await tester.pump(const Duration(milliseconds: 260));
    await _settle(tester);
    expect(PerformanceCounters.snapshot()['live.channels.calls'], 1);
  }

  await change(() => services.liveHealth.setEnabled([channel.id], false));
  expect(services.contentPolicy.liveChannel(name)!.health.enabled, false);
  await change(() => services.liveHealth.setRemoved([channel.id], true));
  expect(services.contentPolicy.liveChannel(name)!.health.removed, true);
  await change(() => services.live.setListEnabled(channel.listId, false));
  expect(services.contentPolicy.liveChannel(name), isNull);
  await change(() => services.live.setListEnabled(channel.listId, true));
  await change(
    () => services.db.write('INSERT OR REPLACE INTO app_meta VALUES(?,?)', [
      'live_metadata:${channel.id}',
      jsonEncode({
        'signature': channel.urls.join('|'),
        'categories': ['测试'],
      }),
    ]),
  );
  expect(
    services.contentPolicy.liveChannel(name)!.metadata.categories,
    contains('测试'),
  );
  await change(() => services.live.favorite(channel, true));
  expect(services.contentPolicy.liveChannel(name)!.favorite, true);
  await change(
    () => services.db.write('UPDATE live_lists SET name=? WHERE id=?', [
      '新列表',
      channel.listId,
    ]),
  );
  expect(services.contentPolicy.liveChannel(name)!.listName, '新列表');
  await change(
    () => services.db.atomic(
      () async {
        await services.musicLibrary.setMode(services.musicLibrary.mode);
        await services.db.batch(
          (batch) => batch.customStatement(
            'INSERT OR REPLACE INTO app_meta VALUES(?,?)',
            ['builtin_live_quarantined:${channel.listId}', '已隔离'],
          ),
        );
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.musicMode},
    ),
  );
  expect(services.contentPolicy.liveChannel(name), isNull);
  await change(
    () => services.db.write('DELETE FROM app_meta WHERE key=?', [
      'builtin_live_quarantined:${channel.listId}',
    ]),
  );
  PerformanceCounters.reset();
  services.contentPolicy.refresh();
  await _settle(tester);
  expect(PerformanceCounters.snapshot()['live.channels.calls'], 1);
  await change(
    () => services.live.importText(
      '新列表',
      Uri.parse('https://list.test/a'),
      'CCTV1,https://media.test/b.ts',
      headers: {'User-Agent': 'changed'},
      verify: false,
    ),
  );
  final updated = services.contentPolicy.liveChannel(name)!;
  expect(updated.headers['User-Agent'], 'changed');
  expect(updated.urls.single.path, '/b.ts');
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 5)),
  );
  await tester.pumpAndSettle();
}
