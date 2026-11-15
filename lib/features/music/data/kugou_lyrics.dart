import 'dart:convert';
import 'dart:io';
import '../../../core/network/cancellation_token.dart';
import '../../../core/network/document_client.dart';
import '../domain/music_lyrics.dart';
import '../domain/music_track.dart';

/// Reads KuGou's public lyric search/download API without executing source JS.
final class KugouLyrics {
  KugouLyrics(this.network, {Uri? searchEndpoint, Uri? lyricEndpoint})
    : searchEndpoint = searchEndpoint ?? Uri.https('mobileservice.kugou.com'),
      lyricEndpoint = lyricEndpoint ?? Uri.https('krcs.kugou.com');

  final DocumentClient network;
  final Uri searchEndpoint, lyricEndpoint;
  static final _hash = RegExp(r'^[0-9a-fA-F]{32}$');
  static final _id = RegExp(r'^\d{1,16}$');
  static const _headers = {'User-Agent': 'KuGou2012-7093-Android601'};
  static const _key = [
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

  Future<MusicLyrics> find(MusicTrack track, CancellationToken token) async {
    final direct = track.provider == 'kugou' && _hash.hasMatch(track.id)
        ? track.id
        : null;
    if (direct != null) {
      try {
        final lyrics = await _download(direct, track.duration, token);
        if (lyrics.lines.isNotEmpty) return lyrics;
      } catch (_) {
        token.check();
      }
    }
    final hashes = <String>[];
    if (track.title.trim().isNotEmpty && track.artist.trim().isNotEmpty) {
      final uri = searchEndpoint
          .resolve('/api/v3/search/song')
          .replace(
            queryParameters: {
              'format': 'json',
              'page': '1',
              'pagesize': '5',
              'keyword': '${track.title} ${track.artist}',
            },
          );
      final raw = (await network.get(
        uri,
        headers: _headers,
        cancellation: token,
        maxBytes: 512 * 1024,
        networkTimeout: const Duration(seconds: 7),
      )).json;
      token.check();
      final data = raw is Map ? raw['data'] : null;
      final rows = data is Map ? data['info'] : null;
      if (rows is List) {
        for (final row in rows.take(5).whereType<Map>()) {
          final hash = row['hash'];
          if (hash is! String ||
              !_hash.hasMatch(hash) ||
              !_same(track.title, row['songname']) ||
              !_same(track.artist, row['singername'])) {
            continue;
          }
          final duration = row['duration'];
          if (duration is num &&
              track.duration > Duration.zero &&
              ((duration * 1000).round() - track.duration.inMilliseconds)
                      .abs() >
                  12000) {
            continue;
          }
          if (hash != direct && !hashes.contains(hash)) hashes.add(hash);
        }
      }
    }
    for (final hash in hashes.take(3)) {
      try {
        final lyrics = await _download(hash, track.duration, token);
        if (lyrics.lines.isNotEmpty) return lyrics;
      } catch (_) {
        token.check();
      }
    }
    return MusicLyrics.empty;
  }

  Future<MusicLyrics> _download(
    String hash,
    Duration duration,
    CancellationToken token,
  ) async {
    final search = lyricEndpoint
        .resolve('/search')
        .replace(
          queryParameters: {
            'ver': '1',
            'man': 'yes',
            'client': 'mobi',
            'keyword': '',
            'duration': '${duration.inMilliseconds}',
            'hash': hash,
          },
        );
    final raw = (await network.get(
      search,
      headers: _headers,
      cancellation: token,
      maxBytes: 128 * 1024,
      networkTimeout: const Duration(seconds: 7),
    )).json;
    token.check();
    final candidates = raw is Map ? raw['candidates'] : null;
    if (candidates is! List) return MusicLyrics.empty;
    for (final candidate in candidates.take(3).whereType<Map>()) {
      final id = '${candidate['id'] ?? ''}';
      final accessKey = candidate['accesskey'];
      if (!_id.hasMatch(id) ||
          accessKey is! String ||
          !_hash.hasMatch(accessKey)) {
        continue;
      }
      final uri = lyricEndpoint
          .resolve('/download')
          .replace(
            queryParameters: {
              'ver': '1',
              'client': 'mobi',
              'id': id,
              'accesskey': accessKey,
              'fmt': 'krc',
              'charset': 'utf8',
            },
          );
      try {
        final doc = (await network.get(
          uri,
          headers: _headers,
          cancellation: token,
          maxBytes: 512 * 1024,
          networkTimeout: const Duration(seconds: 7),
        )).json;
        token.check();
        final content = doc is Map ? doc['content'] : null;
        if (content is! String || content.length > 512 * 1024) continue;
        final text = await _decode(content);
        final lyrics = MusicLyrics.parseKrc(text);
        if (lyrics.lines.isNotEmpty) return lyrics;
      } catch (_) {
        token.check();
      }
    }
    return MusicLyrics.empty;
  }

  Future<String> _decode(String content) async {
    final bytes = base64.decode(content.replaceAll(RegExp(r'\s+'), ''));
    if (bytes.length < 5 || utf8.decode(bytes.sublist(0, 4)) != 'krc1') {
      throw const FormatException('KRC 载荷无效');
    }
    final encoded = [
      for (var i = 4; i < bytes.length; i++) bytes[i] ^ _key[(i - 4) % 16],
    ];
    final output = <int>[];
    await for (final chunk in Stream.value(encoded).transform(ZLibDecoder())) {
      output.addAll(chunk);
      if (output.length > 1024 * 1024) throw const FormatException('KRC 歌词过大');
    }
    return utf8.decode(output);
  }

  bool _same(String expected, Object? actual) =>
      actual is String &&
      expected.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '') ==
          actual.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
}
