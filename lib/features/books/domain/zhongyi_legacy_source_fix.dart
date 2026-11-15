import 'dart:convert';

import 'package:crypto/crypto.dart';

// Full normalized search and rule map from bundled Legado record 1431.
const _oldRulesDigest =
    '6f0f88fe6e33020ec94329fde32dabc74a5b37d6deec7c45c3c0af71ba5d7177';

/// The site's current search form uses a query parameter rather than a path.
Map repairZhongyiLegadoSource(Map data, Map legado) {
  final endpoint = Uri.tryParse('${data['url']}');
  final rules = legado['rules'];
  if (data['kind'] != 'text' ||
      data['format'] != 'html' ||
      endpoint?.scheme != 'https' ||
      endpoint?.host != 'www.zhongyi6.com' ||
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
  return {...legado, 'search': '/books/search?keyword={{key}}&page={{page}}'};
}
