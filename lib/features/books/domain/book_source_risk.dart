import '../../supervision/domain/content_classification.dart';
import 'book.dart';

// These hosts have explicitly adult-labelled entries in the bundled Legado
// snapshot. This is source metadata evidence, not a claim about today's site.
const _adultComicHosts = {
  '18mh.cc', // 十八禁漫
  'ikanhm.top', // 爱看韩漫🔞
  'lcmhx.asia', // 乐成漫画🔞
  'roum26.xyz', // 肉漫屋
  'jpxgyw.cc', // 性感美女网
  'nvyoumh01.top', // 嘿咻漫画
};

// HEAD / on 2026-11-15 returned off-site redirects to survey, unrelated, or
// domain-parking hosts. These old catalog addresses need re-review before use.
const _quarantinedComicHosts = {
  'jpxgyw.cc', // 302 http://surveymrs.com
  'yeseimg.com', // 302 http://survey-twist.com
  'kukk.net', // 301 https://esp-framework.com/
  'bdido.com', // 302 HugeDomains parking page
};

bool quarantinedComicSource(BookSource source) =>
    source.kind == BookKind.comic && quarantinedComicHost(source.endpoint.host);

bool quarantinedComicHost(String host) => _quarantinedComicHosts.any(
  (blocked) => host == blocked || host.endsWith('.$blocked'),
);

bool adultComicHost(String host) =>
    _adultComicHosts.any((adult) => host == adult || host.endsWith('.$adult'));

bool adultComicSource(BookSource source) {
  if (source.kind != BookKind.comic) return false;
  final host = source.endpoint.host.toLowerCase();
  return adultComicHost(host) ||
      source.name.contains('🔞') ||
      source.group.contains('🔞') ||
      RegExp(r'肉漫|性感美女|嘿咻').hasMatch('${source.name} ${source.group}') ||
      adultContent(source.name) ||
      adultContent(source.group, category: true);
}
