import 'dart:convert';

import 'package:crypto/crypto.dart';

// Full normalized search and rule map from bundled Legado record 1056.
const _oldRulesDigest =
    '1b0f9717302fa18ba865a8dd9ebfa2e2924026cc35b3d2290d2e30c13c059f80';

/// Search rows are already links; the reader navigation leads to another
/// chapter, while the current chapter's sections are in the same HTML page.
Map repairShubangLegadoSource(Map data, Map legado) {
  final endpoint = Uri.tryParse('${data['url']}');
  final rules = legado['rules'];
  if (data['kind'] != 'text' ||
      data['format'] != 'html' ||
      endpoint?.scheme != 'https' ||
      endpoint?.host != 'www.shubang.net' ||
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
  final fixedRules = Map.of(rules)
    ..['searchLink'] = 'href'
    ..remove('nextContent');
  return {...legado, 'rules': fixedRules};
}
