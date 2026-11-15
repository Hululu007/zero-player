import '../../../core/network/cancellation_token.dart';
import '../../../core/network/document_client.dart';
import '../domain/music_lyrics.dart';
import '../domain/music_track.dart';

/// Anonymous LRCLIB search; accepts only a matching, time-synced record.
final class LrclibLyrics {
  LrclibLyrics(this.network, {Uri? endpoint})
    : endpoint = endpoint ?? Uri.https('lrclib.net');

  final DocumentClient network;
  final Uri endpoint;
  static const _headers = {
    'User-Agent': 'ZeroPlayer/0.7.4 (https://github.com/yixunfei/zero-player)',
  };

  Future<MusicLyrics> find(MusicTrack track, CancellationToken token) async {
    if (track.title.trim().isEmpty || track.artist.trim().isEmpty) {
      return MusicLyrics.empty;
    }
    final uri = endpoint
        .resolve('/api/search')
        .replace(
          queryParameters: {
            'track_name': track.title,
            'artist_name': track.artist,
          },
        );
    final raw = (await network.get(
      uri,
      headers: _headers,
      cancellation: token,
      maxBytes: 1024 * 1024,
      networkTimeout: const Duration(seconds: 7),
    )).json;
    token.check();
    if (raw is! List) throw const FormatException('LRCLIB 歌词响应无效');
    final matches = <(int, MusicLyrics)>[];
    for (final row in raw.take(20).whereType<Map>()) {
      if (row['instrumental'] == true ||
          !_same(track.title, row['trackName'] ?? row['name']) ||
          !_same(track.artist, row['artistName'])) {
        continue;
      }
      final seconds = row['duration'];
      final difference = seconds is num && track.duration > Duration.zero
          ? ((seconds * 1000).round() - track.duration.inMilliseconds).abs()
          : 0;
      if (difference > 12000) continue;
      final value = row['syncedLyrics'];
      if (value is! String || value.length > 256 * 1024) continue;
      final lyrics = MusicLyrics.parse(value, '', sourceId: 'lrclib');
      if (lyrics.lines.isNotEmpty) matches.add((difference, lyrics));
    }
    matches.sort((a, b) => a.$1.compareTo(b.$1));
    return matches.isEmpty ? MusicLyrics.empty : matches.first.$2;
  }

  bool _same(String expected, Object? actual) =>
      actual is String &&
      expected.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '') ==
          actual.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
}
