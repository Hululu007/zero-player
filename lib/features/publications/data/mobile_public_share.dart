import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import '../domain/cloud_share_address.dart';
import 'cloud_share_listing.dart';
import 'cloud_shared_file.dart';
import 'publication_http.dart';

typedef MobileCloudAccount = ({String phone, String authorization});

bool validMobileCloudAccount(String phone, String authorization) =>
    RegExp(r'^1[0-9]{10}$').hasMatch(phone) &&
    RegExp(r'^Basic [A-Za-z0-9+/=_-]{16,4096}$').hasMatch(authorization);

final class MobilePublicShare {
  MobilePublicShare(this._http);

  final PublicationHttp _http;
  static final _home = Uri.https('yun.139.com', '/shareweb/');
  static const _apiHost = 'share-kd-njs.yun.139.com';
  static const _pageSize = 50;

  Future<CloudShareListing> inspectTree(
    Uri link,
    String? code,
    CancellationToken token, {
    bool preview = false,
  }) {
    final share = _share(link, code);
    return listCloudShare('root', token, (folder, page) {
      return _page(share, folder, page, token);
    }, preview: preview);
  }

  Future<PublicationDownload> resolve(
    Uri link,
    String? code,
    String? id,
    CancellationToken token,
    bool Function(CloudSharedFile) matches, {
    MobileCloudAccount? account,
  }) async {
    final share = _share(link, code);
    final (_, fileId) = splitCloudShareFileId(id);
    String? published;
    await findCloudShareFile(id, matches, (folder, page) {
      return _page(
        share,
        folder,
        page,
        token,
        onFile: (row) {
          if ((cloudNodeId(row['coID']) == fileId
                  ? row['cdnDownLoadUrl']
                  : null)
              case final String url when url.isNotEmpty) {
            published = url;
          }
        },
      );
    });
    if (published case final String url) return _download(url);
    final base = {'linkID': share.id, 'passwd': share.code};
    if (account == null) {
      final result = await _request(
        'getContentInfoFromOutLink',
        {
          'getContentInfoFromOutLinkReq': {
            ...base,
            'contentId': fileId,
            'account': '',
          },
        },
        token,
        allowLoginRequired: true,
      );
      if (result case {'data': {'contentInfo': final Map info}}) {
        final direct = info['cdnDownloadUrl'] ?? info['cdnDownLoadUrl'];
        if (direct is String && direct.isNotEmpty) return _download(direct);
      }
      throw const PublicationFailure(PublicationProblem.login);
    }
    final result = await _request(
      'dlFromOutLinkV3',
      {
        'dlFromOutLinkReqV3': {
          ...base,
          'account': account.phone,
          'coIDLst': {
            'item': [fileId],
          },
        },
      },
      token,
      account: account,
    );
    if (result case {'data': {'extInfo': final Map info}}) {
      for (final key in ['cdnDownloadUrl', 'redrUrl', 'downloadURL']) {
        if (info[key] case final String url when url.isNotEmpty) {
          return _download(url);
        }
      }
    }
    throw const PublicationFailure(PublicationProblem.emptyResponse);
  }

  ({String id, String code}) _share(Uri link, String? code) {
    final id = mobileShareId(link);
    if (id == null) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    if (!validCloudShareCode(code)) {
      throw const PublicationFailure(PublicationProblem.shareCode);
    }
    return (id: id, code: code ?? '');
  }

  Future<CloudSharePage> _page(
    ({String id, String code}) share,
    String folder,
    int page,
    CancellationToken token, {
    void Function(Map)? onFile,
  }) async {
    final result = await _request('getOutLinkInfoV6', {
      'getOutLinkInfoReq': {
        'linkID': share.id,
        'passwd': share.code,
        'pCaID': folder,
        'bNum': (page - 1) * _pageSize + 1,
        'eNum': page * _pageSize,
        'srtDr': 1,
        'caSrt': '',
        'coSrt': '',
      },
    }, token);
    if (result case {'data': final Map data}) {
      final files = _nodes(data['coLst'], 'coID', 'coName', 'coSize', onFile);
      final directories = _nodes(data['caLst'], 'caID', 'caName');
      final count = cloudNodeSize(data['nodNum']);
      return (
        files: files,
        directories: directories,
        more: count != null
            ? count > page * _pageSize
            : (files.length + directories.length) >= _pageSize,
      );
    }
    throw const PublicationFailure(PublicationProblem.invalid);
  }

  List<CloudShareNode> _nodes(
    Object? rows,
    String key,
    String name, [
    String? size,
    void Function(Map)? onFile,
  ]) {
    if (rows is! List) return const [];
    final nodes = <CloudShareNode>[];
    for (final row in rows.take(_pageSize)) {
      if (row is! Map) continue;
      final id = cloudNodeId(row[key]);
      final label = cloudNodeName(row[name]);
      if (id == null || label.isEmpty) continue;
      onFile?.call(row);
      nodes.add((id: id, name: label, bytes: cloudNodeSize(row[size])));
    }
    return nodes;
  }

  Future<Map> _request(
    String operation,
    Map<String, Object?> payload,
    CancellationToken token, {
    MobileCloudAccount? account,
    bool allowLoginRequired = false,
  }) async {
    final target = Uri.https(
      _apiHost,
      '/yun-share/richlifeApp/devapp/IOutLink/$operation',
    );
    final result = await requestCloudShareJson(
      _http,
      target,
      _home,
      token,
      json: payload,
      headers: {if (account != null) 'Authorization': account.authorization},
    );
    final code = result['resultCode']?.toString();
    if (code == '0') return result;
    final message = (result['desc'] ?? result['resultDesc'])?.toString() ?? '';
    if (code == '200000401' ||
        message.contains('鉴权') ||
        message.contains('登录')) {
      if (allowLoginRequired) return const {};
      throw const PublicationFailure(PublicationProblem.login);
    }
    if (code == '9188' || message.contains('密码') || message.contains('提取码')) {
      throw const PublicationFailure(PublicationProblem.shareCode);
    }
    if (code == '200000727' ||
        message.contains('不存在') ||
        message.contains('失效') ||
        message.contains('过期')) {
      throw const PublicationFailure(PublicationProblem.missing);
    }
    throw const PublicationFailure(PublicationProblem.network);
  }

  PublicationDownload _download(String url) => cloudSiteDownload(
    url,
    _home,
    (target) =>
        hostIn(target, 'yun.139.com') || hostIn(target, 'mcloud.139.com'),
  );
}
