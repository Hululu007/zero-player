import 'book.dart';

// This is an advisory text scan, not a JavaScript parser or malware detector.
// Source comments alone are metadata; only fields the app can execute count.
final _dynamicCode = RegExp(r'\beval\s*\(|\b(?:new\s+)?Function\s*\(');
final _scriptMarker = RegExp(r'<js>|@js:', caseSensitive: false);
final _cachedClues = Expando<bool>();

bool _containsDynamicCode(String value) =>
    (value.contains('eval') || value.contains('Function')) &&
    _dynamicCode.hasMatch(value);

/// Warn about visible source rules using dynamic evaluation without running
/// them. An absent clue does not establish that the source or website is safe.
bool bookSourceHasDynamicCode(BookSource source) {
  final cached = _cachedClues[source];
  if (cached != null) return cached;
  final legacy = source.legado;
  if (legacy == null) return _cachedClues[source] = false;
  if (_containsDynamicCode(legacy.library)) return _cachedClues[source] = true;
  final executable = [
    legacy.search,
    ...legacy.categories.map((category) => category.address),
    ...legacy.rules.values,
  ];
  for (final rule in executable) {
    if (_scriptMarker.hasMatch(rule) && _containsDynamicCode(rule)) {
      return _cachedClues[source] = true;
    }
  }
  return _cachedClues[source] = false;
}
