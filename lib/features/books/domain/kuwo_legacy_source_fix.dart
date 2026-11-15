import 'dart:convert';

import 'package:crypto/crypto.dart';

const kuwoCategoryEndpoint = 'https://appi.kuwo.cn/novels/api/book/categories';
const kuwoCategoryMarker = '酷我小说分类';
const _kuwoSearch =
    'http://appi.kuwo.cn/novels/api/book/search?keyword={{key}}&pi={{page}}&ps=30';
const _kuwoCategoryScripts = {
  '23c38894118027d35c4807eaedef6657c87afa1aae48c2bc4920ad687f67cde4',
  '7c54f471b2d055cf6b778d8fbf4544c6a0ec657fee93acc52bd82728d6a861f9',
};

/// Replace only the two audited bundled discovery scripts. They interpolate
/// a network value into eval and use cache APIs this app does not support.
Map repairKuwoLegadoSource(Map data, Map legado) {
  final endpoint = Uri.tryParse('${data['url']}');
  final rules = legado['rules'];
  final categories = legado['explore'];
  if (data['kind'] != 'text' ||
      endpoint?.scheme != 'https' ||
      endpoint?.host != 'appi.kuwo.cn' ||
      !const {'', '/', '/novels/api/book/'}.contains(endpoint?.path) ||
      legado['search'] != _kuwoSearch ||
      rules is! Map ||
      rules['searchList'] != 'data' ||
      rules['searchLink'] !=
          r'http://appi.kuwo.cn/novels/api/book/{{$.book_id}}' ||
      rules['chapters'] != 'data' ||
      rules['content'] != 'data.content' ||
      categories is! List ||
      categories.length != 1 ||
      categories.single is! String) {
    return legado;
  }
  final script = (categories.single as String).trim();
  if (!_kuwoCategoryScripts.contains(
    sha256.convert(utf8.encode(script)).toString(),
  )) {
    return legado;
  }
  const oldChapter = "{{baseUrl.replace('?paging=0','')}}/{{\$.chapter_id}}";
  return {
    ...legado,
    'explore': [
      {'title': kuwoCategoryMarker, 'url': kuwoCategoryEndpoint},
    ],
    'rules': {
      ...rules,
      if (rules['chapterUrl'] == oldChapter)
        'chapterUrl':
            r'https://appi.kuwo.cn/novels/api/book/{{$.book_id}}/chapters/{{$.chapter_id}}',
    },
  };
}
