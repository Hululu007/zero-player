import 'publication_http.dart';

bool isLanzouShare(Uri uri) =>
    RegExp(r'(^|\.)lanzou[a-z]?\.com$').hasMatch(uri.host);

enum PublicationShareProvider {
  direct,
  lanzou,
  lanzouPro,
  quark,
  uc,
  guangya,
  xunlei,
  mobile139,
  pan123,
  baidu,
  aliyun,
  tianyi,
  pan115,
  ctfile;

  bool get listsFiles => this == quark || this == uc || this == lanzou;

  static PublicationShareProvider of(Uri link) {
    if (isLanzouShare(link)) return lanzou;
    for (final (domain, provider) in const [
      ('ilanzou.com', lanzouPro),
      ('quark.cn', quark),
      ('uc.cn', uc),
      ('guangyapan.com', guangya),
      ('xunlei.com', xunlei),
      ('yun.139.com', mobile139),
      ('123pan.com', pan123),
      ('123684.com', pan123),
      ('123865.com', pan123),
      ('pan.baidu.com', baidu),
      ('aliyundrive.com', aliyun),
      ('alipan.com', aliyun),
      ('cloud.189.cn', tianyi),
      ('115.com', pan115),
      ('115cdn.com', pan115),
      ('ctfile.com', ctfile),
      ('ctfile.net', ctfile),
    ]) {
      if (hostIn(link, domain)) return provider;
    }
    return direct;
  }
}
