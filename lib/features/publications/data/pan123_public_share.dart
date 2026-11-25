import 'dart:convert';

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'cloud_share_listing.dart';
import 'cloud_shared_file.dart';
import 'publication_http.dart';
import 'publication_share_provider.dart';

final class Pan123PublicShare {
  Pan123PublicShare(this._http);

  final PublicationHttp _http;
  static const _host = 'yun.123pan.com';
  static final _home = Uri.https(_host, '/');
  static const _pageSize = 50;
  static final _path = RegExp(r'^/s/([A-Za-z0-9_-]{4,128})(?:\.html)?/?$');

  Future<CloudShareListing> inspectTree(
    Uri link,
    String? code,
    CancellationToken token, {
    bool preview = false,
  }) {
    final fields = _share(link, code);
    return listCloudShare('0', token, (folder, page) {
      return _page(fields, folder, page, token);
    }, preview: preview);
  }

  Future<PublicationDownload> resolve(
    Uri link,
    String? code,
    String? id,
    CancellationToken token,
    bool Function(CloudSharedFile) matches,
  ) async {
    final fields = _share(link, code);
    final (_, file) = splitCloudShareFileId(id);
    Map? metadata;
    final current = await findCloudShareFile(id, matches, (folder, page) {
      return _page(
        fields,
        folder,
        page,
        token,
        onFile: (row) {
          if (cloudNodeId(row['FileId']) == file) metadata = row;
        },
      );
    });
    final etag = metadata?['Etag'];
    final storage = metadata?['S3KeyFlag'];
    final fileId = int.tryParse(file);
    if (etag is! String ||
        etag.length > 128 ||
        storage is! String ||
        storage.length > 512 ||
        fileId == null ||
        current.bytes == null) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    final result = await _request(
      'download/info',
      null,
      token,
      json: {
        ...fields,
        'etag': etag,
        'fileId': fileId,
        's3keyFlag': storage,
        'size': current.bytes,
      },
    );
    return _resolvedDownload(result['DownloadURL'], token);
  }

  Future<PublicationDownload> _resolvedDownload(
    Object? raw,
    CancellationToken token,
  ) async {
    final wrapper = raw is String && raw.length <= 12000
        ? Uri.tryParse(raw)
        : null;
    if (wrapper == null) {
      throw const PublicationFailure(PublicationProblem.emptyResponse);
    }
    if (wrapper.scheme != 'https' ||
        wrapper.port != 443 ||
        wrapper.userInfo.isNotEmpty) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final encoded = wrapper.queryParameters['params'];
    if (wrapper.host != 'web-pro2.cjjd18.com' ||
        wrapper.path != '/download-v2/' ||
        encoded == null) {
      return cloudSiteDownload(raw, _home, _cdn);
    }

    // The provider's download page passes this signed URL to its download client.
    String address;
    try {
      address = utf8.decode(base64Decode(encoded));
    } on FormatException {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    final source = cloudSiteDownload(address, wrapper, _cdn);
    if (wrapper.queryParameters['is_s3'] == '1') return source;
    return withPublicationRequestDeadline(token, const Duration(seconds: 15), (
      request,
    ) async {
      final response = await _http.open(
        source.uri,
        request,
        scope: source.scope,
        referer: source.referer,
        range: 'bytes=0-0',
      );
      final status = response.response.statusCode;
      if (status == 200 || status == 206) {
        await discardPublicationResponse(response);
        return source;
      }
      if (status != 210) {
        await discardPublicationResponse(response);
        throw publicationHttpFailure(response);
      }
      final body = await _http.readText(
        response,
        request,
        maxBytes: 32 << 10,
        acceptedStatuses: const {210},
      );
      try {
        final result = jsonDecode(body);
        if (result case {
          'code': 0,
          'data': {'redirect_url': final String url},
        }) {
          return cloudSiteDownload(url, wrapper, _cdn);
        }
      } on FormatException {
        // The provider response can include a signed download URL.
      }
      throw const PublicationFailure(PublicationProblem.emptyResponse);
    });
  }

  bool _cdn(Uri target) =>
      hostIn(target, '123pan.com') ||
      hostIn(target, '123pan.cn') ||
      hostIn(target, '123684.com') ||
      hostIn(target, '123865.com') ||
      hostIn(target, '123pan.net') ||
      hostIn(target, '123295.com') ||
      hostIn(target, 'cjjd19.com');

  Map<String, String> _share(Uri link, String? code) {
    final id = _path.firstMatch(link.path)?[1];
    if (id == null ||
        PublicationShareProvider.of(link) != PublicationShareProvider.pan123 ||
        link.userInfo.isNotEmpty ||
        !((link.scheme == 'https' && link.port == 443) ||
            (link.scheme == 'http' && link.port == 80))) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    if (!validCloudShareCode(code)) {
      throw const PublicationFailure(PublicationProblem.shareCode);
    }
    return {'shareKey': id, 'SharePwd': code ?? ''};
  }

  Future<CloudSharePage> _page(
    Map<String, String> fields,
    String folder,
    int page,
    CancellationToken token, {
    void Function(Map)? onFile,
  }) async {
    final result = await _request('get', {
      ...fields,
      'limit': '$_pageSize',
      'next': '0',
      'orderBy': 'file_id',
      'orderDirection': 'desc',
      'parentFileId': folder,
      'Page': '$page',
    }, token);
    if (result['Expired'] == true) {
      throw const PublicationFailure(PublicationProblem.missing);
    }
    if (result['InfoList'] case final List rows) {
      final files = <CloudShareNode>[];
      final directories = <CloudShareNode>[];
      for (final row in rows.take(_pageSize)) {
        if (row is! Map) continue;
        final id = cloudNodeId(row['FileId']);
        final name = cloudNodeName(row['FileName']);
        if (id == null || name.isEmpty) continue;
        switch (row['Type']) {
          case 1:
            directories.add((id: id, name: name, bytes: null));
          case 0:
            onFile?.call(row);
            files.add((id: id, name: name, bytes: cloudNodeSize(row['Size'])));
        }
      }
      return (
        files: files,
        directories: directories,
        more: rows.isNotEmpty && result['Next']?.toString() != '-1',
      );
    }
    throw const PublicationFailure(PublicationProblem.invalid);
  }

  Future<Map> _request(
    String operation,
    Map<String, String>? query,
    CancellationToken token, {
    Map<String, Object?>? json,
  }) async {
    final result = await requestCloudShareJson(
      _http,
      Uri.https(_host, '/b/api/share/$operation', query),
      _home,
      token,
      json: json,
      headers: const {'Platform': 'web', 'App-Version': '3'},
    );
    if (result case {'code': 0, 'data': final Map data}) return data;
    final message = result['message'];
    throw PublicationFailure(switch ((result['code'], message)) {
      (5112, _) => PublicationProblem.guestLimit,
      (401 || 403, _) => PublicationProblem.login,
      (_, final String text) when text.contains('登录') =>
        PublicationProblem.login,
      (_, final String text) when text.contains('提取码') || text.contains('密码') =>
        PublicationProblem.shareCode,
      (_, final String text)
          when text.contains('失效') || text.contains('取消分享') =>
        PublicationProblem.missing,
      _ => PublicationProblem.network,
    });
  }
}
