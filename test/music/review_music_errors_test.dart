import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/document_client.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/music/application/music_controller.dart';
import 'package:zero_player/features/music/data/music_audio_probe.dart';
import 'package:zero_player/features/music/data/music_library.dart';
import 'package:zero_player/features/music/data/music_repository.dart';
import 'package:zero_player/features/music/data/myfreemp3_client.dart';
import 'package:zero_player/features/music/domain/music_track.dart';
import '../../test_support/http_test_server.dart';
import '../../test_support/fake_player_engine.dart';

MusicTrack song({String provider = 'myfreemp3', Uri? url}) => MusicTrack(
  id: 'one',
  title: 'One',
  artist: 'Artist',
  provider: provider,
  url: url ?? Uri.parse('https://media.test/one.mp3'),
  fetchedAt: DateTime.now(),
);

void main() {
  _playlistTests();
  test('empty audio stream is reported as unusable audio', () async {
    final server = await HttpTestServer.start((request) {
      request.response.headers.contentType = ContentType('audio', 'mpeg');
      request.response.contentLength = 0;
    });
    final http = MediaHttpClient(allowPrivateNetworks: true);
    addTearDown(() async {
      http.close();
      await server.close();
    });
    final repository = MusicRepository(MyFreeMp3Client(DocumentClient(http)));
    await expectLater(
      probeMusicAudio(
        repository,
        song(url: server.baseUri.resolve('one.mp3')),
        CancellationToken(),
      ),
      throwsFormatException,
    );
  });
  test('a filtered queue choice notifies with an actionable notice', () async {
    final http = MediaHttpClient();
    final player = MusicController(
      MusicRepository(MyFreeMp3Client(DocumentClient(http))),
      FakePlayerEngine.new,
    );
    addTearDown(() async {
      await player.close();
      http.close();
    });
    var notices = 0;
    player.addListener(() => notices++);
    await player.select([song(provider: 'archive')], 0);
    expect(player.error, '歌曲已被过滤');
    expect(notices, 1);
    expect(player.selected, isNull);
  });
}

void _playlistTests() {
  for (final operation in ['rename', 'add', 'remove', 'move']) {
    test(
      '$operation after deletion explains that the playlist is gone',
      () async {
        final db = AppDatabase.memory();
        final library = MusicLibrary(db);
        addTearDown(() async {
          await library.close();
          await db.close();
        });
        final id = await library.create('List');
        await library.delete(id);
        final action = switch (operation) {
          'rename' => library.rename(id, 'New'),
          'add' => library.add(id, song()),
          'remove' => library.remove(id, song().key),
          _ => library.move(id, song().key, 1),
        };
        await expectLater(
          action,
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('歌单已删除'),
            ),
          ),
        );
        expect(library.playlists, isEmpty);
      },
    );
  }
}
