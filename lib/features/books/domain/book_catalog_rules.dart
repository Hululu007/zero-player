/// Field paths over a public JSON response.
final class BookCatalogRules {
  BookCatalogRules.fromJson(Map data)
    : fields = Map.unmodifiable({
        for (final key in const [
          'list',
          'id',
          'url',
          'title',
          'author',
          'description',
          'cover',
          'next',
        ])
          if (data[key] != null) key: _path(data[key]),
      }) {
    if (!fields.containsKey('list') ||
        !fields.containsKey('title') ||
        (!fields.containsKey('id') && !fields.containsKey('url'))) {
      throw const FormatException('JSON 书目规则缺少列表、书名或作品地址');
    }
  }

  final Map<String, String> fields;

  static String _path(Object? value) {
    if (value == r'$') return r'$';
    if (value is! String ||
        value.length > 120 ||
        !RegExp(r'^[a-zA-Z0-9_]+(?:\.[a-zA-Z0-9_]+){0,5}$').hasMatch(value)) {
      throw const FormatException('JSON 书目规则必须是有界字段路径');
    }
    return value;
  }

  Object? read(Object? document, String field) {
    final path = fields[field];
    if (path == null) return null;
    if (path == r'$') return document;
    Object? value = document;
    for (final key in path.split('.')) {
      if (value is! Map) return null;
      value = value[key];
    }
    return value;
  }
}
