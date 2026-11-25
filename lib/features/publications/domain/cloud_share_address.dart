final _shareId = RegExp(r'^[A-Za-z0-9_-]{4,128}$');
final _mobileRoute = RegExp(r'^/w/[ift]/([A-Za-z0-9_-]{4,128})/?$');
final _tianyiRoute = RegExp(r'^/t/([A-Za-z0-9_-]{4,128})/?$');

bool _hostIn(Uri uri, String domain) =>
    uri.host == domain || uri.host.endsWith('.$domain');

bool mobileShareHost(Uri uri) =>
    _hostIn(uri, 'yun.139.com') ||
    uri.host == 'caiyun.139.com' ||
    uri.host == 'caiyun.feixin.10086.cn';

bool tianyiShareHost(Uri uri) =>
    _hostIn(uri, 'cloud.189.cn') || uri.host == 'cloud.dlife.cn';

bool _webShare(Uri uri) =>
    uri.userInfo.isEmpty &&
    ((uri.scheme == 'https' && uri.port == 443) ||
        (uri.scheme == 'http' && uri.port == 80));

String? mobileShareId(Uri uri) {
  if (!mobileShareHost(uri) || !_webShare(uri)) return null;
  return _mobileRoute.firstMatch(uri.fragment.split('?').first)?[1] ??
      _mobileRoute.firstMatch(uri.path)?[1];
}

String? tianyiShareId(Uri uri) {
  if (!tianyiShareHost(uri) || !_webShare(uri)) return null;
  final code =
      _tianyiRoute.firstMatch(uri.path)?[1] ??
      (uri.path == '/web/share' ? uri.queryParameters['code'] : null) ??
      (uri.host == 'h5.cloud.189.cn' && uri.path == '/share.html'
          ? (_tianyiRoute.firstMatch(uri.fragment.split('?').first)?[1])
          : null);
  return code != null && _shareId.hasMatch(code) ? code : null;
}

Uri? canonicalCloudShare(Uri uri) {
  if (mobileShareId(uri) != null) {
    final route = _mobileRoute.hasMatch(uri.path)
        ? uri.path
        : uri.fragment.split('?').first;
    return Uri.https(
      'yun.139.com',
      '/shareweb/',
    ).replace(fragment: route.replaceFirst(RegExp(r'/$'), ''));
  }
  if (tianyiShareId(uri) case final String id) {
    return Uri.https('cloud.189.cn', '/t/$id');
  }
  return null;
}

List<String> cloudShareCodes(Uri uri, String key) {
  if (key == 'code' && tianyiShareId(uri) != null && uri.path == '/web/share') {
    return const [];
  }
  final queryStart = uri.fragment.indexOf('?');
  final fragmentQuery = mobileShareId(uri) != null && queryStart >= 0
      ? Uri.tryParse('?${uri.fragment.substring(queryStart + 1)}')
      : null;
  return [
    ...?uri.queryParametersAll[key],
    ...?fragmentQuery?.queryParametersAll[key],
  ];
}
