import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/document_client.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/features/music/data/kugou_lyrics.dart';
import 'package:zero_player/features/music/data/lrclib_lyrics.dart';
import 'package:zero_player/features/music/domain/music_track.dart';
import '../../test_support/http_test_server.dart';

MusicTrack _track(String provider) => MusicTrack(
  id: provider == 'kugou' ? 'C41E80A18D1448FA47086372999C7F43' : 'one',
  title: '海阔天空',
  artist: 'BEYOND',
  duration: const Duration(seconds: 324),
  url: Uri.parse('https://example.com/audio.mp3'),
  fetchedAt: DateTime.now(),
  provider: provider,
);

void main() {
  _online();
  _lrclib();
  _kugou();
}

void _online() {
  test(
    'public LRCLIB and KuGou return real synchronized lines',
    () async {
      final http = MediaHttpClient();
      addTearDown(http.close);
      final network = DocumentClient(http);
      final kugou = await KugouLyrics(
        network,
      ).find(_track('kugou'), CancellationToken());
      expect(kugou.lines, isNotEmpty);
      expect(kugou.sourceId, 'kugou');
      final lrclib = await LrclibLyrics(network).find(
        MusicTrack(
          id: 'sample',
          title: 'I Want to Live',
          artist: 'Borislav Slavov',
          duration: const Duration(seconds: 233),
          url: Uri.parse('https://example.com/audio.mp3'),
          fetchedAt: DateTime.now(),
          provider: 'myfreemp3',
        ),
        CancellationToken(),
      );
      expect(lrclib.lines, isNotEmpty);
      expect(lrclib.sourceId, 'lrclib');
    },
    skip: !const bool.fromEnvironment('RUN_MUSIC_LYRICS_ONLINE'),
  );
}

void _lrclib() {
  test('LRCLIB accepts only the matching timed recording', () async {
    final server = await HttpTestServer.start((request) {
      expect(request.uri.path, '/api/search');
      expect(request.uri.queryParameters['track_name'], '海阔天空');
      expect(request.headers.value('user-agent'), contains('ZeroPlayer'));
      request.response.write(
        jsonEncode([
          {
            'trackName': '海阔天空 Live',
            'artistName': 'BEYOND',
            'duration': 324,
            'syncedLyrics': '[00:01.00]错误版本',
          },
          {
            'trackName': '海阔天空',
            'artistName': 'BEYOND',
            'duration': 325,
            'syncedLyrics': '[00:01.00]正确歌词',
          },
        ]),
      );
    });
    final http = MediaHttpClient(allowPrivateNetworks: true);
    addTearDown(() async {
      http.close();
      await server.close();
    });
    final lyrics = await LrclibLyrics(
      DocumentClient(http),
      endpoint: server.baseUri,
    ).find(_track('myfreemp3'), CancellationToken());
    expect(lyrics.sourceId, 'lrclib');
    expect(lyrics.lines.single.text, '正确歌词');
  });
}

void _kugou() {
  test('KuGou direct hash downloads and decodes synchronized KRC', () async {
    const hash = 'C41E80A18D1448FA47086372999C7F43';
    const key = [
      0x40,
      0x47,
      0x61,
      0x77,
      0x5e,
      0x32,
      0x74,
      0x47,
      0x51,
      0x36,
      0x31,
      0x2d,
      0xce,
      0xd2,
      0x6e,
      0x69,
    ];
    final plain = utf8.encode('[offset:0]\n[1200,800]<0,300,0>海<300,500,0>阔');
    final zipped = ZLibEncoder().convert(plain);
    final payload = base64Encode([
      ...'krc1'.codeUnits,
      for (var i = 0; i < zipped.length; i++) zipped[i] ^ key[i % 16],
    ]);
    final server = await HttpTestServer.start((request) {
      if (request.uri.path == '/search') {
        expect(request.uri.queryParameters['hash'], hash);
        request.response.write(
          jsonEncode({
            'candidates': [
              {
                'id': 346467936,
                'accesskey': '26E1C38D2620C85B154DB097AFDDCEC6',
              },
              {
                'id': 346467937,
                'accesskey': '26E1C38D2620C85B154DB097AFDDCEC6',
              },
            ],
          }),
        );
      } else if (request.uri.path == '/download') {
        request.response.write(
          jsonEncode({
            'content': request.uri.queryParameters['id'] == '346467936'
                ? 'corrupt'
                : payload,
          }),
        );
      } else {
        fail('Direct hash should not require song search');
      }
    });
    final http = MediaHttpClient(allowPrivateNetworks: true);
    addTearDown(() async {
      http.close();
      await server.close();
    });
    final lyrics = await KugouLyrics(
      DocumentClient(http),
      searchEndpoint: server.baseUri,
      lyricEndpoint: server.baseUri,
    ).find(_track('kugou'), CancellationToken());
    expect(lyrics.sourceId, 'kugou');
    expect(lyrics.lines.single.text, '海阔');
    expect(lyrics.lines.single.time, const Duration(milliseconds: 1200));
  });
}
