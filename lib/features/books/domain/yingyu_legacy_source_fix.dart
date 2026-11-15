import 'dart:convert';

import 'package:crypto/crypto.dart';

// Full normalized search and rule map from bundled Legado record 4036.
const _oldRulesDigest =
    '1ab72ad5b05b68d440398279a26edad78cdedbfb2f0fab51ea8c1778270d058c';

/// Repair only the observed source's static search, detail and reading rules.
Map repairYingyuLegadoSource(Map data, Map legado) {
  final endpoint = Uri.tryParse('${data['url']}');
  final rules = legado['rules'];
  if (data['kind'] != 'text' ||
      data['format'] != 'html' ||
      endpoint?.scheme != 'https' ||
      endpoint?.host != 'www.yingyuxiaoshuo.com' ||
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
      'searchTitle': '@css:.grow h2>a@text',
      'searchAuthor': '@css:.grow>div.1@text',
      'searchDescription': '@css:.grow>div.2@text',
      'searchCategory': '@css:.grow>div.3@span.0@text',
      'infoAuthor': r'@css:.listshadow1 .text-danger.1@text##^作者[:：]\s*',
      'infoCategory': '@css:.listshadow1 .text-danger[2:4]@text',
      'chapterTitle': 'text',
      'chapterUrl': 'href',
      'content': '@css:.text-content1 .c-en@text||@css:.text-content1@text',
    },
  };
}
