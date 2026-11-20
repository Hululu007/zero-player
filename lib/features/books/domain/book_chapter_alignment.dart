import 'book.dart';

({int number, String name})? _numbered(String title) {
  final match = RegExp(r'^第\s*([0-9]+)\s*章\s*(.*)$').firstMatch(title.trim());
  if (match == null) return null;
  final number = int.tryParse(match[1]!);
  return number == null
      ? null
      : (number: number, name: bookIdentity(match[2]!));
}

/// Index a verified edition once for a download batch. Shifted numbering can
/// match only a unique subtitle with two nearby anchors at the same offset.
final class BookChapterFallbackIndex {
  BookChapterFallbackIndex(this._chapters) {
    for (var i = 0; i < _chapters.length; i++) {
      final title = bookIdentity(_chapters[i].title);
      _titles.update(title, (_) => null, ifAbsent: () => i);
      final number = _numbered(_chapters[i].title);
      _numberedTitles.add(number);
      if (number != null && number.name.isNotEmpty) {
        _subtitles.update(number.name, (_) => null, ifAbsent: () => i);
      }
    }
  }

  final List<BookChapter> _chapters;
  final _titles = <String, int?>{};
  final _subtitles = <String, int?>{};
  final _numberedTitles = <({int number, String name})?>[];

  BookChapter? match(BookChapter reference, BookChapterFallbackIndex other) {
    final key = bookIdentity(reference.title);
    if (key.isEmpty) return null;
    if (other._titles.containsKey(key)) {
      final index = other._titles[key];
      return index == null ? null : other._chapters[index];
    }
    final from = _titles[key];
    if (from == null) return null;
    final title = _numberedTitles[from];
    if (title == null || _subtitles[title.name] != from) return null;
    final to = other._subtitles[title.name];
    if (to == null) return null;
    final drift = other._numberedTitles[to]!.number - title.number;
    var anchors = 0;
    for (final step in [-2, -1, 1, 2]) {
      if (_isAnchor(from, to, step, drift, other)) anchors++;
    }
    return anchors >= 2 ? other._chapters[to] : null;
  }

  bool _isAnchor(
    int from,
    int to,
    int step,
    int drift,
    BookChapterFallbackIndex other,
  ) {
    final a = from + step;
    final b = to + step;
    if (a < 0 ||
        b < 0 ||
        a >= _chapters.length ||
        b >= other._chapters.length) {
      return false;
    }
    final left = _numberedTitles[a];
    final right = other._numberedTitles[b];
    return left != null &&
        right != null &&
        _subtitles[left.name] == a &&
        other._subtitles[left.name] == b &&
        left.number - _numberedTitles[from]!.number == step &&
        right.number - left.number == drift;
  }
}

/// A number-only title needs two preceding, fully named chapters to agree.
/// Conflicting subtitles, split chapters and repeated boundaries stay ambiguous.
int? bookChapterTailBoundary(
  List<BookChapter> current,
  List<BookChapter> other,
) {
  if (current.isEmpty) return null;
  final key = bookIdentity(current.last.title);
  final exact = <int>[
    for (var i = 0; i < other.length; i++)
      if (bookIdentity(other[i].title) == key) i,
  ];
  if (exact.length > 1) return null;
  if (exact.length == 1) {
    final index = exact.single;
    if (current.length == 1 ||
        index > 0 &&
            bookIdentity(current[current.length - 2].title) ==
                bookIdentity(other[index - 1].title)) {
      return index;
    }
    return null;
  }
  final last = _numbered(current.last.title);
  if (last == null || current.length < 3) return null;
  if (other.where((c) => _numbered(c.title)?.number == last.number).length !=
      1) {
    return null;
  }
  final candidates = <int>[];
  for (var i = 2; i < other.length; i++) {
    final candidate = _numbered(other[i].title);
    if (candidate == null ||
        candidate.number != last.number ||
        last.name.isNotEmpty && candidate.name.isNotEmpty) {
      continue;
    }
    var aligned = true;
    for (var offset = 1; offset <= 2; offset++) {
      final a = _numbered(current[current.length - 1 - offset].title);
      final b = _numbered(other[i - offset].title);
      if (a == null ||
          b == null ||
          a.number != last.number - offset ||
          b.number != a.number ||
          a.name.isEmpty ||
          a.name != b.name) {
        aligned = false;
        break;
      }
    }
    if (aligned) candidates.add(i);
  }
  return candidates.length == 1 ? candidates.single : null;
}
