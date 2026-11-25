import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import '../domain/cloud_share_address.dart';
import 'cloud_share_listing.dart';
import 'cloud_shared_file.dart';
import 'publication_http.dart';

bool validTianyiCloudToken(String value) =>
    RegExp(r'^[A-Za-z0-9._~+/=-]{16,2048}$').hasMatch(value);

typedef _TianyiShare = ({
  String id,
  String root,
  String name,
  int? bytes,
  bool directory,
  String? code,
  String mode,
  String session,
});

final class TianyiPublicShare {
  TianyiPublicShare(this._http);

  final PublicationHttp _http;
  static const _host = 'api.cloud.189.cn';
  static final _home = Uri.https('h5.cloud.189.cn', '/share.html');
  static const _pageSize = 50;
  static final _random = Random.secure();

  Future<CloudShareListing> inspectTree(
    Uri link,
    String? code,
    CancellationToken token, {
    bool preview = false,
  }) async {
    final share = await _share(link, code, token);
    if (!share.directory) {
      return (
        files: [
          CloudShareItem((
            name: share.name,
            id: 'root:${share.root}',
            bytes: share.bytes,
          ), const []),
        ],
        truncated: false,
      );
    }
    return listCloudShare(share.root, token, (folder, page) {
      return _page(share, folder, page, token);
    }, preview: preview);
  }

  Future<PublicationDownload> resolve(
    Uri link,
    String? code,
    String? id,
    CancellationToken token,
    bool Function(CloudSharedFile) matches, {
    String? accessToken,
  }) async {
    final share = await _share(link, code, token);
    final (folder, file) = splitCloudShareFileId(id);
    if (share.directory) {
      await findCloudShareFile(id, matches, (folder, page) {
        return _page(share, folder, page, token);
      });
    } else if (folder != 'root' ||
        file != share.root ||
        !matches((name: share.name, id: id, bytes: share.bytes))) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }

    if (accessToken == null || !validTianyiCloudToken(accessToken)) {
      throw const PublicationFailure(PublicationProblem.login);
    }
    final result = await _request(
      '/open/file/getFileDownloadUrl.action',
      {'fileId': file, 'shareId': share.id, 'dt': '1'},
      token,
      accessToken: accessToken,
    );
    return cloudSiteDownload(
      result['fileDownloadUrl'],
      _home,
      (target) =>
          hostIn(target, 'cloud.189.cn') ||
          hostIn(target, 'cloud.dlife.cn') ||
          hostIn(target, 'cloud.21cn.com'),
    );
  }

  Future<_TianyiShare> _share(
    Uri link,
    String? code,
    CancellationToken token,
  ) async {
    final id = tianyiShareId(link);
    if (id == null) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    if (!validCloudShareCode(code)) {
      throw const PublicationFailure(PublicationProblem.shareCode);
    }
    final result = await _request(
      '/open/share/getShareInfoByCodeV2.action',
      {'shareCode': id},
      token,
      post: true,
    );
    final root = cloudNodeId(result['fileId']);
    final name = cloudNodeName(result['fileName']);
    final mode = cloudNodeId(result['shareMode']);
    final directory = result['isFolder'] == true;
    final session = List.generate(
      32,
      (_) => _random.nextInt(16).toRadixString(16),
    ).join();
    var share = cloudNodeId(result['shareId']);
    if (result['needAccessCode'] == 1 || result['needAccessCode'] == true) {
      if (code == null) {
        throw const PublicationFailure(PublicationProblem.shareCode);
      }
      final verified = await _request(
        '/open/share/checkAccessCode.action',
        {'shareCode': id, 'uuid': session, 'accessCode': code},
        token,
        post: true,
        checkingCode: true,
      );
      share = cloudNodeId(verified['shareId']);
      if (share == null) {
        throw const PublicationFailure(PublicationProblem.shareCode);
      }
    }
    if (root == null || share == null || name.isEmpty || mode == null) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    return (
      id: share,
      root: root,
      name: name,
      bytes: cloudNodeSize(result['fileSize']),
      directory: directory,
      mode: mode,
      code: code,
      session: session,
    );
  }

  Future<CloudSharePage> _page(
    _TianyiShare share,
    String folder,
    int page,
    CancellationToken token,
  ) async {
    final result = await _request('/open/share/listShareDir.action', {
      'uuid': share.session,
      'shareId': share.id,
      'fileId': folder,
      'shareMode': share.mode,
      'isFolder': 'true',
      'iconOption': '5',
      'pageSize': '$_pageSize',
      'pageNum': '$page',
      if (share.code case final String code) 'accessCode': code,
    }, token);
    if (result case {'fileListAO': final Map data}) {
      final files = _nodes(data['fileList'], files: true);
      final directories = _nodes(data['folderList']);
      final count = cloudNodeSize(data['count']);
      return (
        files: files,
        directories: directories,
        more: count != null
            ? count > page * _pageSize
            : files.length + directories.length >= _pageSize,
      );
    }
    throw const PublicationFailure(PublicationProblem.invalid);
  }

  List<CloudShareNode> _nodes(Object? rows, {bool files = false}) => [
    if (rows is List)
      for (final row in rows.take(_pageSize))
        if (row is Map)
          if (cloudNodeId(row['id']) case final String id)
            if (cloudNodeName(row['name']) case final label
                when label.isNotEmpty)
              (
                id: id,
                name: label,
                bytes: files ? cloudNodeSize(row['size']) : null,
              ),
  ];

  Future<Map> _request(
    String path,
    Map<String, String> fields,
    CancellationToken token, {
    bool post = false,
    bool checkingCode = false,
    String? accessToken,
  }) async {
    final headers = <String, String>{};
    if (accessToken != null) {
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final parameters = SplayTreeMap<String, String>.of({
        ...fields,
        'AccessToken': accessToken,
        'Timestamp': timestamp,
      });
      final signed = parameters.entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join('&');
      headers.addAll({
        'AccessToken': accessToken,
        'Timestamp': timestamp,
        'Sign-Type': '1',
        'Signature': md5.convert(utf8.encode(signed)).toString(),
      });
    }
    final result = await requestCloudShareJson(
      _http,
      Uri.https(_host, path, post ? null : fields),
      _home,
      token,
      form: post ? fields : null,
      headers: headers,
    );
    final code = result['res_code'];
    if (code == 0 || code == '0') return result;
    throw PublicationFailure(switch (code) {
      'InvalidAccessToken' ||
      'AccessTokenHasExpired' ||
      'InvalidSessionKey' ||
      'CommonInvalidSessionKey' => PublicationProblem.login,
      'ShareAccessCodeFaildCountOver' ||
      'ShareAccessOverLimited' => PublicationProblem.rateLimit,
      'ShareExpiredError' ||
      'ShareExpired' ||
      'ShareInfoNotFound' ||
      'ShareNotFound' => PublicationProblem.missing,
      _ when checkingCode => PublicationProblem.shareCode,
      _ => PublicationProblem.network,
    });
  }
}
