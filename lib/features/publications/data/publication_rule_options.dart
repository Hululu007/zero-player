import 'package:html/dom.dart' as dom;

final class PublicationRuleOptions {
  const PublicationRuleOptions(
    this.list,
    this.next,
    this.detail,
    this.upgradeSameHostHttp,
  );
  final String? list, next;
  final Map<String, String> detail;
  final bool upgradeSameHostHttp;

  factory PublicationRuleOptions.parse(Map spec, {required bool html}) {
    final list = spec['listEndpoint'];
    final next = spec['next'];
    final detail = spec['detail'] ?? const {};
    final upgrade = spec['upgradeSameHostHttp'];
    if ((upgrade != null && upgrade is! bool) ||
        (list != null &&
            (list is! String || list.isEmpty || list.length > 2048)) ||
        (next != null &&
            (next is! String || !publicationRuleSelector(next, html: html))) ||
        detail is! Map ||
        detail.length > 6 ||
        detail.entries.any(
          (entry) =>
              !const {
                'epub',
                'pdf',
                'zip',
                'epubCode',
                'pdfCode',
                'zipCode',
              }.contains(entry.key) ||
              entry.value is! String ||
              !publicationRuleSelector(entry.value as String, html: html),
        ) ||
        (detail.isNotEmpty &&
            (spec['field'] is! Map ||
                (spec['field'] as Map)['page'] == null))) {
      throw const FormatException('发现地址、下一页或详情字段无效');
    }
    return PublicationRuleOptions(
      list as String?,
      next as String?,
      Map<String, String>.from(detail),
      upgrade == true,
    );
  }

  Map<String, Object?> toSpec() => {
    'listEndpoint': ?list,
    'next': ?next,
    if (upgradeSameHostHttp) 'upgradeSameHostHttp': true,
    if (detail.isNotEmpty) 'detail': detail,
  };
}

bool publicationRuleSelector(
  String value, {
  required bool html,
  bool rows = false,
}) {
  if (value.isEmpty || value.length > 160) return false;
  if (!html) {
    return RegExp(r'^[a-zA-Z_][\w-]*$').hasMatch(value) ||
        RegExp(
          r'^/(?:[^/\x00-\x20~]|~[01])+(?:/(?:[^/\x00-\x20~]|~[01])+){0,9}$',
        ).hasMatch(value);
  }
  final query = value.split('@');
  if (query.length > 2 ||
      (query.length == 2 &&
          (rows ||
              !const {
                'href',
                'data-url',
                'data-isbn',
                'content',
                'rel',
              }.contains(query[1])))) {
    return false;
  }
  // Bounded simple selectors, with attribute tests for annotated catalogue HTML.
  const simple =
      r'''(?:[a-zA-Z][\w-]*)?(?:[.#][\w-]+)?(?:\[[a-z][\w-]*(?:[~|^$*]?=(?:"[a-zA-Z0-9_.:/+\- ]{1,56}"|'[a-zA-Z0-9_.:/+\- ]{1,56}'|[a-zA-Z0-9_.:+\-]+))?\]){0,2}''';
  return query.first.trim().isNotEmpty &&
      RegExp('^$simple(?: +$simple){0,3}\$').hasMatch(query.first);
}

Object? publicationJsonField(Object? value, String path) {
  if (!path.startsWith('/')) return value is Map ? value[path] : null;
  for (final part in path.substring(1).split('/')) {
    final token = part.replaceAll('~1', '/').replaceAll('~0', '~');
    if (value is Map) {
      value = value[token];
    } else if (value is List) {
      final index = int.tryParse(token);
      value = index != null && index >= 0 && index < value.length
          ? value[index]
          : null;
    } else {
      return null;
    }
  }
  return value;
}

Object? publicationRuleValue(Object? node, String path) {
  if (node is dom.Document || node is dom.Element) {
    final selector = path.split('@');
    final element = node is dom.Document
        ? node.querySelector(selector.first)
        : (node as dom.Element).querySelector(selector.first);
    return selector.length == 2
        ? element?.attributes[selector.last]
        : element?.text;
  }
  return publicationJsonField(node, path);
}
