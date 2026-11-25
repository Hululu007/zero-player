final class BookDetectedReplacement {
  const BookDetectedReplacement(
    this.text, {
    this.paragraph = false,
    this.before = 0,
    this.after = 0,
  });

  static const maxOffset = 20;
  final String text;
  final bool paragraph;
  final int before, after;

  factory BookDetectedReplacement.fromJson(Map raw) {
    final text = raw['text'];
    final before = raw['before'], after = raw['after'];
    if (text is! String ||
        text.length > 1000 ||
        raw['paragraph'] is! bool ||
        before is! int ||
        after is! int ||
        before < 0 ||
        before > maxOffset ||
        after < 0 ||
        after > maxOffset) {
      throw const FormatException('自动替换配置无效');
    }
    return BookDetectedReplacement(
      text,
      paragraph: raw['paragraph'] == true,
      before: before,
      after: after,
    );
  }

  Map<String, Object> toJson() => {
    'text': text,
    'paragraph': paragraph,
    'before': before,
    'after': after,
  };

  String apply(String body, List<(int, int)> matches) {
    if (matches.isEmpty) return body;
    final ranges = paragraph ? _expandParagraphs(body, matches) : matches;
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    final result = StringBuffer();
    var cursor = 0;
    for (var index = 0; index < ranges.length; index++) {
      final (start, end) = ranges[index];
      var limit = end;
      while (index + 1 < ranges.length && ranges[index + 1].$1 <= limit) {
        final nextEnd = ranges[++index].$2;
        if (nextEnd > limit) limit = nextEnd;
      }
      result
        ..write(body.substring(cursor, start))
        ..write(text);
      cursor = limit;
      if (result.length > 8 * 1024 * 1024) {
        throw const FormatException('替换后正文超过大小限制');
      }
    }
    return (result..write(body.substring(cursor))).toString();
  }

  List<(int, int)> _expandParagraphs(String body, List<(int, int)> matches) {
    final paragraphs = <(int, int)>[];
    var start = 0;
    for (final separator in RegExp(r'(?:\r?\n[ \t]*)+').allMatches(body)) {
      if (separator.start > start) paragraphs.add((start, separator.start));
      start = separator.end;
    }
    if (start < body.length) paragraphs.add((start, body.length));
    int paragraphAt(int offset) {
      var start = 0, end = paragraphs.length - 1;
      while (start < end) {
        final middle = (start + end) ~/ 2;
        if (offset < paragraphs[middle].$2) {
          end = middle;
        } else {
          start = middle + 1;
        }
      }
      return start;
    }

    return [
      for (final (start, end) in matches)
        (
          paragraphs[(paragraphAt(start) - before).clamp(
                0,
                paragraphs.length - 1,
              )]
              .$1,
          paragraphs[(paragraphAt(end - 1) + after).clamp(
                0,
                paragraphs.length - 1,
              )]
              .$2,
        ),
    ];
  }
}
