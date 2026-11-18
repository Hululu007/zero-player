import 'book.dart';

({int number, String name})? _numbered(String title) {
  final match = RegExp(r'^第\s*([0-9]+)\s*章\s*(.*)$').firstMatch(title.trim());
  if (match == null) return null;
  final number = int.tryParse(match[1]!);
  return number == null
      ? null
      : (number: number, name: bookIdentity(match[2]!));
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
