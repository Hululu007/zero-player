import 'dart:convert';

import 'package:crypto/crypto.dart';

// Full normalized search and rule map from bundled Legado record 3685.
const _oldRulesDigest =
    '3d01f75781bcdd0ba04bb86734026ed17a89053d3fe8d456139c4cd294ff569a';

/// Repair only the original QQ Reading web source, preserving user variants.
Map repairQqReadingLegadoSource(Map data, Map legado) {
  final endpoint = Uri.tryParse('${data['url']}');
  final rules = legado['rules'];
  if (data['kind'] != 'text' ||
      data['format'] != 'html' ||
      endpoint?.scheme != 'https' ||
      endpoint?.host != 'book.qq.com' ||
      !const {'', '/'}.contains(endpoint?.path) ||
      endpoint?.hasQuery != false ||
      (legado['library'] ?? '') != '' ||
      legado['search'] is! String ||
      rules is! Map ||
      rules.keys.any((key) => key is! String) ||
      rules.values.any((value) => value is! String)) {
    return legado;
  }
  final keys = rules.keys.cast<String>().toList()..sort();
  final normalized = {
    'search': (legado['search'] as String).trim(),
    'rules': {for (final key in keys) key: (rules[key] as String).trim()},
  };
  if (sha256.convert(utf8.encode(jsonEncode(normalized))).toString() !=
      _oldRulesDigest) {
    return legado;
  }
  return {
    ...legado,
    'search':
        'https://book.qq.com/api/booksearch/query?keyWord={{key}}&pageNo={{page}}&pageSize=10',
    'rules': {
      ...rules,
      'searchList': r'$.data.bookList[*]',
      'searchTitle': r'$.title',
      'searchLink': r'$.bid##(\d+)##https://book.qq.com/book-detail/$1##',
      'searchAuthor': r'$.author',
      'searchDescription': r'$.intro',
      'searchCategory': r'$.category3Name',
      'searchWordCount': r'$.totalWords',
      'searchCover': '',
      'infoAuthor': r'@css:.book-meta .author@text##\s*著$',
      'infoCover': '@css:.book-wrap .book-cover img@src',
    },
  };
}
