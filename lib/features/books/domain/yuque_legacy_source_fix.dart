import 'dart:convert';

import 'package:crypto/crypto.dart';

const yuqueBookListUrl = 'https://www.yuque.com/yuqueyonghun8txcr/psb8yc';
const yuqueBookId = 32273288;

// The complete normalized search, comment and rule map from bundled record
// 4083. Requiring the entire map leaves custom and newer versions untouched.
const _oldRuleDigest =
    '2f07c51c496054e0bf6fc5ab7e36176d11d079bf176f757eb0f06161acd7dcf9';

const yuqueSafeRules = <String, String>{
  'searchList': r'$.book',
  'searchTitle': 'name',
  'searchLink': 'url',
  'searchAuthor': 'author',
  'searchDescription': 'description',
  'exploreList': r'$.book',
  'exploreTitle': 'name',
  'exploreLink': 'url',
  'exploreAuthor': 'author',
  'exploreDescription': 'description',
  'infoInit': r'$.book',
  'infoTitle': 'name',
  'infoAuthor': 'author',
  'infoDescription': 'description',
  'chapters': r'$.book.docs',
  'chapterTitle': 'title',
  'chapterUrl': r'https://www.yuque.com/api/docs/{{$.slug}}?book_id=32273288',
  'content': r'$.data.content',
};

/// Repairs only the observed export, never arbitrary sources using eval.
Map repairYuqueLegadoSource(Map data, Map legado) {
  final categories = legado['explore'];
  if (data['kind'] != 'text' ||
      data['format'] != 'html' ||
      data['url'] != yuqueBookListUrl ||
      (legado['library'] ?? '') != '' ||
      (legado['bookUrlPattern'] ?? '') != '' ||
      categories is! List ||
      categories.length != 1 ||
      categories.single is! Map ||
      (categories.single as Map)['title'] != '📜哈哈哈的书单' ||
      (categories.single as Map)['url'] != yuqueBookListUrl ||
      ((categories.single as Map)['group'] ?? '') != '' ||
      legado['search'] is! String ||
      legado['comment'] is! String ||
      legado['rules'] is! Map) {
    return legado;
  }
  final original = legado['rules'] as Map;
  if (original.keys.any((key) => key is! String) ||
      original.values.any((value) => value is! String)) {
    return legado;
  }
  final keys = original.keys.cast<String>().toList()..sort();
  final normalized = {
    'search': (legado['search'] as String).trim(),
    'comment': (legado['comment'] as String).trim(),
    'rules': {for (final key in keys) key: (original[key] as String).trim()},
  };
  final digest = sha256.convert(utf8.encode(jsonEncode(normalized))).toString();
  if (digest != _oldRuleDigest) return legado;
  return {
    ...legado,
    'search': yuqueBookListUrl,
    'comment': '',
    'rules': yuqueSafeRules,
  };
}
