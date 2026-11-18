import 'dart:convert';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/music/data/music_library.dart';
import 'package:zero_player/features/music/domain/music_track.dart';
import 'package:zero_player/features/sources/domain/video_source.dart';

MusicTrack workloadTrack(int index) => MusicTrack(
  id: 'song-$index',
  title: '曲目 $index',
  artist: '固定夹具',
  url: Uri.parse('https://media.test/$index.mp3'),
  fetchedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
  provider: 'myfreemp3',
);

Future<void> seedMusicWorkload(AppDatabase db) => db.atomic(() async {
  for (var i = 0; i < 20; i++) {
    final id = i.toRadixString(16).padLeft(32, '0');
    final playlist = MusicPlaylist(
      id,
      '歌单 $i',
      List.generate(100, (j) => workloadTrack(i * 100 + j)),
    );
    await db.customStatement('INSERT INTO app_meta VALUES(?,?)', [
      'music_playlist:$id',
      jsonEncode(playlist.toJson()),
    ]);
  }
  for (var i = 0; i < 200; i++) {
    final track = workloadTrack(i);
    await db.customStatement('INSERT INTO app_meta VALUES(?,?)', [
      'music_history:${stableId(track.key)}',
      jsonEncode({
        'track': track.toJson(),
        'position': i,
        'playedAt': 1700000000000 + i,
      }),
    ]);
  }
  await db.customStatement('INSERT INTO app_meta VALUES(?,?)', [
    'music_mode',
    jsonEncode('shuffle'),
  ]);
});
