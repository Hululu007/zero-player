/// Normalize publisher labels and user keywords without executing expressions.
String normalizeContent(String input) {
  const traditional = {
    '倫': '伦',
    '裏': '里',
    '無': '无',
    '碼': '码',
    '視': '视',
    '頻': '频',
    '區': '区',
    '國': '国',
    '產': '产',
    '愛': '爱',
    '慾': '欲',
    '劇': '剧',
    '級': '级',
    '寫': '写',
    '真': '真',
    '門': '门',
    '專': '专',
    '體': '体',
    '覽': '览',
  };
  final folded = String.fromCharCodes(
    input.runes.map((r) => r >= 0xff01 && r <= 0xff5e ? r - 0xfee0 : r),
  ).toLowerCase();
  return folded
      .split('')
      .map((c) => traditional[c] ?? c)
      .join()
      .replaceAll(_ignoredContentCharacters, '');
}

final _ignoredContentCharacters = RegExp(r'[^a-z0-9㐀-鿿]');
final _adultLabels = <String>{
  '成人',
  'adult',
  'erotic',
  'erotica',
  'sex',
  '成人专区',
  '伦理片',
  '伦理',
  '伦理剧',
  '理论片',
  '情色',
  '色情',
  '三级',
  '三级片',
  '日本av',
  '欧美av',
  'av',
  'xxx',
  '无码',
  '有码',
  '里番',
  '18禁',
  '十八禁',
  'r18',
  'r18g',
  '19禁',
  'hentai',
  'porn',
  'pornhub',
  '91porn',
  'javbus',
  'javdb',
  'javlibrary',
  'xnxx',
  'redtube',
  'youporn',
  'nsfw',
};
final _adultMarkers = <String>[
  '色情',
  '情色',
  '伦理片',
  '成人影片',
  '成人视频',
  '成人电影',
  '成人影院',
  '成人网站',
  '成人频道',
  '成人专区',
  '三级片',
  '三级伦理',
  '无码',
  '有码av',
  '里番',
  '十八禁',
  '麻豆传媒',
  '天美传媒',
  'av女优',
  '无修正',
  '淫乱',
  '乱伦',
  '性爱',
  '自慰',
  'pornhub',
  '91porn',
  'javbus',
  'javdb',
  'javlibrary',
  'xnxx',
  'redtube',
  'youporn',
  'xvideos',
  'xhamster',
  'hentai',
  'nsfw',
];
final _adultWords = RegExp(
  r'(^|[^a-z0-9])(av|xxx|r[ -]?18g?|porn(?:ography)?|hentai|nsfw)(?=$|[^a-z0-9])|18\s*\+|18\s*禁',
  caseSensitive: false,
);
final _invisibleContentCharacters = RegExp(
  r'[\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFEFF]',
);
final _regionalAdultLabel = RegExp(
  r'^(?:日本|韩国|日韩|欧美|港台|香港|台湾|国产|中国|西方)?(?:伦理|理论|三级)(?:片|剧|电影)?$',
);

bool adultContent(String text, {bool category = false}) {
  final normalized = _adultSearchText(text);
  final folded = String.fromCharCodes(
    text.runes.map((r) => r >= 0xff01 && r <= 0xff5e ? r - 0xfee0 : r),
  ).replaceAll(_invisibleContentCharacters, '');
  if (_adultMarkers.any(normalized.contains) || _adultWords.hasMatch(folded)) {
    return true;
  }
  if (_adultLabels.contains(normalized)) return true;
  if (category && _regionalAdultLabel.hasMatch(normalized)) {
    return true;
  }
  return category &&
      folded.split(RegExp(r'[,，/|、;；\s]+')).any((part) {
        final label = normalizeContent(part);
        return _adultLabels.contains(label) ||
            _regionalAdultLabel.hasMatch(label);
      });
}

/// Diagnostic tokens only. Callers must verify supervision credentials before
/// rendering these values; normal errors must use a generic reason.
List<String> adultContentMatches(String text) {
  final normalized = _adultSearchText(text);
  return {
    for (final marker in _adultMarkers)
      if (normalized.contains(marker)) marker,
    for (final match in _adultWords.allMatches(text)) match.group(0)!.trim(),
    if (_adultLabels.contains(normalized)) normalized,
  }.toList();
}

String _adultSearchText(String text) =>
    normalizeContent(text)
    // Verified ordinary compound: the color adjective and emotion noun meet
    // at a boundary that happens to form a restricted two-character token.
    // Only this complete phrase is exempt; other occurrences still match.
    .replaceAll('灰色情绪', '灰色心绪');

/// Return the original UTF-16 ranges recognized by the active detectors.
List<(int start, int end)> sensitiveContentSpans(
  String text, {
  required Iterable<String> keywords,
  required bool filterAdult,
}) {
  final terms = keywords.map(normalizeContent).where((word) => word.isNotEmpty);
  if (!terms.any(normalizeContent(text).contains) &&
      !(filterAdult && adultContent(text))) {
    return const [];
  }
  final matches = <(int, int)>[];
  final normalized = _ContentOffsets(text, normalizeContent);
  void findWords(String searchable, Iterable<String> words) {
    for (final word in words) {
      var offset = searchable.indexOf(word);
      while (offset >= 0) {
        matches.add(normalized.span(offset, offset + word.length));
        offset = searchable.indexOf(word, offset + 1);
      }
    }
  }

  findWords(normalized.text, terms);
  if (filterAdult) {
    final searchable = _adultSearchText(text);
    if (searchable.length == normalized.text.length) {
      findWords(searchable, _adultMarkers);
      if (_adultLabels.contains(searchable)) {
        matches.add(normalized.span(0, searchable.length));
      }
    }
    final folded = _ContentOffsets(text, (character) {
      final value = character.runes.single;
      return (value >= 0xff01 && value <= 0xff5e
              ? String.fromCharCode(value - 0xfee0)
              : character)
          .replaceAll(_invisibleContentCharacters, '');
    });
    for (final match in _adultWords.allMatches(folded.text)) {
      matches.add(
        folded.span(match.start + (match[1]?.length ?? 0), match.end),
      );
    }
  }
  return matches;
}

final class _ContentOffsets {
  _ContentOffsets(String original, String Function(String) transform) {
    final result = StringBuffer();
    var start = 0;
    for (final value in original.runes) {
      final character = String.fromCharCode(value);
      final end = start + character.length;
      final converted = transform(character);
      result.write(converted);
      for (var i = 0; i < converted.length; i++) {
        ranges.add((start, end));
      }
      start = end;
    }
    text = result.toString();
  }

  final ranges = <(int, int)>[];
  late final String text;
  (int, int) span(int start, int end) => (ranges[start].$1, ranges[end - 1].$2);
}
