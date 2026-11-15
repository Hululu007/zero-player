import '../../../core/network/cancellation_token.dart';
import '../../sources/domain/video_source.dart';
import '../../supervision/application/content_policy.dart';
import '../../supervision/domain/supervision_rules.dart';
import '../domain/music_track.dart';
import '../domain/music_lyrics.dart';
import '../domain/music_match.dart';
import 'netease_music_details.dart';
import 'kugou_lyrics.dart';
import 'lrclib_lyrics.dart';
import 'music_parser.dart';
import 'myfreemp3_client.dart';
import 'public_music_sources.dart';
import 'website_music_sources.dart';

final class MusicRepository {
  MusicRepository(this.client, {this.policy});
  final MyFreeMp3Client client;
  final ContentPolicy? policy;
  late final public = PublicMusicSources(client.network);
  late final _netease = NeteaseMusicDetails(client.network);
  late final _kugouLyrics = KugouLyrics(client.network);
  late final _lrclib = LrclibLyrics(client.network);
  final _lyricCache = <String, MusicLyrics>{};
  VideoSource sourceFor(String provider) => provider == 'neteasePlaylist'
      ? sourceFor('netease')
      : provider == 'kugouPlaylist'
      ? sourceFor('kugou')
      : provider == 'myfreemp3'
      ? source
      : VideoSource(
          id: 'music-$provider',
          name:
              musicSources[provider] ??
              musicPlaylistProviders[provider] ??
              switch (provider) {
                'lrclib' => 'LRCLIB 同步歌词',
                'appleHome' => 'Apple Music',
                'wfu' => 'WFU 音乐精选',
                _ => provider,
              },
          kind: 'music',
          enabled: true,
          endpoint: Uri.parse(switch (provider) {
            'audius' => 'https://audius.co',
            'flacHi' => 'https://flac.music.hi.cn',
            'kugou' => 'https://www.kugou.com',
            'lrclib' => 'https://lrclib.net',
            'qqPlaylist' => 'https://y.qq.com',
            'appleHome' => 'https://rss.marketingtools.apple.com',
            'wfu' => 'https://music1.wfuapp.com',
            'archive' => 'https://archive.org',
            'lxHuibq' => 'https://lxmusicapi.onrender.com',
            'qqmp3' => 'https://www.qqmp3.vip',
            'musicBox' => 'https://mu-jie.cc/musicBox/',
            'lxHuanyin' => 'https://music-dl.sayqz.com',
            'lxQdy' || 'lxXinghai' => 'https://music-api.gdstudio.xyz',
            'lxExclusive' => 'https://88.lxmusic.xn--fiqs8s',
            'lxHelloWorld' => 'https://c.wwwweb.top',
            'lxHyw' => 'https://103.79.184.97',
            'lxFlower' || 'lxGrass' => 'http://97.64.37.235',
            'lxJuhe' => 'https://api.music.lerd.dpdns.org',
            _ => 'https://music.163.com',
          }),
        );
  Map<String, String> headers(MusicTrack track) => track.provider == 'myfreemp3'
      ? const {'Referer': 'https://myfreemp3.ink/'}
      : {'qqmp3', 'musicBox'}.contains(track.provider)
      ? WebsiteMusicSources.headers(track.provider)
      : const {};
  static final source = VideoSource(
    id: 'music-myfreemp3',
    name: 'MY FREE MP3',
    kind: 'music',
    enabled: true,
    endpoint: Uri.parse('https://myfreemp3.ink'),
  );

  bool allowed(MusicTrack track) =>
      (musicSources.containsKey(track.provider) ||
          musicPlaylistProviders.containsKey(track.provider)) &&
      !(track.explicit && (policy?.filterAdult ?? true)) &&
      (policy?.sourceAllowed(sourceFor(track.provider)) ?? true) &&
      (policy?.textAllowed('${track.title} ${track.artist}') ?? true);

  bool supportsLyrics(MusicTrack track) =>
      allowed(track) &&
      (NeteaseMusicDetails.supportsLyrics(track.provider) ||
          track.provider == 'kugou' ||
          track.artist.trim().isNotEmpty) &&
      const [
        'netease',
        'kugou',
        'lrclib',
      ].any((id) => policy?.sourceAllowed(sourceFor(id)) ?? true);

  Future<MusicLyrics> lyrics(MusicTrack track, CancellationToken token) async {
    if (!supportsLyrics(track)) return MusicLyrics.empty;
    final cached = _lyricCache[track.key];
    if (cached != null && _lyricSourceAllowed(cached.sourceId)) return cached;
    final result = await _lookupLyrics(track, token);
    token.check();
    if (result.lines.isNotEmpty &&
        supportsLyrics(track) &&
        _lyricSourceAllowed(result.sourceId)) {
      _lyricCache.remove(track.key);
      _lyricCache[track.key] = result;
      if (_lyricCache.length > 64) _lyricCache.remove(_lyricCache.keys.first);
      return result;
    }
    return MusicLyrics.empty;
  }

  Future<MusicLyrics> _lookupLyrics(
    MusicTrack track,
    CancellationToken token,
  ) async {
    if (NeteaseMusicDetails.supportsLyrics(track.provider) &&
        _lyricSourceAllowed('netease')) {
      final direct = await _tryNetease(track.id, token);
      if (direct.lines.isNotEmpty) return direct;
    }
    if (track.provider == 'kugou' && _lyricSourceAllowed('kugou')) {
      final direct = await _tryProvider(
        () => _kugouLyrics.find(track, token),
        token,
      );
      if (direct.lines.isNotEmpty) return direct;
    }
    if (track.artist.trim().isEmpty) return MusicLyrics.empty;
    if (_lyricSourceAllowed('lrclib')) {
      final result = await _tryProvider(
        () => _lrclib.find(track, token),
        token,
      );
      if (result.lines.isNotEmpty) return result;
    }
    if (track.provider != 'kugou' && _lyricSourceAllowed('kugou')) {
      final result = await _tryProvider(
        () => _kugouLyrics.find(track, token),
        token,
      );
      if (result.lines.isNotEmpty) return result;
    }
    if (_lyricSourceAllowed('netease')) {
      try {
        final results = await search(
          '${track.title} ${track.artist}',
          provider: 'netease',
          cancellation: token,
        );
        final matches = results.tracks.where((candidate) {
          if (!matchesMusic(track, candidate)) return false;
          if (NeteaseMusicDetails.supportsLyrics(track.provider) &&
              track.id == candidate.id) {
            return false;
          }
          return track.duration == Duration.zero ||
              candidate.duration == Duration.zero ||
              (track.duration - candidate.duration).abs() <=
                  const Duration(seconds: 12);
        });
        for (final candidate in matches.take(2)) {
          final result = await _tryNetease(candidate.id, token);
          if (result.lines.isNotEmpty) return result;
        }
      } catch (_) {
        token.check();
      }
    }
    return MusicLyrics.empty;
  }

  bool _lyricSourceAllowed(String id) =>
      policy?.sourceAllowed(sourceFor(id)) ?? true;

  Future<MusicLyrics> _tryNetease(String id, CancellationToken token) =>
      _tryProvider(() => _netease.lyrics(id, token), token);

  Future<MusicLyrics> _tryProvider(
    Future<MusicLyrics> Function() fetch,
    CancellationToken token,
  ) async {
    try {
      final lyrics = await fetch();
      token.check();
      if (_lyricSourceAllowed(lyrics.sourceId)) return lyrics;
    } catch (_) {
      token.check();
    }
    return MusicLyrics.empty;
  }

  MusicLyrics visibleLyrics(MusicLyrics lyrics) {
    final policy = this.policy;
    if (policy == null || lyrics.lines.isEmpty) return lyrics;
    if (!_lyricSourceAllowed(lyrics.sourceId)) return MusicLyrics.empty;
    return lyrics.filtered(policy.textAllowed);
  }

  Future<({String name, List<MusicTrack> tracks, int total})> importPlaylist(
    String value,
    CancellationToken token,
  ) async {
    final source = sourceFor('netease');
    policy?.requireSource(source);
    final list = await _netease.playlist(value, token);
    token.check();
    policy?.requireSource(source);
    if (!(policy?.textAllowed(list.name) ?? true)) throw const ContentBlocked();
    final tracks = <String, MusicTrack>{
      for (final track in list.tracks.where(allowed)) track.key: track,
    };
    if (tracks.isEmpty) throw const FormatException('歌单内没有可导入的歌曲');
    return (
      name: list.name,
      tracks: List<MusicTrack>.unmodifiable(tracks.values),
      total: list.total,
    );
  }

  String validateSearchQuery(String value) {
    final query = value
        .replaceAll(RegExp(r'[\\/\x00-\x1f\x7f?#%<>{}\[\]|^`]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (query.isEmpty || query.length > 100) {
      throw const FormatException('请输入 1–100 字的歌名或歌手');
    }
    if (!(policy?.textAllowed(query) ?? true)) throw const ContentBlocked();
    return query;
  }

  Future<MusicSearchResult> search(
    String query, {
    int page = 1,
    CancellationToken? cancellation,
    String provider = 'myfreemp3',
  }) async {
    query = validateSearchQuery(query);
    if (page < 1 || page > 1000) throw const FormatException('搜索页码超出范围');
    if (!musicSources.containsKey(provider)) {
      throw const FormatException('未知音乐渠道');
    }
    policy?.requireSource(sourceFor(provider));
    if (provider != 'myfreemp3') {
      final result = await public.search(provider, query, page, cancellation);
      return MusicSearchResult(
        List.unmodifiable(result.tracks.where(allowed)),
        hasNext: result.hasNext,
      );
    }
    final document = await client.search(
      query,
      page,
      cancellation: cancellation,
    );
    cancellation?.check();
    policy?.requireSource(source);
    final result = parseMusicSearch(document.text, query: query, page: page);
    return MusicSearchResult(
      List.unmodifiable(result.tracks.where(allowed)),
      hasNext: result.hasNext,
    );
  }

  Future<MusicTrack> resolve(
    MusicTrack track,
    CancellationToken cancellation, {
    bool refresh = false,
  }) async {
    if (!allowed(track)) throw const ContentBlocked();
    if (track.searchOnly) throw const FormatException('请先匹配可播放的音乐渠道');
    if (track.provider != 'myfreemp3') {
      return public.resolve(track, cancellation);
    }
    if (!refresh &&
        DateTime.now().difference(track.fetchedAt) <
            const Duration(minutes: 10)) {
      return track;
    }
    final result = await search(
      track.query.isEmpty ? '${track.artist} ${track.title}' : track.query,
      page: track.page,
      cancellation: cancellation,
    );
    return result.tracks.where((item) => item.id == track.id).firstOrNull ??
        (throw const FormatException('歌曲地址已失效，请重新搜索后播放'));
  }
}
