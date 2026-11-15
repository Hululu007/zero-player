import 'package:html/dom.dart' as dom;

import '../../../core/network/header_policy.dart';

/// Advisory patterns in an inert homepage sample, never a malware verdict.
enum BookPageScriptClue { crossOriginRedirect, decodedDynamicEvaluation }

/// `sampled` covers only the bounded inline script elements, not the whole site.
enum BookPageScriptCoverage { notChecked, sampled, partial }

final class BookPageScriptReview {
  const BookPageScriptReview({
    this.coverage = BookPageScriptCoverage.notChecked,
    this.clues = const {},
  });

  final BookPageScriptCoverage coverage;
  final Set<BookPageScriptClue> clues;
  bool get hasClues => clues.isNotEmpty;

  Map<String, Object> toJson() => {
    'version': 1,
    'coverage': coverage.name,
    'clues': [
      for (final value in BookPageScriptClue.values)
        if (clues.contains(value)) value.name,
    ],
  };

  static bool validJson(Object? value) {
    if (value is! Map || value['version'] != 1 || value['clues'] is! List) {
      return false;
    }
    final rawCoverage = value['coverage'];
    final coverage = BookPageScriptCoverage.values
        .where((entry) => entry.name == rawCoverage)
        .firstOrNull;
    if (coverage == null) return false;
    final raw = value['clues'] as List;
    if (raw.length > BookPageScriptClue.values.length ||
        raw.toSet().length != raw.length ||
        raw.any(
          (name) =>
              name is! String ||
              !BookPageScriptClue.values.any((clue) => clue.name == name),
        ) ||
        (coverage == BookPageScriptCoverage.notChecked && raw.isNotEmpty)) {
      return false;
    }
    return true;
  }

  static BookPageScriptReview fromJson(Object? value) {
    if (!validJson(value)) return const BookPageScriptReview();
    final map = value as Map;
    final coverage = BookPageScriptCoverage.values.firstWhere(
      (entry) => entry.name == map['coverage'],
    );
    final raw = map['clues'] as List;
    return BookPageScriptReview(
      coverage: coverage,
      clues: Set.unmodifiable(
        BookPageScriptClue.values.where((clue) => raw.contains(clue.name)),
      ),
    );
  }
}

const _maxElements = 2048;
const _maxScriptElements = 64;
const _maxInlineScripts = 8;
const _maxInlineCharacters = 8192;
const _maxTotalCharacters = 32768;
const _maxTokens = 4096;

/// The DOM is already a bounded, inert sample. No script, URL or text escapes
/// this function: the returned review contains only finite enum values.
BookPageScriptReview inspectBookPageScripts(
  dom.Document document,
  Uri origin, {
  required bool truncated,
}) {
  var partial = truncated;
  var scriptElements = 0, inlineScripts = 0, total = 0, elements = 0;
  final clues = <BookPageScriptClue>{};
  for (final element in document.querySelectorAll('*')) {
    if (++elements > _maxElements) {
      partial = true;
      break;
    }
    final inertParent = _inertParent(element);
    if (inertParent != null) {
      if (inertParent == 'svg') partial = true;
      continue;
    }
    final tag = element.localName?.toLowerCase();
    if (tag == 'iframe' || tag == 'object' || tag == 'embed') partial = true;
    if (tag == 'base' && element.attributes.containsKey('href')) partial = true;
    for (final attribute in element.attributes.entries) {
      final key = attribute.key;
      if (key is String && key.toLowerCase().startsWith('on')) partial = true;
      if (key is String &&
          (key.toLowerCase() == 'href' || key.toLowerCase() == 'src') &&
          attribute.value.trimLeft().toLowerCase().startsWith('javascript:')) {
        partial = true;
      }
    }
    if (tag != 'script') continue;
    if (++scriptElements > _maxScriptElements) {
      partial = true;
      break;
    }
    final declaredType = element.attributes['type'];
    final language = (element.attributes['language'] ?? '')
        .trim()
        .toLowerCase();
    final type = declaredType != null
        ? declaredType.trim().toLowerCase()
        : language.isEmpty
        ? ''
        : 'text/$language';
    if (!_executableScriptType(type)) continue;
    if (type == 'module') partial = true; // Static imports are not fetched.
    if (element.attributes.containsKey('src')) {
      partial = true;
      continue;
    }
    if (++inlineScripts > _maxInlineScripts) {
      partial = true;
      continue;
    }
    final text = element.text;
    total += text.length;
    if (text.length > _maxInlineCharacters || total > _maxTotalCharacters) {
      partial = true;
      continue;
    }
    final scan = _scanScript(text, origin);
    clues.addAll(scan.clues);
    partial = partial || scan.partial;
  }
  return BookPageScriptReview(
    coverage: partial
        ? BookPageScriptCoverage.partial
        : BookPageScriptCoverage.sampled,
    clues: Set.unmodifiable(clues),
  );
}

String? _inertParent(dom.Element element) {
  for (var parent = element.parent; parent != null; parent = parent.parent) {
    final tag = parent.localName?.toLowerCase();
    if (const {'template', 'noscript', 'svg'}.contains(tag)) {
      return tag;
    }
  }
  return null;
}

bool _executableScriptType(String type) => const {
  '',
  'module',
  'text/javascript',
  'application/javascript',
  'application/x-javascript',
  'text/ecmascript',
  'application/ecmascript',
  'application/x-ecmascript',
  'text/javascript1.0',
  'text/javascript1.1',
  'text/javascript1.2',
  'text/javascript1.3',
  'text/javascript1.4',
  'text/javascript1.5',
  'text/jscript',
  'text/livescript',
  'text/x-ecmascript',
  'text/x-javascript',
}.contains(type);

enum _TokenKind { word, number, string, symbol }

final class _Token {
  const _Token(this.kind, this.value);
  final _TokenKind kind;
  final String? value;
  bool isValue(String expected) => value == expected;
}

final class _Lexed {
  const _Lexed(this.tokens, this.partial);
  final List<_Token> tokens;
  final bool partial;
}

bool _wordStart(int c) =>
    (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 36 || c == 95;
bool _digit(int c) => c >= 48 && c <= 57;

/// Conservative lexer: ambiguous slash/regex or template syntax stops the
/// remaining scan. Quoted text and comments never become executable tokens.
_Lexed _lex(String text) {
  final tokens = <_Token>[];
  var i = 0, partial = false;
  while (i < text.length) {
    if (tokens.length >= _maxTokens) return _Lexed(tokens, true);
    final c = text.codeUnitAt(i);
    if (c <= 32) {
      i++;
      continue;
    }
    if (text.startsWith('//', i) ||
        text.startsWith('<!--', i) ||
        text.startsWith('-->', i)) {
      if (!text.startsWith('//', i)) partial = true;
      final end = text.indexOf('\n', i);
      i = end < 0 ? text.length : end + 1;
      continue;
    }
    if (text.startsWith('/*', i)) {
      final end = text.indexOf('*/', i + 2);
      if (end < 0) return _Lexed(tokens, true);
      i = end + 2;
      continue;
    }
    if (c == 47 || c == 96) return _Lexed(tokens, true);
    if (c == 34 || c == 39) {
      final start = ++i;
      var escaped = false;
      while (i < text.length && text.codeUnitAt(i) != c) {
        if (text.codeUnitAt(i) == 10 || text.codeUnitAt(i) == 13) {
          return _Lexed(tokens, true);
        }
        if (text.codeUnitAt(i) == 92) {
          escaped = true;
          i++;
        }
        i++;
      }
      if (i >= text.length) return _Lexed(tokens, true);
      tokens.add(
        _Token(_TokenKind.string, escaped ? null : text.substring(start, i)),
      );
      partial = partial || escaped;
      i++;
      continue;
    }
    if (_wordStart(c)) {
      final start = i++;
      while (i < text.length &&
          (_wordStart(text.codeUnitAt(i)) || _digit(text.codeUnitAt(i)))) {
        i++;
      }
      tokens.add(_Token(_TokenKind.word, text.substring(start, i)));
      continue;
    }
    if (_digit(c)) {
      final start = i++;
      while (i < text.length && _digit(text.codeUnitAt(i))) {
        i++;
      }
      tokens.add(_Token(_TokenKind.number, text.substring(start, i)));
      continue;
    }
    if (!'.,;:()[]{}=!?+-*%&|<>^~'.contains(text[i])) {
      return _Lexed(tokens, true);
    }
    final start = i++;
    while (i < text.length &&
        i - start < 3 &&
        '=!<>?&|+-'.contains(text[i]) &&
        '=!<>?&|+-'.contains(text[start])) {
      i++;
    }
    tokens.add(_Token(_TokenKind.symbol, text.substring(start, i)));
  }
  return _Lexed(tokens, partial);
}

({Set<BookPageScriptClue> clues, bool partial}) _scanScript(
  String text,
  Uri origin,
) {
  final lexed = _lex(text);
  final tokens = lexed.tokens;
  if (_hasAmbiguousBinding(tokens)) return (clues: {}, partial: true);
  final clues = <BookPageScriptClue>{};
  var partial = lexed.partial;
  for (var i = 0; i < tokens.length; i++) {
    // Computed access could refer to location or evaluation APIs, but this
    // deliberately small lexer does not interpret properties or expressions.
    if ((_at(tokens, i, 'window') ||
            _at(tokens, i, 'document') ||
            _at(tokens, i, 'globalThis')) &&
        _at(tokens, i + 1, '[')) {
      partial = true;
    }
    final redirect = _redirectCandidate(tokens, i);
    if (redirect != null) {
      final result = redirect.literal == null
          ? null
          : _crossOriginLiteral(origin, redirect.literal!);
      if (result == null) {
        partial = true;
      } else if (result) {
        clues.add(BookPageScriptClue.crossOriginRedirect);
      }
    }
    final evaluation = _evaluationCallee(tokens, i);
    if (evaluation != null) {
      if (_decodedEvaluation(tokens, evaluation)) {
        clues.add(BookPageScriptClue.decodedDynamicEvaluation);
      } else {
        partial = true;
      }
    }
  }
  return (clues: clues, partial: partial);
}

bool _hasAmbiguousBinding(List<_Token> tokens) {
  const sensitive = {
    'window',
    'document',
    'location',
    'globalThis',
    'eval',
    'Function',
    'String',
    'atob',
    'decodeURIComponent',
    'unescape',
  };
  const declarations = {'var', 'let', 'const', 'function', 'class', 'import'};
  for (var i = 0; i < tokens.length; i++) {
    if (tokens[i].kind != _TokenKind.word ||
        !sensitive.contains(tokens[i].value)) {
      continue;
    }
    final previous = i > 0 && tokens[i - 1].kind != _TokenKind.string
        ? tokens[i - 1].value
        : null;
    final next =
        i + 1 < tokens.length && tokens[i + 1].kind != _TokenKind.string
        ? tokens[i + 1].value
        : null;
    if (declarations.contains(previous) ||
        ((previous == '(' || previous == ',') &&
            (next == ')' || next == ','))) {
      return true;
    }
  }
  return false;
}

bool _at(List<_Token> tokens, int index, String value) =>
    index >= 0 &&
    index < tokens.length &&
    tokens[index].kind != _TokenKind.string &&
    tokens[index].isValue(value);

bool _independent(List<_Token> tokens, int index) =>
    index == 0 ||
    !const {
      '.',
      '?.',
      'function',
      'class',
      'const',
      'let',
      'var',
    }.contains(tokens[index - 1].value);

final class _RedirectCandidate {
  const _RedirectCandidate(this.literal);
  final String? literal;
}

_RedirectCandidate? _redirectCandidate(List<_Token> tokens, int i) {
  if (!_independent(tokens, i)) return null;
  var j = i;
  if (_at(tokens, j, 'window') || _at(tokens, j, 'document')) {
    if (!_at(tokens, j + 1, '.') || !_at(tokens, j + 2, 'location')) {
      return null;
    }
    j += 2;
  } else if (!_at(tokens, j, 'location')) {
    return null;
  }
  j++;
  if (_at(tokens, j, '.') && _at(tokens, j + 1, 'href')) j += 2;
  if (_at(tokens, j, '=')) {
    final value = j + 1;
    if (value >= tokens.length || tokens[value].kind != _TokenKind.string) {
      return const _RedirectCandidate(null);
    }
    final after = value + 1;
    if (after < tokens.length &&
        !const {';', '}', ')', ','}.contains(tokens[after].value)) {
      return const _RedirectCandidate(null);
    }
    return _RedirectCandidate(tokens[value].value);
  }
  if (_at(tokens, j, '.') &&
      (_at(tokens, j + 1, 'assign') || _at(tokens, j + 1, 'replace')) &&
      _at(tokens, j + 2, '(')) {
    if (j + 3 >= tokens.length ||
        tokens[j + 3].kind != _TokenKind.string ||
        !_at(tokens, j + 4, ')')) {
      return const _RedirectCandidate(null);
    }
    return _RedirectCandidate(tokens[j + 3].value);
  }
  return null;
}

/// Only simple, unescaped web URL literals can be compared. Other targets are
/// unknown; the URL is never fetched, persisted or included in a result.
bool? _crossOriginLiteral(Uri origin, String value) {
  if (value.isEmpty ||
      value.contains('\\') ||
      RegExp(r'[\x00-\x20\x7f]').hasMatch(value)) {
    return null;
  }
  try {
    final literal = Uri.tryParse(value);
    if (literal == null) return null;
    if (!literal.hasScheme && !literal.hasAuthority) return false;
    final target = origin.resolveUri(literal);
    if (!const {'http', 'https'}.contains(target.scheme) ||
        !target.hasAuthority ||
        target.host.isEmpty ||
        target.userInfo.isNotEmpty ||
        target.port < 1 ||
        target.port > 65535 ||
        !RegExp(r'^[a-zA-Z0-9.\-]+$').hasMatch(target.host)) {
      return null;
    }
    return HeaderPolicy.origin(origin) != HeaderPolicy.origin(target);
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}

int? _evaluationCallee(List<_Token> tokens, int i) {
  if (!_independent(tokens, i)) return null;
  var j = i;
  if (_at(tokens, j, 'window') || _at(tokens, j, 'globalThis')) {
    if (!_at(tokens, j + 1, '.')) return null;
    j += 2;
  }
  if ((!_at(tokens, j, 'eval') && !_at(tokens, j, 'Function')) ||
      !_at(tokens, j + 1, '(')) {
    return null;
  }
  return j;
}

bool _decodedEvaluation(List<_Token> tokens, int i) {
  if (!_at(tokens, i + 1, '(')) return false;
  final j = i + 2;
  var decoder = j;
  if ((_at(tokens, decoder, 'window') || _at(tokens, decoder, 'globalThis')) &&
      _at(tokens, decoder + 1, '.')) {
    decoder += 2;
  }
  if ((_at(tokens, decoder, 'atob') ||
          _at(tokens, decoder, 'decodeURIComponent') ||
          _at(tokens, decoder, 'unescape')) &&
      _at(tokens, decoder + 1, '(') &&
      decoder + 2 < tokens.length &&
      tokens[decoder + 2].kind == _TokenKind.string &&
      _at(tokens, decoder + 3, ')') &&
      _at(tokens, decoder + 4, ')')) {
    final literal = tokens[decoder + 2].value;
    if (literal == null || literal.length < 8) return false;
    if (_at(tokens, decoder, 'atob')) {
      return RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(literal);
    }
    return RegExp(r'%(?:[0-9a-fA-F]{2}|u[0-9a-fA-F]{4})').hasMatch(literal);
  }
  if (!_at(tokens, j, 'String') ||
      !_at(tokens, j + 1, '.') ||
      !_at(tokens, j + 2, 'fromCharCode') ||
      !_at(tokens, j + 3, '(')) {
    return false;
  }
  var pos = j + 4, count = 0;
  while (pos < tokens.length && tokens[pos].kind == _TokenKind.number) {
    final number = int.tryParse(tokens[pos].value ?? '');
    if (number == null || number > 65535) return false;
    count++;
    pos++;
    if (!_at(tokens, pos, ',')) break;
    pos++;
  }
  return count >= 4 && _at(tokens, pos, ')') && _at(tokens, pos + 1, ')');
}
