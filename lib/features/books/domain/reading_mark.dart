enum ReadingMarkStyle {
  underline('直线'),
  wave('波浪线'),
  highlight('背景高亮'),
  outline('框选');

  const ReadingMarkStyle(this.label);
  final String label;
}

typedef ReadingRange = ({int start, int end});

final class ReadingMark {
  const ReadingMark({
    required this.digest,
    required this.section,
    required this.range,
    required this.quote,
    this.style = ReadingMarkStyle.underline,
    this.color = 0,
    this.bookmark = false,
  });

  final String digest, quote;
  final int section, color;
  final ReadingRange range;
  final ReadingMarkStyle style;
  final bool bookmark;

  (String, int, int, int) get identity =>
      (digest, section, range.start, range.end);

  ReadingMark copyWith({ReadingMarkStyle? style, int? color, bool? bookmark}) =>
      ReadingMark(
        digest: digest,
        section: section,
        range: range,
        quote: quote,
        style: style ?? this.style,
        color: color ?? this.color,
        bookmark: bookmark ?? this.bookmark,
      );

  bool matches(String text) =>
      range.start >= 0 &&
      range.end <= text.length &&
      text.substring(range.start, range.end) == quote;

  Map<String, Object?> toJson() => {
    'digest': digest,
    'section': section,
    'start': range.start,
    'end': range.end,
    'quote': quote,
    'style': style.name,
    'color': color,
    'bookmark': bookmark,
  };

  static List<ReadingMark> decode(Object? value, {String? digest}) {
    if (value == null) return const [];
    if (value is! List || value.length > 1000) {
      throw const FormatException('标注记录无效');
    }
    final marks = <ReadingMark>[];
    final keys = <(String, int, int, int)>{};
    for (final row in value) {
      if (row
          case {
            'digest': final String version,
            'section': final int section,
            'start': final int start,
            'end': final int end,
            'quote': final String quote,
            'style': final String kind,
            'color': final int color,
            'bookmark': final bool bookmark,
          }
          when RegExp(r'^[a-f0-9]{64}$').hasMatch(version) &&
              (digest == null || digest == version) &&
              section >= 0 &&
              section < 100000 &&
              start >= 0 &&
              end > start &&
              end <= 32 * 1024 * 1024 &&
              quote.length == end - start &&
              quote.length <= 1200 &&
              color >= 0 &&
              color < 5) {
        final style = ReadingMarkStyle.values
            .where((style) => style.name == kind)
            .firstOrNull;
        if (style != null && keys.add((version, section, start, end))) {
          marks.add(
            ReadingMark(
              digest: version,
              section: section,
              range: (start: start, end: end),
              quote: quote,
              style: style,
              color: color,
              bookmark: bookmark,
            ),
          );
          continue;
        }
      }
      throw const FormatException('标注内容或版本无效');
    }
    return marks;
  }
}
