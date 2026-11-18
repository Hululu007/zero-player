import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../../../core/persistence/app_database.dart';
import '../../../core/diagnostics/performance_counters.dart';
import '../../sources/domain/video_source.dart';
import '../../playback/domain/player_engine.dart';
import '../domain/music_track.dart';

enum MusicPlayMode { sequential, repeatAll, repeatOne, shuffle }

const musicModeLabels = ['顺序播放', '列表循环', '单曲循环', '随机播放'];

final class MusicPlaylist {
  const MusicPlaylist(this.id, this.name, this.tracks);
  final String id, name;
  final List<MusicTrack> tracks;
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'tracks': tracks.map((t) => t.toJson()).toList(),
  };
  factory MusicPlaylist.fromJson(Map data) {
    final name = data['name'] as String;
    final tracks = data['tracks'] as List;
    if (name.trim().isEmpty ||
        name.length > 80 ||
        tracks.length > 500 ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(data['id'] as String)) {
      throw const FormatException('歌单名称或容量无效');
    }
    return MusicPlaylist(
      data['id'] as String,
      name,
      List.unmodifiable(tracks.cast<Map>().map(MusicTrack.fromJson)),
    );
  }
}

final class MusicHistory {
  const MusicHistory(this.track, this.position, this.playedAt);
  final MusicTrack track;
  final Duration position;
  final DateTime playedAt;
}

final class MusicLibrary extends ChangeNotifier {
  MusicLibrary(this.db);
  final AppDatabase db;
  List<MusicPlaylist> playlists = [];
  List<MusicHistory> history = [];
  MusicPlayMode mode = MusicPlayMode.sequential;
  Future<void>? _loaded;
  Future<void> _pending = Future.value();
  ({int writes, int external})? _readVersion;
  bool _closed = false;
  String? notice;
  Future<void> load() => _loaded ??= _read();
  Future<void> get pendingWrites => _pending;
  Future<void> reload() async {
    await _pending;
    await _read();
  }

  Future<({int writes, int external})> _version() async {
    // total_changes includes raw statements, batches, triggers and rolled-back
    // writes on this connection; data_version also detects other connections.
    final row = (await db.rows(
      'SELECT total_changes() AS writes, data_version AS external FROM pragma_data_version',
    )).single;
    return (writes: row['writes'] as int, external: row['external'] as int);
  }

  Future<void> _read({int? historyChanges}) async {
    final previous = _readVersion;
    final historyOnly = historyChanges != null && previous != null;
    final before = historyOnly ? previous : await _version();
    final rows = await db.rows(
      historyOnly
          ? "SELECT * FROM app_meta WHERE key GLOB 'music_history:*'"
          : "SELECT * FROM app_meta WHERE key GLOB 'music_playlist:*' OR key GLOB 'music_history:*' OR key='music_mode'",
    );
    final after = await _version();
    PerformanceCounters.add(
      historyOnly ? 'music.read.history' : 'music.read.all',
    );
    PerformanceCounters.add('music.read.rows', rows.length);
    if (historyOnly &&
        (after.external != before.external ||
            after.writes != before.writes + historyChanges)) {
      PerformanceCounters.add('music.read.fallback');
      await _read();
      return;
    }
    // An overlapping unknown write leaves this snapshot usable, but prevents
    // the next write from assuming that its unrelated metadata is current.
    _readVersion = historyOnly || before == after ? after : null;
    _decode(rows, historyOnly: historyOnly);
    if (!_closed) notifyListeners();
  }

  void _decode(List<Map<String, Object?>> rows, {required bool historyOnly}) {
    final lists = <MusicPlaylist>[];
    final records = <MusicHistory>[];
    for (final row in rows) {
      try {
        final key = row['key'] as String;
        if (PerformanceCounters.enabled) {
          PerformanceCounters.add(
            'music.decode.bytes',
            utf8.encode(row['value'] as String).length,
          );
        }
        final value = jsonDecode(row['value'] as String);
        if (key == 'music_mode') {
          mode = MusicPlayMode.values.byName(value as String);
        } else if (key.startsWith('music_playlist:')) {
          lists.add(MusicPlaylist.fromJson(value as Map));
          PerformanceCounters.add('music.decode.playlists');
          PerformanceCounters.add(
            'music.decode.playlist_tracks',
            lists.last.tracks.length,
          );
        } else {
          final map = value as Map;
          records.add(
            MusicHistory(
              MusicTrack.fromJson(map['track'] as Map),
              Duration(milliseconds: map['position'] as int),
              DateTime.fromMillisecondsSinceEpoch(map['playedAt'] as int),
            ),
          );
        }
      } catch (_) {
        notice = '部分音乐记录损坏，已保留原数据并跳过。';
      }
    }
    if (!historyOnly) playlists = lists;
    history = records..sort((a, b) => b.playedAt.compareTo(a.playedAt));
  }

  Future<void> _write(
    Future<void> Function() action, {
    int Function()? historyChanges,
  }) {
    if (_closed) return Future.error(StateError('音乐库已关闭'));
    final future = _pending.then((_) async {
      await load();
      await action();
      await _read(historyChanges: historyChanges?.call());
    });
    _pending = future.catchError((Object _) {});
    return future;
  }

  Future<String> create(
    String name, {
    List<MusicTrack> tracks = const [],
  }) async {
    final id = List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await _write(() async {
      if (playlists.length >= 100) throw const FormatException('最多创建 100 个歌单');
      await _save(
        MusicPlaylist.fromJson(MusicPlaylist(id, name.trim(), tracks).toJson()),
      );
    });
    return id;
  }

  Future<void> _save(MusicPlaylist list) => db.write(
    'INSERT OR REPLACE INTO app_meta VALUES(?,?)',
    ['music_playlist:${list.id}', jsonEncode(list.toJson())],
  );
  MusicPlaylist _playlist(String id) => playlists.firstWhere(
    (p) => p.id == id,
    orElse: () => throw const FormatException('歌单已删除，请刷新后重试'),
  );
  Future<void> rename(String id, String name) => _write(() async {
    final list = _playlist(id);
    await _save(
      MusicPlaylist.fromJson({...list.toJson(), 'name': name.trim()}),
    );
  });
  Future<void> delete(String id) => _write(
    () => db.write('DELETE FROM app_meta WHERE key=?', ['music_playlist:$id']),
  );
  Future<void> add(String id, MusicTrack track) => _write(() async {
    final list = _playlist(id);
    if (list.tracks.any((t) => t.key == track.key)) return;
    if (list.tracks.length >= 500) throw const FormatException('每个歌单最多 500 首');
    await _save(MusicPlaylist(id, list.name, [...list.tracks, track]));
  });
  Future<void> remove(String id, String key) => _write(() async {
    final list = _playlist(id);
    await _save(
      MusicPlaylist(
        id,
        list.name,
        list.tracks.where((t) => t.key != key).toList(),
      ),
    );
  });
  Future<void> move(String id, String key, int delta) => _write(() async {
    final list = _playlist(id);
    final tracks = list.tracks.toList();
    final from = tracks.indexWhere((t) => t.key == key);
    if (from < 0) return;
    final to = (from + delta).clamp(0, tracks.length - 1);
    final item = tracks.removeAt(from);
    tracks.insert(to, item);
    await _save(MusicPlaylist(id, list.name, tracks));
  });
  Future<void> setMode(MusicPlayMode value) => _write(
    () => db.write('INSERT OR REPLACE INTO app_meta VALUES(?,?)', [
      'music_mode',
      jsonEncode(value.name),
    ]),
  );
  Future<void> record(MusicTrack track, PlaybackSnapshot state) {
    var changes = 0;
    return _write(() async {
      if (state.duration <= Duration.zero) return;
      await db.write('INSERT OR REPLACE INTO app_meta VALUES(?,?)', [
        'music_history:${stableId(track.key)}',
        jsonEncode({
          'track': track.toJson(),
          'position': state.position.inMilliseconds.clamp(
            0,
            state.duration.inMilliseconds,
          ),
          'playedAt': DateTime.now().millisecondsSinceEpoch,
        }),
      ]);
      changes++;
      final rows = await db.rows(
        "SELECT key FROM app_meta WHERE key GLOB 'music_history:*' ORDER BY json_extract(value,'\$.playedAt') DESC LIMIT -1 OFFSET 200",
      );
      for (final row in rows) {
        await db.write('DELETE FROM app_meta WHERE key=?', [row['key']]);
        changes++;
      }
    }, historyChanges: () => changes);
  }

  Future<void> clearHistory() => _write(
    () => db.write("DELETE FROM app_meta WHERE key GLOB 'music_history:*'"),
  );
  Future<void> close() async {
    await _pending;
    _closed = true;
    super.dispose();
  }
}

bool validateMusicMetadata(String key, String text) {
  if (!(key.startsWith('music_playlist:') ||
      key.startsWith('music_history:') ||
      key == 'music_mode')) {
    return false;
  }
  final value = jsonDecode(text);
  if (key == 'music_mode') {
    MusicPlayMode.values.byName(value as String);
  } else if (key.startsWith('music_playlist:')) {
    final playlist = MusicPlaylist.fromJson(value as Map);
    if (key != 'music_playlist:${playlist.id}') {
      throw const FormatException('歌单标识无效');
    }
  } else {
    final data = value as Map;
    final track = MusicTrack.fromJson(data['track'] as Map);
    if (key != 'music_history:${stableId(track.key)}' ||
        data['position'] is! int ||
        (data['position'] as int) < 0 ||
        data['playedAt'] is! int) {
      throw const FormatException('播放历史无效');
    }
  }
  return true;
}

void validateMusicCollection(List<Map<String, Object?>> rows) {
  final playlists = rows
      .where((row) => (row['key'] as String).startsWith('music_playlist:'))
      .length;
  final history = rows
      .where((row) => (row['key'] as String).startsWith('music_history:'))
      .length;
  if (playlists > 100 || history > 200) {
    throw const FormatException('音乐备份超过歌单或历史容量限制');
  }
}
