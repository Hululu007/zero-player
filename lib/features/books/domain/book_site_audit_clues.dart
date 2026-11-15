import 'book.dart';

// An advisory observation from one bounded root-page scan, not a malware
// verdict. See docs/implementation/legado-amsi-summary-20261115.json.
const _historicalAmsiHosts = {
  'www.4qo.net',
  'api.jiaston.com',
  'bbs.fanfanu.com',
  'cl.2790z.xyz',
  'get.xiashuzhan.com',
  'kuronavi.blog',
  'lwkk.xyz',
  'm.69shu.la',
  'm.bz001.org',
  'm.nshkedu.com',
  's.fjwhcbsh.com',
  'shuhuang.la',
  'wap.18biquge.com',
  'www.230book.net',
  'www.ffxs.info',
  'www.jpxgyw.cc',
  'www.lengmen.org',
};

bool bookSourceHasHistoricalAmsiClue(BookSource source) =>
    _historicalAmsiHosts.contains(source.endpoint.host.toLowerCase());
