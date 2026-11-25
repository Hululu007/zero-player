const greenTeaPressRule = <String, Object?>{
  'version': 2,
  'kind': 'htmlSearch',
  'name': 'Green Tea Press · Think Python 2e',
  'endpoint': 'https://greenteapress.com/wp/think-python-2e/',
  'rows': 'html',
  'upgradeSameHostHttp': true,
  'field': {'title': 'title', 'pdf': r'a[href$="thinkpython2.pdf"]@href'},
  'license': 'CC BY-NC，Green Tea Press 原版',
};

const openLogicProjectRule = <String, Object?>{
  'version': 2,
  'kind': 'htmlSearch',
  'name': 'Open Logic Project · 开放逻辑教材',
  'endpoint': 'https://builds.openlogicproject.org/',
  'hosts': [
    'slc.openlogicproject.org',
    'ic.openlogicproject.org',
    'bd.openlogicproject.org',
    'st.openlogicproject.org',
  ],
  'rows': 'h3',
  'field': {'title': 'a', 'page': 'a@href'},
  'detail': {'pdf': r'a[href$="-screen.pdf"]@href'},
  'next': r'a[rel="next"]@href',
  'license': 'CC BY 4.0 · Open Logic Project 官方原版',
};

const mobiPublicationRule = <String, Object?>{
  'version': 2,
  'kind': 'htmlSearch',
  'name': 'Mobi 图书 · 公开书目',
  'endpoint': 'https://www.mobitushu.cn/search.php',
  'listEndpoint': '/wenxue/',
  'rows': 'article.post',
  'field': {'title': 'header h2 a', 'page': 'header h2 a@href'},
  'license': '仅书目与原站出处',
};

const publicationRuleExamples = [
  greenTeaPressRule,
  openLogicProjectRule,
  mobiPublicationRule,
];
