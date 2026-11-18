import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/diagnostics/performance_counters.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/music/data/music_library.dart';
import 'package:zero_player/features/playback/domain/player_engine.dart';
import '../../test_support/music_library_workload.dart';

void main() {
  for (final enabled in [false, true]) {
    test('history workload with counters $enabled', () async {
      final db = AppDatabase.memory();
      final library = MusicLibrary(db);
      final previous = PerformanceCounters.enabled;
      addTearDown(() async {
        PerformanceCounters.enabled = previous;
        PerformanceCounters.reset();
        await library.close();
        await db.close();
      });
      await seedMusicWorkload(db);
      await library.load();
      PerformanceCounters.enabled = enabled;
      PerformanceCounters.reset();
      for (var i = 0; i < 20; i++) {
        await library.record(
          workloadTrack(0),
          PlaybackSnapshot(
            position: Duration(seconds: i),
            duration: const Duration(minutes: 4),
          ),
        );
      }
      final counts = PerformanceCounters.snapshot();
      expect(library.playlists, hasLength(20));
      expect(library.playlists.first.tracks, hasLength(100));
      expect(library.history, hasLength(200));
      expect(library.history.first.position, const Duration(seconds: 19));
      expect(library.mode, MusicPlayMode.shuffle);
      if (enabled) {
        expect(counts['db.statements'], 20);
        expect(counts['db.notifications'], 20);
        expect(counts['music.read.history'], 20);
        expect(counts['music.read.all'] ?? 0, 0);
        expect(counts['music.decode.playlists'] ?? 0, 0);
        expect(counts['music.decode.playlist_tracks'] ?? 0, 0);
        // Aggregate evidence only; elapsed test time is not an energy result.
        stdout.writeln(
          jsonEncode({
            'scenario': 'music-20x100-200-20ticks',
            'counts': counts,
          }),
        );
      } else {
        expect(counts, isEmpty);
      }
    });
  }
}
