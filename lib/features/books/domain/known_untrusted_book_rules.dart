import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'book.dart';

// SHA-256 of imported, normalized rule fields. Each exact digest corresponds
// to a reviewed remote-script/attribute-to-eval data flow in the bundled
// snapshot; it is not a claim that the page or app executed malware.
// Evidence and original record indices: legado-eval-normalized-20261115.json
// and legado-response-eval-normalized-20261115.json.
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
    '1204297cf51eb5a75de21610a922ff607413b04a34c08647128b7c2371e28805',
    '1eca465e14604b8f5655de7bc9c7c8b322b1a6838dd0ec22b4b1e49950aa9d3e',
    '2bac062eb7f6343ab24901b04c5c8e1aee2e3873ebf8cbc87d66817526ca3bf8',
    '5cde25452e0d6aed7a9dac09b389e75d70f15827e4f6aa92f7fba6f0dd75b2fb',
    '6468bfafec6bb7c45b7319e3ab8f4700993f67f67d9c85714dbb29149b1dadc3',
    '69b080f669919220f89fbe265315036bb4cd12fa595f054b80e2d82f7572798e',
    'b9e35303050e615f95616771254c681625b09b7cd460f1685c16700f303d322b',
    '10e888c21a834a8d84e6bbc2f70584fa2de4757e3a3cf41cdf6aa4c6aae44308',
    '2d21e8ffa3affa4ecbac39d2b9aeff3db80f6ea09295eaabad8f80777054a858',
    '39ece384090e22e08ca7e9a8cc6f884f6098b5443ad564ca25db9114d9e9fd27',
    '3a3b58b88fe06502bd4dc8af190c56db87b07e56f6a47ad48153d018d9b30f6e',
    '3fdb77bfc0cadddf4caa95585c414c37f0a8eaca58c88fc7d190a816055f9d21',
    '663908ed8d42d5a63236e979e54acaed2ec91c21763a6e357c853a8f2ca90f21',
    '813f933382434733ce626185508128a5135c66da089920d0b2aa66c49e19b4d6',
    'e9216096a8566f11a534622e4204bff5452bf1606ec5fe4d57b2d8c37437d96b',
    '97447b6a69e2a673282c69876b889e0439f10bce8021e3e5a4abf700c202e266',
  },
  'searchList': {
    '31b0a1f9df433c5c8d712873420d0e1f0bad43322f0a114808454b1148edc749',
    '0b5459197ae724493e2d7aabe6f78a5bc9fcd6d6a753bff6b7319d72ae3ded25',
    '78bce775a2f84d9344fbd713d82ac28d698887391a8a12aca7d9c3fd4b9ebc20',
    'c6402c74d4296b887d964ecea9de943def1893636d1b991f60fde75e1bf9802d',
  },
  'infoWordCount': {
    '0be8f8149eae8a31e3b755016766d2100a82a08775cb5aae39895061e7ee6477',
  },
  'searchWordCount': {
    '9b61c335ff5523cfff92e2c8d3b3151eef05c525bbba14cc50b17935cfc46894',
  },
  'chapters': {
    'fa794b49a04305aa105da88c3fe56e2fba89fca96973eb0b06f56f6cd4fabd51',
    'ea79f50590b7d304f031a7fd56601809a6916e1268eb87e82b567d5dce72949f',
    'ec96c23352d6b8cbcdc36d7771e8a6eea047a27e9d5042541a72949d7d543ba8',
  },
  'infoInit': {
    '76449859c45027ce477a8085c4e86f094b4faecd08ce4b1a8ba51f1fb55aaa3d',
  },
  'infoTitle': {
    'fdb69981f90e44c670f6c9fb2480fad82511bc6c3e42f40b96cbe6c00576f7f0',
  },
  'infoAuthor': {
    'b1291a263a5d30aef6f9f9f1e6527035d7f05b49fe6fbeefe7eab42109bbcef0',
  },
  'infoDescription': {
    'b1345ba7c2c5078ae85dd5781cd630baa9f194b5f26e20cc5686323968d9a258',
  },
  'infoCover': {
    '513b681971c60d397666f88835a808774f3fbda438fde96a1663ebbb94ad8f97',
  },
  'infoCategory': {
    '2995f6c27187c854f166f2e58b0071403f2a90a4008cf5a1c462c62f10300555',
  },
  'infoLatest': {
    'add2e23155707a9f54cf32dd9d7add34169e589388dab4ba875ef48c7f9e935e',
  },
  'nextContent': {
    '0424cd5a0af89f66c8263b687c9299c04981b36b176de936e9359b6309ad4685',
    '732047bdd71dcd21df255736e6e1bcf4aa539528000b8e27f2b7544338af98e7',
    'c33300939c5aa06113ec4b6d257ebfdcde3f0bed6f18c8060ecc2aff1be6a70e',
    'f35e0e9d3653b1affe7a9fca632c3fd91175484d36cc90326d3e56568714a8a2',
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
