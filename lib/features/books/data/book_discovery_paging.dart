import 'dart:convert';

import '../domain/book.dart';
import '../domain/legado_source.dart';
import 'legado/legado_request.dart';

const _pageKeys = {
  'page',
  'p',
  'pageno',
  'page_no',
  'pageindex',
  'page_index',
  'pagenum',
  'page_num',
  'pn',
  'pi',
  'offset',
  'start',
};
final _script = RegExp(r'@js\s*:|<js>', caseSensitive: false);
final _encodedPathSeparator = RegExp(r'%(?:2f|5c|2e)', caseSensitive: false);

/// Check a concrete category alias without executing a restricted script.
bool bookDiscoveryCategoryDenied(
  BookSource source,
  LegadoCategory candidate,
  Iterable<LegadoCategory> denied,
) {
  if (const {
    BookFormat.shuyin,
    BookFormat.bookan,
    BookFormat.ximalaya,
  }.contains(source.format)) {
    // These adapters use opaque category IDs, not URL path components.
    return denied.any((item) => item.address == candidate.address);
  }
  final request = _request(source, candidate.address, 1);
  for (final item in denied) {
    if (item.address == candidate.address) return true;
    final restricted = _request(source, item.address, 1);
    try {
      // A skipped restricted script can resolve to any same-source address.
      // Without both concrete requests, the candidate cannot be proven safe.
      if (request == null ||
          restricted == null ||
          _denies(restricted, request)) {
        return true;
      }
    } on FormatException {
      return true;
    } on ArgumentError {
      return true;
    }
  }
  return false;
}

/// Only known, concrete restricted categories can classify a stored book URL.
/// An unknown script is not evidence that every book from the source is adult.
bool bookDiscoveryStaticBookDenied(
  BookSource source,
  Book book,
  Iterable<LegadoCategory> denied,
) {
  if (source.format != BookFormat.html) return false;
  try {
    final known = <(LegadoRequest, bool)>[];
    for (final category in denied) {
      final restricted = _request(source, category.address, 1);
      if (restricted != null) known.add((restricted, category.paginated));
    }
    if (known.isEmpty) return false;
    var target = book.request.isEmpty
        ? null
        : _request(source, book.request, 1);
    if (target == null || target.uri != source.requestTarget(book.uri)) {
      target = _request(source, book.uri.toString(), 1);
    }
    if (target == null) return false;
    for (final (restricted, paginated) in known) {
      if (_deniesBook(restricted, target, paginated)) {
        return true;
      }
    }
  } on FormatException {
    return false;
  } on ArgumentError {
    return false;
  } on TypeError {
    return false;
  }
  return false;
}

/// Accept only a page whose URL and request body remain within the selected
/// category. Unknown script-derived or unclassifiable next links fail closed.
bool bookDiscoveryNextAllowed(
  BookSource source,
  LegadoCategory? selected,
  Iterable<LegadoCategory> denied,
  String cursor,
  int nextPage,
) {
  if (nextPage < 2 || nextPage > 10000000) return false;
  if (const {
    BookFormat.shuyin,
    BookFormat.bookan,
    BookFormat.ximalaya,
  }.contains(source.format)) {
    // These adapters ignore cursor addresses; they use the verified category
    // and numeric page parameter to construct their own fixed API request.
    return int.tryParse(cursor) == nextPage;
  }
  if (source.format != BookFormat.html) return false;
  final target = _request(source, cursor, nextPage);
  return target != null &&
      _requestAllowed(source, selected, denied, target, nextPage);
}

bool _requestAllowed(
  BookSource source,
  LegadoCategory? selected,
  Iterable<LegadoCategory> denied,
  LegadoRequest target,
  int nextPage,
) {
  try {
    return _requestAllowedChecked(source, selected, denied, target, nextPage);
  } on FormatException {
    return false;
  } on ArgumentError {
    return false;
  } on TypeError {
    return false;
  }
}

bool _requestAllowedChecked(
  BookSource source,
  LegadoCategory? selected,
  Iterable<LegadoCategory> denied,
  LegadoRequest target,
  int nextPage,
) {
  final address = selected?.address ?? source.discover;
  final base = _request(source, address, 1);
  final expected = _request(source, address, nextPage);
  if (base == null || expected == null) return false;
  // Percent-encoded path separators/dots can have server-specific meanings.
  if (_encodedPathSeparator.hasMatch(_rawPath(target.uri))) return false;
  for (final item in denied) {
    final restricted = _request(source, item.address, 1);
    if (restricted == null || _denies(restricted, target)) {
      return false;
    }
  }
  if (!_fixedEqual(_query(base), _query(target)) ||
      !_sameBody(base, target) ||
      base.encoding.name != target.encoding.name ||
      jsonEncode(_canonical(base.headers)) !=
          jsonEncode(_canonical(target.headers)) ||
      !_pageValuesAllowed(
        _query(base),
        _query(expected),
        _query(target),
        nextPage,
      ) ||
      !_pageValuesAllowed(
        _body(base),
        _body(expected),
        _body(target),
        nextPage,
      )) {
    return false;
  }
  if (!_allowedPath(
    base.uri.path,
    expected.uri.path,
    target.uri.path,
    nextPage,
  )) {
    return false;
  }
  return _trimSlash(base.uri.path) != _trimSlash(target.uri.path) ||
      _pageChanged(_query(base), _query(target)) ||
      _pageChanged(_body(base), _body(target));
}

bool bookDiscoveryPageAllowed(
  BookSource source,
  LegadoCategory? selected,
  Iterable<LegadoCategory> denied,
  int page,
) {
  if (page < 1 || page > 10000000) return false;
  if (page == 1 || source.format != BookFormat.html) return true;
  final target = _request(source, selected?.address ?? source.discover, page);
  return target != null &&
      _requestAllowed(source, selected, denied, target, page);
}

LegadoRequest? _request(BookSource source, String address, int page) {
  if (address.isEmpty || _script.hasMatch(address)) return null;
  try {
    return LegadoRequest.parse(source, source.endpoint, address, page: page);
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  } on TypeError {
    return null;
  }
}

String _rawPath(Uri uri) => uri.toString().split('?').first.split('#').first;

bool _denies(LegadoRequest restricted, LegadoRequest target) {
  if (restricted.uri.host != target.uri.host ||
      !_restrictedPath(restricted.uri.path, target.uri.path) ||
      !_fixedContains(
        _requestParameters(target),
        _requestParameters(restricted),
      )) {
    return false;
  }
  return true;
}

bool _deniesBook(
  LegadoRequest restricted,
  LegadoRequest target,
  bool paginated,
) =>
    restricted.uri.host == target.uri.host &&
    (_trimSlash(restricted.uri.path) == _trimSlash(target.uri.path) ||
        (paginated && _restrictedPath(restricted.uri.path, target.uri.path))) &&
    _fixedContains(_requestParameters(target), _requestParameters(restricted));

String _trimSlash(String path) => path.length > 1 && path.endsWith('/')
    ? path.substring(0, path.length - 1)
    : path;

bool _restrictedPath(String restricted, String target) {
  final base = _trimSlash(restricted);
  final next = _trimSlash(target);
  if (base == next || _appendedPage(base, next) != null) return true;
  // A restricted numeric sibling can be another page of the same category.
  // This deliberately errs on the side of hiding an ambiguous category ID.
  return _siblingPage(base, next) != null;
}

bool _allowedPath(String initial, String expected, String target, int page) {
  final base = _trimSlash(initial);
  final next = _trimSlash(target);
  if (base == next) return true;
  final appended = _appendedPage(base, next);
  if (appended != null) {
    return appended == page ||
        (_trimSlash(expected) != base && _trimSlash(expected) == next);
  }
  final sibling = _siblingPage(base, next);
  if (sibling == null) return false;
  if (_trimSlash(expected) != base && _trimSlash(expected) == next) return true;
  return _explicitPageTail(base) && sibling == page;
}

bool _explicitPageTail(String path) {
  final match = RegExp(
    r'^(.*)([/_-])([0-9]+)(\.(?:html?|shtml))?$',
    caseSensitive: false,
  ).firstMatch(path);
  if (match == null || int.tryParse(match.group(3)!) != 1) return false;
  if (match.group(2) != '/') return true;
  final segments = match.group(1)!.split('/').where((part) => part.isNotEmpty);
  // A lone /sort/1 can be a category ID rather than page one.
  return segments.length >= 2 ||
      const {'page', 'pages', 'p'}.contains(segments.lastOrNull?.toLowerCase());
}

int? _appendedPage(String base, String target) {
  final extension = RegExp(
    r'\.(?:html?|shtml)$',
    caseSensitive: false,
  ).firstMatch(base);
  final stem = extension == null ? base : base.substring(0, extension.start);
  final suffix = extension?.group(0) ?? '';
  final pattern = RegExp(
    '^${RegExp.escape(stem)}(?:/|_|-)([0-9]+)${RegExp.escape(suffix)}\$',
    caseSensitive: false,
  );
  return int.tryParse(pattern.firstMatch(target)?.group(1) ?? '');
}

int? _siblingPage(String base, String target) {
  final pattern = RegExp(
    r'^(.*[/_-])([0-9]+)(\.(?:html?|shtml))?$',
    caseSensitive: false,
  );
  final a = pattern.firstMatch(base), b = pattern.firstMatch(target);
  if (a == null ||
      b == null ||
      a.group(1) != b.group(1) ||
      (a.group(3) ?? '').toLowerCase() != (b.group(3) ?? '').toLowerCase()) {
    return null;
  }
  return int.tryParse(b.group(2)!);
}

Map<String, Object?> _query(LegadoRequest request) => {
  for (final entry in request.uri.queryParametersAll.entries)
    entry.key: entry.value,
};

Map<String, Object?> _body(LegadoRequest request) =>
    request.form ?? request.json ?? const {};

// Servers may read the same discriminator from query, form, or JSON. Merge
// these only for denial; positive pagination checks keep the original carrier.
Map<String, Object?> _requestParameters(LegadoRequest request) {
  final values = <String, List<Object?>>{};
  for (final part in [_fixed(_query(request)), _fixed(_body(request))]) {
    for (final entry in part.entries) {
      final target = values.putIfAbsent(entry.key.toLowerCase(), () => []);
      target.addAll(entry.value is List ? entry.value as List : [entry.value]);
    }
  }
  return values;
}

bool _sameBody(LegadoRequest base, LegadoRequest target) =>
    (base.form != null) == (target.form != null) &&
    (base.json != null) == (target.json != null) &&
    _fixedEqual(_body(base), _body(target));

bool _isPageValue(String key, Object? value) {
  if (!_pageKeys.contains(key.toLowerCase())) return false;
  final values = value is List ? value : [value];
  return values.isNotEmpty &&
      values.every((item) => int.tryParse('$item') != null);
}

Map<String, Object?> _fixed(Map<String, Object?> value) => {
  for (final entry in value.entries)
    if (!_isPageValue(entry.key, entry.value))
      entry.key: _canonical(entry.value),
};

bool _fixedEqual(Map<String, Object?> a, Map<String, Object?> b) =>
    jsonEncode(_canonical(_fixed(a))) == jsonEncode(_canonical(_fixed(b)));

bool _fixedContains(
  Map<String, Object?> candidate,
  Map<String, Object?> restricted,
) {
  Map<String, List<Object?>> fold(Map<String, Object?> input) {
    final result = <String, List<Object?>>{};
    for (final entry in _fixed(input).entries) {
      (result[entry.key.toLowerCase()] ??= []).addAll(
        entry.value is List ? entry.value as List : [entry.value],
      );
    }
    return result;
  }

  final actual = fold(candidate);
  final required = fold(restricted);
  return required.entries.every((entry) {
    final value = actual[entry.key];
    return value != null &&
        entry.value.every(
          (requiredValue) => value.any(
            (candidateValue) =>
                _denialValue(candidateValue) == _denialValue(requiredValue),
          ),
        );
  });
}

String _denialValue(Object? value) =>
    value is String || value is num || value is bool
    ? '$value'
    : jsonEncode(_canonical(value));

bool _pageChanged(Map<String, Object?> base, Map<String, Object?> target) =>
    target.entries.any(
      (entry) =>
          _isPageValue(entry.key, entry.value) &&
          jsonEncode(entry.value) != jsonEncode(base[entry.key]),
    );

bool _pageValuesAllowed(
  Map<String, Object?> base,
  Map<String, Object?> expected,
  Map<String, Object?> target,
  int page,
) {
  for (final entry in target.entries) {
    if (!_isPageValue(entry.key, entry.value)) continue;
    final values = entry.value is List ? entry.value as List : [entry.value];
    if (values.length != 1) return false;
    final actual = int.tryParse('${values.single}');
    if (actual == null || actual < 0 || actual > 10000000) return false;
    final old = _singleNumber(base[entry.key]);
    final rendered = _singleNumber(expected[entry.key]);
    if (rendered != null && rendered != old) {
      if (actual != rendered) return false;
    } else if (actual != old && actual != page) {
      return false;
    }
  }
  return true;
}

int? _singleNumber(Object? value) {
  final values = value is List ? value : [value];
  return values.length == 1 ? int.tryParse('${values.single}') : null;
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}
