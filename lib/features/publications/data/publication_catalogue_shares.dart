import '../domain/publication.dart';
import 'publication_share_provider.dart';

final _shareCode = RegExp(r'^[A-Za-z0-9]{2,16}$');
final _codeQuery = RegExp(r'^(pwd|p)=([A-Za-z0-9]{2,16})$');
final _shortShare = RegExp(r'^/s/[A-Za-z0-9_-]{4,80}/?$');
final _ctHost = RegExp(r'^url[0-9]{1,3}\.ctfile\.com$');
final _ctFile = RegExp(r'^/f/[0-9]{1,20}-[0-9]{1,20}(?:-[a-f0-9]{4,16})?$');

bool supportsCatalogueShareDownload(String source, Uri uri) {
  final resource = publishedCatalogueShare(
    source,
    uri.toString(),
    provider: PublicationShareProvider.of(uri),
    baiduDownloads: true,
  );
  return resource?.canListFiles == true && resource!.link == uri;
}

/// Validates a visible share from a built-in catalogue. Only providers with
/// a supported visitor flow can create an in-app acquisition.
PublicationResource? publishedCatalogueShare(
  String source,
  String? raw, {
  required PublicationShareProvider provider,
  String? code,
  PublicationFormat? format,
  bool baiduDownloads = false,
}) {
  if (raw == null || raw.length > 512) return null;
  final reference = Uri.tryParse(raw.trim());
  if (reference == null ||
      reference.scheme != 'https' ||
      reference.port != 443 ||
      reference.userInfo.isNotEmpty ||
      reference.fragment.isNotEmpty) {
    return null;
  }
  final uri = reference.removeFragment();
  final label = switch (provider) {
    PublicationShareProvider.quark
        when uri.host == 'pan.quark.cn' && _shortShare.hasMatch(uri.path) =>
      '夸克网盘',
    PublicationShareProvider.baidu
        when uri.host == 'pan.baidu.com' && _shortShare.hasMatch(uri.path) =>
      '百度网盘',
    PublicationShareProvider.xunlei
        when uri.host == 'pan.xunlei.com' && _shortShare.hasMatch(uri.path) =>
      '迅雷网盘',
    PublicationShareProvider.ctfile
        when _ctHost.hasMatch(uri.host) && _ctFile.hasMatch(uri.path) =>
      '城通网盘',
    _ => null,
  };
  if (label == null) return null;

  final query = _codeQuery.firstMatch(uri.query);
  if (uri.hasQuery &&
      (query == null ||
          (query[1] == 'p' && provider != PublicationShareProvider.ctfile))) {
    return null;
  }
  final embedded = query?[2];
  final supplied = code != null && _shareCode.hasMatch(code) ? code : null;
  if (supplied != null && embedded != null && supplied != embedded) return null;

  final inApp =
      provider == PublicationShareProvider.quark ||
      (provider == PublicationShareProvider.baidu && baiduDownloads);
  return PublicationResource(
    source: source,
    link: inApp ? Uri.https(uri.host, '/s/${uri.pathSegments[1]}') : uri,
    label: label,
    code: supplied ?? embedded,
    canListFiles: inApp,
    format: format,
  );
}
