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
