import 'package:flutter/services.dart' show rootBundle;

final publicationHanText = RegExp(r'\p{Script=Han}', unicode: true);
Future<Map<int, int>>? _folding;

Future<Map<int, int>> publicationHanFold() => _folding ??= _loadFold();

Future<Map<int, int>> _loadFold() async {
  final source = await rootBundle.loadString(
    'assets/catalogs/books/chinese-search-fold.txt',
  );
  final mapping = <int, int>{};
  for (final line in source.split('\n')) {
    if (line.startsWith('#')) continue;
    final runes = line.runes.toList();
    if (runes.length == 2) mapping[runes.first] = runes.last;
  }
  return Map.unmodifiable(mapping);
}
