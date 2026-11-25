import '../domain/cloud_share_address.dart';
import 'publication_http.dart';

bool isLanzouShare(Uri uri) =>
    RegExp(r'(^|\.)lanzou[a-z]?\.com$').hasMatch(uri.host);

final _baiduSharePath = RegExp(r'^/s/[a-zA-Z0-9_-]{1,128}/?$');
final _baiduShareCode = RegExp(r'^[a-zA-Z0-9]{4}$');
final _baiduAccessToken = RegExp(r'^[a-zA-Z0-9._~-]{16,512}$');

bool validBaiduPublicationToken(String token) =>
    _baiduAccessToken.hasMatch(token);

bool isBaiduPublicationShare(Uri uri) =>
    ((uri.scheme == 'https' && uri.port == 443) ||
        (uri.scheme == 'http' && uri.port == 80)) &&
    uri.host == 'pan.baidu.com' &&
    uri.userInfo.isEmpty &&
    _baiduSharePath.hasMatch(uri.path);

Uri baiduPublicationSharePage(Uri uri, String? code) {
  if (!isBaiduPublicationShare(uri)) {
    throw const FormatException('百度网盘分享链接无效');
  }
  if (code != null && !_baiduShareCode.hasMatch(code)) {
    throw const FormatException('百度网盘提取码应为四位字母或数字');
  }
  return Uri.https(uri.host, uri.path, code == null ? null : {'pwd': code});
}

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
  ctfile,
  wo,
  weiyun,
  onedrive,
  googleDrive;

  bool get listsFiles =>
      this == quark ||
      this == uc ||
      this == lanzou ||
      this == baidu ||
      this == tianyi ||
      this == mobile139 ||
      this == pan123;

  bool get previewsFiles => listsFiles || this == aliyun;

  static PublicationShareProvider of(Uri link) {
    if (isLanzouShare(link)) return lanzou;
    if (mobileShareHost(link)) return mobile139;
    if (tianyiShareHost(link)) return tianyi;
    for (final (domain, provider) in const [
      ('ilanzou.com', lanzouPro),
      ('quark.cn', quark),
      ('uc.cn', uc),
      ('guangyapan.com', guangya),
      ('xunlei.com', xunlei),
      ('123pan.cn', pan123),
      ('123pan.com', pan123),
      ('123684.com', pan123),
      ('123865.com', pan123),
      ('pan.baidu.com', baidu),
      ('aliyundrive.com', aliyun),
      ('alipan.com', aliyun),
      ('1drv.ms', onedrive),
      ('onedrive.live.com', onedrive),
      ('drive.google.com', googleDrive),
      ('pan.wo.cn', wo),
      ('weiyun.com', weiyun),
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
