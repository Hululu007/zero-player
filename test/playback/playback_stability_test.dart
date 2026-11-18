import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/catalog/domain/catalog_item.dart';
import 'package:zero_player/features/playback/application/playback_controller.dart';
import 'package:zero_player/features/playback/domain/player_engine.dart';
import '../../test_support/fake_player_engine.dart';

late Directory root;
late AppServices services;
late FakePlayerEngine engine;
late PlaybackController player;
final item = CatalogItem(
  sourceId: 'fixture',
  id: 'movie',
  title: '稳定性样本',
  lines: [
    PlayLine('main', [Episode('1', Uri.parse('https://media.example/1.mp4'))]),
  ],
);

void main() {
  _resetOrderRegression();
  _resumeRejectionTests();
  _missingDurationResume();
  _failedToggleAfterResume();
  test('manual seek after a rejected resume accepts actual progress', () async {
    await player.open(
      PlaybackRequest(item, position: const Duration(minutes: 2)),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(player.error, isNotNull);
    await player.seek(const Duration(seconds: 5));
    await player.save();
    expect(player.error, isNull);
    expect(
      (await services.history.all()).single.position,
      const Duration(seconds: 5),
    );
  });
  setUp(() async {
    root = await Directory.systemTemp.createTemp('playback-stability-');
    services = AppServices.scoped(root, AppDatabase.memory());
    await services.settings.load();
    await services.supervision.load();
    await services.gateway.start();
    engine = FakePlayerEngine();
    player = PlaybackController(services, engine);
  });
  tearDown(() async {
    await player.close();
    await services.close();
    await root.delete(recursive: true);
  });

  test(
    'a recoverable decoder warning does not interrupt advancing playback',
    () async {
      await player.open(PlaybackRequest(item));
      await player.seek(const Duration(seconds: 12));
      engine.failures.add(
        'decoder packet warning https://private.example/token',
      );
      await Future<void>.delayed(Duration.zero);
      engine.change(position: const Duration(seconds: 13));
      await Future<void>.delayed(Duration.zero);
      expect(player.error, isNull);
      expect(player.recovering, isFalse);
      expect(engine.opens, 1);
      expect(player.diagnosticReport(), isNot(contains('private.example')));
    },
  );

  test(
    'a short replacement resource never silently resumes at the beginning',
    () async {
      await player.open(
        PlaybackRequest(item, position: const Duration(minutes: 12)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(engine.seeks, isEmpty);
      expect(engine.snapshot.playing, isFalse);
      expect(player.error, contains('时长'));
      await player.save();
      expect(
        (await services.history.all()).single.position,
        const Duration(minutes: 12),
      );
    },
  );

  test(
    'an error burst preserves the position before a native position reset',
    () async {
      await player.open(PlaybackRequest(item));
      await player.seek(const Duration(seconds: 12));
      engine.failures.add('network');
      await Future<void>.delayed(Duration.zero);
      engine.emit(const PlaybackSnapshot());
      await Future<void>.delayed(const Duration(milliseconds: 3200));
      expect(player.recovering, isTrue);
      await player.save();
      expect(
        (await services.history.all()).single.position,
        const Duration(seconds: 12),
      );
    },
  );
}

void _resetOrderRegression() {
  test(
    'a native reset before its error still preserves the last good position',
    () async {
      await player.open(PlaybackRequest(item));
      await player.seek(const Duration(seconds: 12));
      engine.emit(const PlaybackSnapshot());
      await Future<void>.delayed(Duration.zero);
      engine.failures.add('network');
      await Future<void>.delayed(const Duration(milliseconds: 3200));
      expect(player.recovering, isTrue);
      await player.save();
      expect(
        (await services.history.all()).single.position,
        const Duration(seconds: 12),
      );
    },
  );
}

void _resumeRejectionTests() {
  for (final seekFailure in [false, true]) {
    test(
      'rejected resume permits controls and saves new progress: seekFailure=$seekFailure',
      () async {
        if (seekFailure) {
          await player.close();
          engine = FakePlayerEngine(
            onSeek: (_) async => throw StateError('fixture seek'),
          );
          player = PlaybackController(services, engine);
        }
        await player.open(
          PlaybackRequest(
            item,
            position: Duration(seconds: seekFailure ? 12 : 60),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(player.awaitingResume, isFalse);
        expect(player.error, isNotNull);
        await player.save();
        expect(
          (await services.history.all()).single.position.inSeconds,
          seekFailure ? 12 : 60,
        );
        var notifications = 0;
        player.addListener(() => notifications++);
        await player.toggle();
        engine.change(position: const Duration(seconds: 8), playing: true);
        await Future<void>.delayed(Duration.zero);
        await player.save();
        expect(notifications, greaterThan(0));
        expect(
          (await services.history.all()).single.position,
          const Duration(seconds: 8),
        );
        await player.toggle();
        expect(engine.snapshot.playing, isFalse);
      },
    );
  }
  test('saving unchanged paused progress does not write again', () async {
    await player.open(PlaybackRequest(item));
    await player.toggle();
    final before = (await services.db.rows(
      'SELECT total_changes() AS n',
    )).single['n'];
    await player.save();
    await player.save();
    expect(
      (await services.db.rows('SELECT total_changes() AS n')).single['n'],
      before,
    );
  });
}

void _missingDurationResume() {
  test(
    'missing duration watchdog releases controls and preserves old progress until accepted',
    () async {
      await player.close();
      engine = FakePlayerEngine(initialDuration: Duration.zero);
      player = PlaybackController(services, engine);
      await player.open(
        PlaybackRequest(item, position: const Duration(minutes: 2)),
      );
      expect(player.awaitingResume, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 12200));
      expect(player.awaitingResume, isFalse);
      expect(player.error, contains('时长'));
      await player.save();
      expect(
        (await services.history.all()).single.position,
        const Duration(minutes: 2),
      );
      await player.toggle();
      engine.change(position: const Duration(seconds: 7));
      await Future<void>.delayed(Duration.zero);
      await player.save();
      expect(
        (await services.history.all()).single.position,
        const Duration(seconds: 7),
      );
    },
  );
}

void _failedToggleAfterResume() {
  test(
    'a failed play command after resume rejection keeps the recovery point',
    () async {
      await player.close();
      engine = FakePlayerEngine(
        onPlayOrPause: () async => throw StateError('fixture play'),
      );
      player = PlaybackController(services, engine);
      await player.open(
        PlaybackRequest(item, position: const Duration(minutes: 2)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await expectLater(player.toggle(), throwsStateError);
      await player.save();
      expect(player.error, isNotNull);
      expect(
        (await services.history.all()).single.position,
        const Duration(minutes: 2),
      );
    },
  );
}
