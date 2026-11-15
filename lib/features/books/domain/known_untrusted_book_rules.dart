import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'book.dart';

// SHA-256 of imported, normalized rule fields. Each exact digest corresponds
// to a reviewed remote-script/attribute-to-eval data flow in the bundled
// snapshot; it is not a claim that the page or app executed malware.
// Evidence and original record indices: legado-eval-normalized-20261115.json.
const _ruleDigests = <String, Set<String>>{
  'content': {
    '0026f7be18a5907db1fbd5f776904bc511370a6d39875ac3b10997041eb450c0',
    '25eb6b9292645ef1e452e118dbb69301fa72520f22a730e645e681ab9bac8992',
    '31e2c5cbda1e704bf7790a78da4e32b51f0ead228a857182a71fb8424857a4dc',
    '4c8b690d38383c5e9b4d5fbca03a856820d566a373b1f9aada4a399a404f2509',
    '5008e24edf3ecf547dc0f062fb9090cfb1541321fc7806c630a213b52216ef54',
    '562be97529d59dbc72508a94e0d764e5ab3698af648f390b3cac69e11bb1b8ce',
    '624834a5f7c05abf712f2066dd8add81c3de77f0e3b1d5921e33d8626855b037',
    '64bf3a9d333a6cebe5a5fcb04d2887fc463ed9fb04a1fb6db996b10b30893b0a',
    '74e6b3458909b604a15df5c482c949e13f601809219d9f48ef6c387069db6d14',
  },
  'searchList': {
    '31b0a1f9df433c5c8d712873420d0e1f0bad43322f0a114808454b1148edc749',
  },
  'infoWordCount': {
    '0be8f8149eae8a31e3b755016766d2100a82a08775cb5aae39895061e7ee6477',
  },
  'searchWordCount': {
    '9b61c335ff5523cfff92e2c8d3b3151eef05c525bbba14cc50b17935cfc46894',
  },
};

const _commentDigests = {
  'b0cececbfa92db3895a02a55c90e112e68f4b74abcecc9ce8b0730d6cfebbd79',
  '315056a018d4e9853964dd859a9bf53c407d72c6dc09e7bd7f1d631ac101262c',
  '1cb0c7ef4a06a125695f3c29c8aebf901014fd61a0b1c3f5995c0fb8e01ded77',
};

// Metadata alone is not executable. At least one reviewed caller must also
// match the exact normalized search/content field that evaluates the comment.
const _commentCallers = {
  'searchList':
      '5f1f8ac565e82d32973b3b3e76ad1a586ab009767d35b0059ad85e7a15df0127',
  'content': '3cdc030a37e1bdca4e8b748ae4d8f5be29f182ce2575275787f6a8adcb5bbb13',
};

final _matches = Expando<bool>();

String _digest(String value) => sha256.convert(utf8.encode(value)).toString();

bool knownUntrustedBookRule(BookSource source) {
  final saved = _matches[source];
  if (saved != null) return saved;
  final legacy = source.legado;
  if (legacy == null) return _matches[source] = false;
  for (final entry in _ruleDigests.entries) {
    final rule = legacy.rules[entry.key] ?? '';
    if (rule.contains('eval') && entry.value.contains(_digest(rule))) {
      return _matches[source] = true;
    }
  }
  if (legacy.comment.contains('eval') &&
      _commentDigests.contains(_digest(legacy.comment))) {
    for (final caller in _commentCallers.entries) {
      final rule = legacy.rules[caller.key] ?? '';
      if (rule.contains('eval') && _digest(rule) == caller.value) {
        return _matches[source] = true;
      }
    }
  }
  return _matches[source] = false;
}
