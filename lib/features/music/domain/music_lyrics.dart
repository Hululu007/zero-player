import '../../../core/text/display_text.dart';

typedef MusicLyricLine = ({Duration time, String text, String translation});

final class MusicLyrics {
  MusicLyrics._(this.lines, this.sourceId);
  static final empty = MusicLyrics._(const [], '');
  final List<MusicLyricLine> lines;
  final String sourceId;
  late final String originalLrc = _toLrc(translated: false);
  late final String translatedLrc = _toLrc(translated: true);
  static final _timestamp = RegExp(
    r'\[(\d{1,3}):([0-5]\d)(?:[.:](\d{1,3}))?\]',
  );
  static final _offset = RegExp(
    r'^\[offset:([+-]?\d{1,6})\]$',
    multiLine: true,
  );
  static final _wordTimestamp = RegExp(r'<\d{1,3}:[0-5]\d(?:[.:]\d{1,3})?>');
  static final _yrcLine = RegExp(r'^\[(\d{1,9}),\d{1,9}\](.*)$');
  static final _yrcWord = RegExp(r'\(\d{1,9},\d{1,9},\d+\)');
  static final _krcLine = RegExp(r'^\[(\d{1,9}),\d{1,9}\](.*)$');
  static final _krcWord = RegExp(r'<\d{1,9},\d{1,9},\d+>');

  factory MusicLyrics.parse(
    String original,
    String translation, {
    String sourceId = 'netease',
  }) {
    final source = _parseLrc(original);
    final translated = _parseLrc(translation);
    return MusicLyrics._(_merged(source, translated), sourceId);
  }

  /// NetEase's YRC has line start/duration and optional per-word stamps.
  factory MusicLyrics.parseYrc(String original, String translation) {
    final source = <int, String>{};
    for (final row in original.replaceAll('\r', '').split('\n')) {
      final match = _yrcLine.firstMatch(row);
      if (match == null) continue;
      final time = int.tryParse(match.group(1)!);
      if (time == null || time > 86400000) continue;
      final value = displayText(match.group(2)!.replaceAll(_yrcWord, ''));
      if (value.length > 1000) continue;
      source[time] = value;
      if (source.length >= 2000) break;
    }
    return MusicLyrics._(_merged(source, _parseLrc(translation)), 'netease');
  }

  factory MusicLyrics.parseKrc(String original) {
    final source = <int, String>{};
    final normalized = original.replaceAll('\r', '').replaceAll('\uFEFF', '');
    final offset =
        int.tryParse(
          RegExp(
                r'^\[offset:([+-]?\d{1,6})\]$',
                multiLine: true,
              ).firstMatch(normalized)?.group(1) ??
              '',
        ) ??
        0;
    for (final row in normalized.split('\n')) {
      final match = _krcLine.firstMatch(row);
      if (match == null) continue;
      final time = int.tryParse(match.group(1)!);
      if (time == null || time > 86400000) continue;
      final value = displayText(match.group(2)!.replaceAll(_krcWord, ''));
      if (value.length > 1000) continue;
      source[(time - offset).clamp(0, 86400000)] = value;
      if (source.length >= 2000) break;
    }
    return MusicLyrics._(_merged(source, const {}), 'kugou');
  }

  static List<MusicLyricLine> _merged(
    Map<int, String> source,
    Map<int, String> translated,
  ) {
    return List.unmodifiable([
      for (final time in source.keys.toList()..sort())
        (
          time: Duration(milliseconds: time),
          text: source[time]!,
          translation: translated[time] ?? _nearTranslation(translated, time),
        ),
    ]);
  }

  static String _nearTranslation(Map<int, String> lines, int time) {
    var nearest = 251;
    var text = '';
    for (final entry in lines.entries) {
      final distance = (entry.key - time).abs();
      if (distance < nearest) {
        nearest = distance;
        text = entry.value;
      }
    }
    return text;
  }

  static Map<int, String> _parseLrc(String lrc) {
    final normalized = lrc.replaceAll('\r', '');
    final offset =
        int.tryParse(_offset.firstMatch(normalized)?.group(1) ?? '') ?? 0;
    final lines = <int, String>{};
    for (final line in normalized.split('\n')) {
      final tags = <Match>[];
      var start = 0;
      while (tags.length < 16) {
        final tag = _timestamp.matchAsPrefix(line, start);
        if (tag == null) break;
        tags.add(tag);
        start = tag.end;
      }
      if (tags.isEmpty) continue;
      final text = displayText(
        line.substring(start).replaceAll(_wordTimestamp, ''),
      );
      if (text.length > 1000) continue;
      for (final tag in tags) {
        final fraction = (tag.group(3) ?? '').padRight(3, '0');
        final time =
            int.parse(tag.group(1)!) * 60000 +
            int.parse(tag.group(2)!) * 1000 +
            int.parse(fraction) -
            offset;
        lines[time < 0 ? 0 : time] = text;
        if (lines.length >= 2000) return lines;
      }
    }
    return lines;
  }

  MusicLyrics filtered(bool Function(String) allowed) => MusicLyrics._(
    List.unmodifiable([
      for (final line in lines)
        (
          time: line.time,
          text: allowed(line.text) ? line.text : '',
          translation: allowed(line.translation) ? line.translation : '',
        ),
    ]),
    sourceId,
  );

  int indexAt(Duration position) {
    var low = 0;
    var high = lines.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (lines[mid].time <= position) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low - 1;
  }

  MusicLyricLine? lineAt(Duration position) {
    final index = indexAt(position);
    return index < 0 ? null : lines[index];
  }

  String _toLrc({required bool translated}) => [
    for (final line in lines)
      if (translated ? line.translation.isNotEmpty : line.text.isNotEmpty)
        '[${line.time.inMinutes.toString().padLeft(2, '0')}:'
            '${(line.time.inSeconds % 60).toString().padLeft(2, '0')}.'
            '${(line.time.inMilliseconds % 1000).toString().padLeft(3, '0')}]'
            '${translated ? line.translation : line.text}',
  ].join('\n');
}
