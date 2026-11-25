import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'cloud_share_listing.dart';
import 'cloud_shared_file.dart';
import 'publication_http.dart';
import 'publication_share_provider.dart';

final class AliyunSharePreview {
  AliyunSharePreview(this._http);

  final PublicationHttp _http;
  static final _home = Uri.https('www.alipan.com', '/');
  static const _host = 'api.alipan.com';
  static const _pageSize = 50;
  static final _path = RegExp(
    r'^/s/([A-Za-z0-9_-]{4,128})(?:/folder/([A-Za-z0-9_-]{1,128}))?/?$',
  );

  Future<CloudShareListing> inspectTree(
    Uri link,
    String? code,
    CancellationToken token, {
    bool preview = false,
  }) async {
    final route = _path.firstMatch(link.path);
    if (route == null ||
        PublicationShareProvider.of(link) != PublicationShareProvider.aliyun ||
        link.scheme != 'https' ||
        link.port != 443 ||
        link.userInfo.isNotEmpty) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    if (!validCloudShareCode(code)) {
      throw const PublicationFailure(PublicationProblem.shareCode);
    }
    final id = route[1]!;
    final share = await _request('/v2/share_link/get_share_token', {
      'share_id': id,
      'share_pwd': code ?? '',
    }, token);
    final access = share['share_token'];
    if (access is! String ||
        !RegExp(r'^[A-Za-z0-9._~+/=-]{16,4096}$').hasMatch(access)) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    final markers = <(String, int), String>{};
    return listCloudShare(route[2] ?? 'root', token, (folder, page) async {
      final result = await _request(
        '/adrive/v2/file/list_by_share',
        {
          'share_id': id,
          'parent_file_id': folder,
          'limit': _pageSize,
          if (markers[(folder, page)] case final String marker)
            'marker': marker,
        },
        token,
        shareToken: access,
      );
      return _parsePage(result, (marker) {
        if (marker == markers[(folder, page)]) return false;
        markers[(folder, page + 1)] = marker;
        return true;
      });
    }, preview: preview);
  }

  CloudSharePage _parsePage(Map result, bool Function(String) next) {
    final rows = result['items'];
    if (rows is! List || rows.length > _pageSize) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    final files = <CloudShareNode>[];
    final folders = <CloudShareNode>[];
    for (final row in rows) {
      if (row is! Map) continue;
      final fileId = cloudNodeId(row['file_id']);
      final name = cloudNodeName(row['name']);
      if (fileId == null || name.isEmpty) continue;
      switch (row['type']) {
        case 'folder':
          folders.add((id: fileId, name: name, bytes: null));
        case 'file':
          files.add((
            id: fileId,
            name: name,
            bytes: cloudNodeSize(row['size']),
          ));
      }
    }
    final marker = result['next_marker'];
    final more = marker is String && marker.isNotEmpty;
    if (more && (marker.length > 2048 || !next(marker))) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    return (files: files, directories: folders, more: more);
  }

  Future<Map> _request(
    String path,
    Map<String, Object?> json,
    CancellationToken token, {
    String? shareToken,
  }) async {
    final result = await requestCloudShareJson(
      _http,
      Uri.https(_host, path),
      _home,
      token,
      json: json,
      headers: {
        'X-Canary': 'client=web,app=share,version=v2.3.1',
        'X-Share-Token': ?shareToken,
      },
    );
    final code = result['code'];
    if (code == null) return result;
    throw PublicationFailure(switch (code) {
      'ShareLink.PwdInvalid' ||
      'ShareLink.PasswordRequired' => PublicationProblem.shareCode,
      'ShareLink.Forbidden' ||
      'ShareLink.NotFound' ||
      'ShareLink.Expired' => PublicationProblem.missing,
      _ => PublicationProblem.network,
    });
  }
}
