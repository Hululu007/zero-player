import 'dart:convert';

import 'package:crypto/crypto.dart';

// Full normalized search and rule map from bundled Legado record 4149.
const _oldRulesDigest =
    '528248efb4b90d7d4deee6af26132b789ea663f7e9de8d8e0b89bf6ac4d92a00';

/// Fix the observed search-result markup without changing custom rule sets.
Map repairJingzhiLegadoSource(Map data, Map legado) {
  final endpoint = Uri.tryParse('${data['url']}');
  final rules = legado['rules'];
  if (data['kind'] != 'text' ||
      data['format'] != 'html' ||
      endpoint?.scheme != 'https' ||
      endpoint?.host != 'www.jingzhi5.com' ||
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
    'rules': {
      ...rules,
      'searchAuthor': 'class.search-info@tag.a.1@text',
      'searchDescription': 'class.search-sumary@text',
    },
  };
}
