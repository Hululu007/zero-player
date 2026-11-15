/// Repairs a specific outdated bundled Dushu template, including saved copies.
/// Search and chapter rules must match the observed template; other sources and
/// user-modified rules are left untouched.
Map repairDushuLegadoSource(Map data, Map legado) {
  final endpoint = Uri.tryParse('${data['url']}');
  final rules = legado['rules'];
  const previousSearch =
      'https://www.dushu.com/search.aspx?wd={{key}}&f=0&r=3&t=0&p={{page}}';
  if (data['kind'] != 'text' ||
      endpoint?.scheme != 'https' ||
      endpoint?.host != 'www.dushu.com' ||
      legado['search'] != previousSearch ||
      rules is! Map ||
      rules['content'] != 'class.content_txt@html' ||
      !const {
        'class.booklist-table@td@a',
        'class.booklist-table@tag.td',
      }.contains(rules['chapters'])) {
    return legado;
  }
  return {
    ...legado,
    'search': previousSearch.replaceFirst('?wd=', '?rd='),
    'rules': {
      ...rules,
      if (rules['searchAuthor'] == 'tag.p.0@tag.em@text')
        'searchAuthor': 'tag.p.0@text',
      if (const {
        'class.book-details-left@tag.a.0@text',
        'class.book-details@tag.tr.0@tag.a@text',
      }.contains(rules['infoAuthor']))
        'infoAuthor': 'class.book-details-left@tag.tr.0@tag.td.1@text',
    },
  };
}
