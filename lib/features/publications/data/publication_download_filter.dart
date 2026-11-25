import '../domain/publication.dart';
import 'publication_share_provider.dart';

enum PublicationDownloadFilter {
  all('全部下载途径'),
  direct('直接下载'),
  cloud('全部网盘'),
  baidu('百度网盘', PublicationShareProvider.baidu),
  quark('夸克网盘', PublicationShareProvider.quark),
  uc('UC 网盘', PublicationShareProvider.uc),
  aliyun('阿里云盘', PublicationShareProvider.aliyun),
  lanzou('蓝奏云', PublicationShareProvider.lanzou),
  pan115('115 网盘', PublicationShareProvider.pan115),
  pan123('123 网盘', PublicationShareProvider.pan123),
  xunlei('迅雷云盘', PublicationShareProvider.xunlei),
  tianyi('天翼云盘', PublicationShareProvider.tianyi),
  mobile139('移动云盘', PublicationShareProvider.mobile139),
  guangya('光鸭云盘', PublicationShareProvider.guangya),
  ctfile('城通网盘', PublicationShareProvider.ctfile),
  archive('压缩包（ZIP）');

  const PublicationDownloadFilter(this.label, [this.provider]);
  final String label;
  final PublicationShareProvider? provider;

  bool matches(PublicationEdition edition) {
    if (this == all) return true;
    return edition.candidates.any((item) => _matches(item.link, item.format)) ||
        edition.resources.any(
          (item) => !item.lookupRequired && _matches(item.link, item.format),
        );
  }

  bool _matches(Uri link, PublicationFormat? format) {
    final actual = PublicationShareProvider.of(link);
    return switch (this) {
      direct =>
        actual == PublicationShareProvider.direct &&
            (format != null || PublicationFormat.fromName(link.path) != null),
      cloud => actual != PublicationShareProvider.direct,
      archive =>
        format == PublicationFormat.zip ||
            PublicationFormat.fromName(link.path) == PublicationFormat.zip,
      lanzou =>
        actual == provider || actual == PublicationShareProvider.lanzouPro,
      _ => actual == provider,
    };
  }
}
