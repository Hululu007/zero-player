import 'dart:convert';

import '../../domain/book.dart';
import '../../domain/yuque_legacy_source_fix.dart';

final _appDataPrefix = RegExp(
  r'window\.appData\s*=\s*JSON\.parse\(\s*decodeURIComponent\(\s*',
);
final _slug = RegExp(r'^[a-z0-9]{1,64}$');

bool isRepairedYuqueBookList(BookSource source) {
  final legacy = source.legado;
  return source.kind == BookKind.text &&
      source.format == BookFormat.html &&
      source.endpoint.toString() == yuqueBookListUrl &&
      legacy != null &&
      legacy.search == yuqueBookListUrl &&
      legacy.comment.isEmpty &&
      legacy.library.isEmpty &&
      legacy.rules.length == yuqueSafeRules.length &&
      yuqueSafeRules.entries.every(
        (entry) => legacy.rules[entry.key] == entry.value,
      );
}

/// Read one JSON string literal as data, never as JavaScript. The projected
/// object deliberately drops private documents and unrelated page fields.
String normalizeYuqueBookList(String html) {
  if (utf8.encode(html).length > 2 * 1024 * 1024) {
    throw const FormatException('语雀书单页面超过大小限制');
  }
  final matches = _appDataPrefix.allMatches(html).take(2).toList();
  if (matches.length != 1) throw const FormatException('语雀书单数据入口不唯一');
  final start = matches.single.end;
  if (start >= html.length || html.codeUnitAt(start) != 34) {
    throw const FormatException('语雀书单数据不是 JSON 字符串');
  }
  var end = start + 1;
  var escaped = false;
  for (; end < html.length; end++) {
    final code = html.codeUnitAt(end);
    if (escaped) {
      escaped = false;
    } else if (code == 92) {
      escaped = true;
    } else if (code == 34) {
      break;
    }
  }
  if (end >= html.length ||
      !RegExp(r'^\s*\)\s*\)').hasMatch(html.substring(end + 1))) {
    throw const FormatException('语雀书单数据未闭合');
  }
  final Object? decoded;
  try {
    final encoded = jsonDecode(html.substring(start, end + 1));
    if (encoded is! String) throw const FormatException();
    decoded = jsonDecode(Uri.decodeComponent(encoded));
  } on FormatException {
    throw const FormatException('语雀书单数据不是有效 JSON');
  } on ArgumentError {
    throw const FormatException('语雀书单数据编码无效');
  }
  if (decoded is! Map || decoded['book'] is! Map) {
    throw const FormatException('语雀书单数据格式无效');
  }
  final book = decoded['book'] as Map;
  final docs = book['docs'];
  final contributors = book['contributors'];
  if (book['id'] is! int ||
      book['id'] != yuqueBookId ||
      book['name'] is! String ||
      bookLabel(book['name']).isEmpty ||
      book['description'] is! String ||
      docs is! List ||
      docs.isEmpty ||
      docs.length > 512 ||
      contributors is! List ||
      contributors.length > 100) {
    throw const FormatException('语雀书单身份或字段无效');
  }
  final names = <String>[];
  for (final person in contributors) {
    if (person is! Map || person['name'] is! String) {
      throw const FormatException('语雀书单作者字段无效');
    }
    final name = bookLabel(person['name']);
    if (name.isNotEmpty) names.add(name);
  }
  final seen = <String>{};
  final publicDocs = <Map<String, String>>[];
  for (final row in docs) {
    if (row is! Map ||
        row['public'] is! int ||
        row['status'] is! int ||
        row['slug'] is! String ||
        row['title'] is! String) {
      throw const FormatException('语雀书单目录字段无效');
    }
    final slug = row['slug'] as String;
    if (!_slug.hasMatch(slug) || !seen.add(slug)) {
      throw const FormatException('语雀书单目录地址无效');
    }
    if (row['public'] != 1 || row['status'] != 1) continue;
    final title = bookLabel(row['title']);
    if (title.isEmpty) throw const FormatException('语雀书单目录标题为空');
    publicDocs.add({'title': title, 'slug': slug});
  }
  if (publicDocs.isEmpty) throw const FormatException('语雀书单没有公开目录');
  return jsonEncode({
    'book': {
      'name': bookLabel(book['name']),
      'author': names.join('，'),
      'description': bookLabel(book['description'], 4000),
      'url': yuqueBookListUrl,
      'docs': publicDocs,
    },
  });
}
