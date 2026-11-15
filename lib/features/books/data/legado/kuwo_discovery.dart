import 'dart:convert';

import '../../domain/book.dart';
import '../../domain/kuwo_legacy_source_fix.dart';
import '../../domain/legado_source.dart';

// Observed from the publisher's HTTPS categories endpoint on 2026-11-15.
// A changed or unknown identifier needs a new audit; it is not a URL template.
const _categories = <int, Map<int, String>>{
  1: {
    20001: '玄幻',
    20005: '奇幻',
    20010: '武侠',
    20014: '仙侠',
    20019: '都市',
    20028: '历史',
    20032: '军事',
    20037: '悬疑灵异',
    20042: '科幻',
    20050: '游戏',
    20054: '体育',
    20059: '轻小说',
    20065: '现实',
    20076: '短篇',
    20109: '诸天无限',
  },
  2: {
    30001: '玄幻言情',
    30008: '仙侠奇缘',
    30013: '古代言情',
    30020: '现代言情',
    30031: '浪漫青春',
    30036: '悬疑侦探',
    30042: '科幻空间',
    30050: '游戏竞技',
    30055: '轻小说',
    30083: '短篇',
    30120: '现实生活',
  },
};

bool isKuwoAuditedDiscovery(BookSource source) {
  final legacy = source.legado;
  if (source.kind != BookKind.text ||
      source.endpoint.host != 'appi.kuwo.cn' ||
      legacy == null ||
      legacy.search !=
          'http://appi.kuwo.cn/novels/api/book/search?keyword={{key}}&pi={{page}}&ps=30' ||
      legacy.categories.length != 1) {
    return false;
  }
  final category = legacy.categories.single;
  return category.title == kuwoCategoryMarker &&
      category.address == kuwoCategoryEndpoint &&
      legacy.rules['searchList'] == 'data' &&
      legacy.rules['chapters'] == 'data' &&
      legacy.rules['content'] == 'data.content';
}

List<LegadoCategory> parseKuwoCategories(String text) {
  if (utf8.encode(text).length > 512 * 1024) {
    throw const FormatException('酷我分类响应超过大小限制');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw const FormatException('酷我分类响应不是有效 JSON');
  }
  if (decoded is! Map || decoded['code'] != 200 || decoded['data'] is! List) {
    throw const FormatException('酷我分类响应格式无效');
  }
  final groups = decoded['data'] as List;
  if (groups.isEmpty || groups.length > 3) {
    throw const FormatException('酷我分类组数量无效');
  }
  final seenGroups = <int>{};
  final result = <LegadoCategory>[];
  for (final item in groups) {
    if (item is! Map ||
        item['freetype'] is! int ||
        item['categories'] is! List) {
      throw const FormatException('酷我分类组格式无效');
    }
    final type = item['freetype'] as int;
    final entries = item['categories'] as List;
    if (!const {1, 2, 3}.contains(type) ||
        !seenGroups.add(type) ||
        entries.length > 128) {
      throw const FormatException('酷我分类组未审核或数量无效');
    }
    // The previous source deliberately excluded freetype 3.
    if (type == 3) continue;
    final seen = <int>{};
    for (final row in entries) {
      if (row is! Map ||
          row['category_id'] is! int ||
          row['category_name'] is! String) {
        throw const FormatException('酷我分类字段无效');
      }
      final id = row['category_id'] as int;
      final name = _categories[type]![id];
      if (id <= 0 ||
          name == null ||
          row['category_name'] != name ||
          !seen.add(id)) {
        throw const FormatException('酷我分类已变化或包含未审核的 ID');
      }
      result.add(
        LegadoCategory(
          name,
          'https://appi.kuwo.cn/novels/api/book/category/$type'
          '?category_id=$id&fk=1&sk=1&pi={{page}}&ps=20',
          group: type == 1 ? '男生' : '女生',
        ),
      );
    }
    if (seen.isEmpty) throw const FormatException('酷我分类组为空');
  }
  if (!seenGroups.containsAll({1, 2})) {
    throw const FormatException('酷我分类缺少已审核组');
  }
  return result;
}
