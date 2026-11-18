import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:zero_player/core/diagnostics/performance_counters.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/music/data/music_library.dart';
import 'package:zero_player/features/music/domain/music_track.dart';
import 'package:zero_player/features/playback/domain/player_engine.dart';
import 'package:zero_player/features/settings/data/backup_service.dart';
import '../../test_support/music_library_workload.dart';

const _state = PlaybackSnapshot(
  position: Duration(seconds: 10),
  duration: Duration(minutes: 2),
);

void main() {
  setUp(() {
    PerformanceCounters.enabled = true;
    PerformanceCounters.reset();
  });
  tearDown(() {
    PerformanceCounters.enabled = false;
    PerformanceCounters.reset();
  });
  _unknownWrites();
  _historyContracts();
  _recoveryContracts();
}

Future<(AppDatabase, MusicLibrary, String)> _fixture({File? file}) async {
  final db = file == null ? AppDatabase.memory() : AppDatabase(file);
  final library = MusicLibrary(db);
  addTearDown(() async {
    await library.close();
    await db.close();
  });
  final id = await library.create('原歌单', tracks: [workloadTrack(0)]);
  PerformanceCounters.reset();
  return (db, library, id);
}

void _unknownWrites() {
  for (final writer in ['write', 'raw', 'batch', 'transaction']) {
    test(
      '$writer changes cause full music refresh on the next record',
      () async {
        final (db, library, id) = await _fixture();
        final args = [
          jsonEncode(MusicPlaylist(id, '外部改名', [workloadTrack(1)]).toJson()),
          'music_playlist:$id',
        ];
        const sql = 'UPDATE app_meta SET value=? WHERE key=?';
        switch (writer) {
          case 'write':
            await db.write(sql, args);
          case 'raw':
            await db.customStatement(sql, args);
          case 'batch':
            await db.batch((batch) => batch.customStatement(sql, args));
          case 'transaction':
            await db.atomic(() => db.customStatement(sql, args));
        }
        await db.customStatement(
          'INSERT OR REPLACE INTO app_meta VALUES(?,?)',
          ['music_mode', jsonEncode('repeatOne')],
        );
        await library.record(workloadTrack(0), _state);
        expect(library.playlists.single.name, '外部改名');
        expect(library.playlists.single.tracks.single.id, 'song-1');
        expect(library.mode, MusicPlayMode.repeatOne);
        expect(PerformanceCounters.snapshot()['music.read.fallback'], 1);
      },
    );
  }
  test('writes through another connection invalidate the snapshot', () async {
    final root = await Directory.systemTemp.createTemp('music-external-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/test.sqlite');
    final (_, library, _) = await _fixture(file: file);
    final writer = sqlite3.open(file.path);
    try {
      writer.execute('INSERT OR REPLACE INTO app_meta VALUES(?,?)', [
        'music_mode',
        jsonEncode('shuffle'),
      ]);
      await library.record(workloadTrack(0), _state);
      expect(library.mode, MusicPlayMode.shuffle);
      expect(PerformanceCounters.snapshot()['music.read.fallback'], 1);
    } finally {
      writer.close();
    }
  });
  test(
    'a trigger changing metadata during record forces a full refresh',
    () async {
      final (db, library, _) = await _fixture();
      await db.customStatement('''
      CREATE TRIGGER music_side_effect AFTER INSERT ON app_meta
      WHEN NEW.key GLOB 'music_history:*'
      BEGIN INSERT OR REPLACE INTO app_meta VALUES('music_mode','"repeatAll"'); END
    ''');
      await library.record(workloadTrack(0), _state);
      expect(library.mode, MusicPlayMode.repeatAll);
      expect(PerformanceCounters.snapshot()['music.read.fallback'], 1);
    },
  );
}

void _historyContracts() {
  test(
    'record retains 200 newest entries, clamps position and refreshes metadata',
    () async {
      final db = AppDatabase.memory();
      final library = MusicLibrary(db);
      addTearDown(() async {
        await library.close();
        await db.close();
      });
      await seedMusicWorkload(db);
      await library.load();
      PerformanceCounters.reset();
      final latest = MusicTrack.fromJson({
        ...workloadTrack(2001).toJson(),
        'title': '最新标题',
      });
      await library.record(
        latest,
        const PlaybackSnapshot(
          position: Duration(minutes: 3),
          duration: Duration(minutes: 2),
        ),
      );
      expect(library.history, hasLength(200));
      expect(library.history.first.track.title, '最新标题');
      expect(library.history.first.position, const Duration(minutes: 2));
      expect(library.history.any((item) => item.track.id == 'song-0'), isFalse);
      expect(
        library.history.first.playedAt.millisecondsSinceEpoch,
        greaterThan(1700000000199),
      );
      await library.record(
        latest,
        const PlaybackSnapshot(
          position: Duration(seconds: -1),
          duration: Duration(minutes: 2),
        ),
      );
      expect(library.history.first.position, Duration.zero);
      final playedAt = library.history.first.playedAt;
      await library.record(latest, const PlaybackSnapshot());
      expect(library.history.first.playedAt, playedAt);
      expect(library.mode, MusicPlayMode.shuffle);
      expect(PerformanceCounters.snapshot()['music.decode.playlists'] ?? 0, 0);
    },
  );
  test(
    'unknown corrupt playlist is preserved and reported; reload remains complete',
    () async {
      final (db, library, _) = await _fixture();
      const key = 'music_playlist:ffffffffffffffffffffffffffffffff';
      await db.write('INSERT INTO app_meta VALUES(?,?)', [key, '{broken']);
      await library.record(workloadTrack(0), _state);
      expect(library.notice, contains('损坏'));
      expect(library.playlists, hasLength(1));
      expect(
        (await db.rows('SELECT value FROM app_meta WHERE key=?', [
          key,
        ])).single['value'],
        '{broken',
      );
      PerformanceCounters.reset();
      await library.record(workloadTrack(0), _state);
      expect(library.notice, contains('损坏'));
      expect(PerformanceCounters.snapshot()['music.read.all'] ?? 0, 0);
      await library.reload();
      expect(PerformanceCounters.snapshot()['music.read.all'], 1);
      expect(library.notice, contains('损坏'));
    },
  );
}

void _recoveryContracts() {
  test(
    'restore is observed by history save even before explicit reload',
    () async {
      final (db, library, id) = await _fixture();
      final backup = BackupService(db);
      final exported = await backup.export();
      await library.rename(id, '临时改名');
      await library.setMode(MusicPlayMode.repeatAll);
      await backup.restore(await backup.preview(exported));
      await library.record(workloadTrack(0), _state);
      expect(library.playlists.single.name, '原歌单');
      // No persisted mode in the original backup: existing mode semantics remain.
      expect(library.mode, MusicPlayMode.repeatAll);
      expect(PerformanceCounters.snapshot()['music.read.fallback'], 1);
      await library.reload();
      expect(library.history.single.position, _state.position);
    },
  );
  test(
    'failed writes do not publish success and the queue accepts a retry',
    () async {
      final (db, library, _) = await _fixture();
      var notifications = 0;
      library.addListener(() => notifications++);
      await db.customStatement('''
      CREATE TRIGGER music_failure BEFORE INSERT ON app_meta
      WHEN NEW.key GLOB 'music_history:*'
      BEGIN SELECT RAISE(ABORT, 'fixture failure'); END
    ''');
      await expectLater(
        library.record(workloadTrack(0), _state),
        throwsA(anything),
      );
      expect(library.history, isEmpty);
      expect(notifications, 0);
      await db.customStatement('DROP TRIGGER music_failure');
      await library.record(workloadTrack(0), _state);
      expect(library.history.single.position, _state.position);
      expect(notifications, 1);
      await library.pendingWrites;
    },
  );
  test('queued playlist edits and records retain operation order', () async {
    final (_, library, id) = await _fixture();
    await Future.wait([
      library.rename(id, '队列改名'),
      library.record(workloadTrack(0), _state),
      library.add(id, workloadTrack(1)),
      library.move(id, workloadTrack(1).key, -1),
      library.setMode(MusicPlayMode.repeatOne),
    ]);
    expect(library.playlists.single.name, '队列改名');
    expect(library.playlists.single.tracks.map((item) => item.id), [
      'song-1',
      'song-0',
    ]);
    expect(library.mode, MusicPlayMode.repeatOne);
    expect(library.history.single.position, _state.position);
  });
}
