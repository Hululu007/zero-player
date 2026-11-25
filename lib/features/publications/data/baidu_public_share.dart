import 'dart:collection';
import 'dart:convert';

import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'cloud_shared_file.dart';
import 'publication_http.dart';
import 'publication_share_provider.dart';

final class BaiduPublicShare {
  BaiduPublicShare(this.http);

  final PublicationHttp http;
  static const _pageSize = 100;
  static const _directoryBudget = 20;
  static const _filesLimit = 600;
  static final _origin = Uri.https('pan.baidu.com', '/');
  static final _legacyData = RegExp(
    r'(?:^|\n)\s*(?:window\.)?locals\.mset\(\s*(\{[^\r\n]*\})\s*\)\s*;',
  );
  static final _initialPage = RegExp(
    r"""SHAREPAGETYPE\s*=\s*['"]init['"]|name\s*=\s*['"]accessForm['"]""",
  );
  static final _digits = RegExp(r'^[0-9]{1,20}$');
  static const _web = {
    'channel': 'chunlei',
    'clienttype': '0',
    'web': '1',
    'app_id': '250528',
  };

  Future<List<CloudSharedFile>> inspect(
    Uri address,
    String? code,
    CancellationToken token,
  ) async => _files(await _open(address, code, token), token).toList();

  Future<CloudShareListing> inspectTree(
    Uri link,
    String? code,
    CancellationToken token, {
    bool preview = false,
  }) async {
    final share = await _open(link, code, token);
    var truncated = false;
    final entries = _entries(share, token, onLimit: () => truncated = true);
    final files = await (preview ? entries.take(6) : entries).toList();
    return (
      files: files,
      truncated: truncated || (preview && files.length == 6),
    );
  }

  Future<PublicationDownload> resolve(
    Uri address,
    String? fileId,
    String? code,
    CancellationToken token,
    bool Function(CloudSharedFile) matches, {
    String? accessToken,
  }) async {
    if (fileId == null || !_digits.hasMatch(fileId)) {
      throw const PublicationFailure(PublicationProblem.shareFile);
    }
    final share = await _open(address, code, token);
    await for (final file in _files(share, token)) {
      if (file.id != fileId) continue;
      if (!matches(file)) {
        throw const PublicationFailure(PublicationProblem.invalid);
      }
      return _download(share, file, token, accessToken);
    }
    throw const PublicationFailure(PublicationProblem.missing);
  }

  Future<_BaiduShare> _open(
    Uri address,
    String? code,
    CancellationToken token,
  ) async {
    if (!isBaiduPublicationShare(address)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final page = baiduPublicationSharePage(address, null);
    final cookies = GuestShareSession(_isSite);
    Future<String> readPage() => http.text(
      page,
      token,
      scope: _requireSite,
      guest: cookies,
      allowGzip: true,
    );

    var markup = await readPage();
    String? ticket;
    if (_initialPage.hasMatch(markup)) {
      ticket = await _verify(
        page,
        cookies,
        code ?? address.queryParameters['pwd'],
        token,
      );
      markup = await readPage();
      if (_initialPage.hasMatch(markup)) {
        throw const PublicationFailure(PublicationProblem.challenge);
      }
    }

    final document = html.parse(markup);
    final script = document.querySelector(
      'script#locals-data[type="application/json"]',
    );
    final data = _decode(script?.text ?? _legacyData.firstMatch(markup)?[1]);
    final id = _number(data?['shareid']);
    final owner = _number(data?['share_uk']);
    final rows = _rows(data?['file_list']);
    if (id == null || owner == null || rows == null) {
      final title = document.querySelector('title')?.text ?? '';
      throw PublicationFailure(
        title.contains('不存在') || title.contains('已失效')
            ? PublicationProblem.missing
            : PublicationProblem.challenge,
      );
    }
    return _BaiduShare(
      page: page,
      cookies: cookies,
      id: id,
      owner: owner,
      ticket: _text(data?['sekey']) ?? ticket,
      rows: rows,
    );
  }

  Future<String> _verify(
    Uri page,
    GuestShareSession cookies,
    String? code,
    CancellationToken token,
  ) async {
    if (code == null || !RegExp(r'^[A-Za-z0-9]{4}$').hasMatch(code)) {
      throw const PublicationFailure(PublicationProblem.shareCode);
    }
    final shortLink = _shareKey(page);
    if (shortLink.length != 23 || !shortLink.startsWith('1')) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final verification = await _request(
      page,
      cookies,
      token,
      '/share/verify',
      {
        't': DateTime.now().millisecondsSinceEpoch.toString(),
        'bioc': '1',
        'surl': shortLink.substring(1),
      },
      form: {'pwd': code, 'vcode': '', 'vcode_str': ''},
    );
    final value = _text(verification['randsk']);
    if (value == null) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    return Uri.decodeComponent(value);
  }

  Stream<CloudSharedFile> _files(_BaiduShare share, CancellationToken token) =>
      _entries(share, token).map((item) => item.file);

  Stream<CloudShareItem> _entries(
    _BaiduShare share,
    CancellationToken token, {
    void Function()? onLimit,
  }) async* {
    final seenFiles = <String>{};
    final directories = Queue<(String, int, List<String>)>();
    final seenPaths = <String>{};
    var rows = share.rows;
    var folders = const <String>[];
    for (var requested = 0; requested <= _directoryBudget; requested++) {
      token.check();
      for (final row in rows) {
        token.check();
        if (_number(row['isdir']) == '1') {
          final path = _text(row['path']);
          if (path == null ||
              !path.startsWith('/') ||
              seenPaths.contains(path)) {
            continue;
          }
          if (seenPaths.length >= _directoryBudget) {
            onLimit?.call();
            continue;
          }
          seenPaths.add(path);
          final name = publicationLabel(row['server_filename']);
          directories.add((
            path,
            1,
            [...folders, name.isEmpty ? path.split('/').last : name],
          ));
        } else if (_file(row) case final file? when seenFiles.add(file.id!)) {
          yield CloudShareItem(file, folders);
          if (seenFiles.length >= _filesLimit) {
            onLimit?.call();
            return;
          }
        }
      }
      if (directories.isEmpty) break;
      if (requested == _directoryBudget) {
        onLimit?.call();
        break;
      }
      final (path, page, parents) = directories.removeFirst();
      folders = parents;
      final data =
          await _request(share.page, share.cookies, token, '/share/list', {
            'uk': share.owner,
            'shareid': share.id,
            'page': '$page',
            'num': '$_pageSize',
            'dir': path,
            'order': 'name',
            'desc': '0',
            'showempty': '0',
            'web': '1',
            'clienttype': '0',
          });
      rows = _rows(data['list']) ?? const [];
      if (rows.length > _pageSize) {
        throw const PublicationFailure(PublicationProblem.invalid);
      }
      if (rows.length == _pageSize) directories.add((path, page + 1, parents));
    }
  }

  Future<PublicationDownload> _download(
    _BaiduShare share,
    CloudSharedFile file,
    CancellationToken token,
    String? accessToken,
  ) async {
    final signature =
        await _request(share.page, share.cookies, token, '/share/tplconfig', {
          ..._web,
          'fields': 'sign,timestamp',
          'view_mode': '1',
          'surl': _shareKey(share.page),
        });
    final data = signature['data'];
    final sign = data is Map ? _text(data['sign']) : null;
    final timestamp = data is Map ? _number(data['timestamp']) : null;
    final browserId = share.cookies
        .forAddress(_origin)
        ?.split('; ')
        .where((cookie) => cookie.startsWith('BAIDUID='))
        .firstOrNull;
    if (sign == null || timestamp == null || browserId == null) {
      throw const PublicationFailure(PublicationProblem.challenge);
    }
    final reply = await _request(
      share.page,
      share.cookies,
      token,
      '/api/sharedownload',
      {
        ..._web,
        'sign': sign,
        'timestamp': timestamp,
        'logid': base64Encode(
          utf8.encode(browserId.substring('BAIDUID='.length)),
        ),
      },
      form: {
        'encrypt': '0',
        'product': 'share',
        'uk': share.owner,
        'primaryid': share.id,
        'fid_list': '[${file.id}]',
        if (share.ticket != null) 'extra': jsonEncode({'sekey': share.ticket}),
      },
    );
    if (reply['list'] is String) {
      throw const PublicationFailure(PublicationProblem.guestLimit);
    }
    final result = _rows(reply['list'])?.singleOrNull;
    final raw = result?['dlink'];
    final link = raw is String ? Uri.tryParse(raw) : null;
    if (result == null || _file(result) != file || link == null) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    _requireDownload(link);
    http.authorize(link);
    final download = accessToken == null
        ? link
        : _authorizedLink(link, accessToken);
    return PublicationDownload(
      download,
      scope: _requireDownload,
      referer: share.page,
      detectGuestQuota: true,
      allowRanges: false,
    );
  }

  Future<Map> _request(
    Uri page,
    GuestShareSession cookies,
    CancellationToken token,
    String path,
    Map<String, String> query, {
    Map<String, String>? form,
  }) async {
    final body = await http.text(
      Uri.https(page.host, path, query),
      token,
      scope: _requireSite,
      guest: cookies,
      referer: page,
      form: form,
      maxBytes: 512 << 10,
      allowGzip: true,
    );
    final data = _decode(body);
    final problem = switch (data?['errno']) {
      0 => null,
      -9 when path == '/share/verify' => PublicationProblem.shareCode,
      -6 || 9019 => PublicationProblem.login,
      -19 ||
      -20 ||
      -62 ||
      -63 ||
      112 ||
      113 ||
      118 ||
      8046 => PublicationProblem.challenge,
      _ => PublicationProblem.invalid,
    };
    if (problem != null) throw PublicationFailure(problem);
    return data!;
  }

  static String _shareKey(Uri uri) =>
      uri.pathSegments.where((part) => part.isNotEmpty).last;

  static CloudSharedFile? _file(Map row) {
    final id = _number(row['fs_id']);
    final name = publicationLabel(row['server_filename']);
    final bytes = int.tryParse(_number(row['size']) ?? '');
    if (_number(row['isdir']) != '0' ||
        id == null ||
        bytes == null ||
        bytes < 1 ||
        name.isEmpty) {
      return null;
    }
    return (name: name, id: id, bytes: bytes);
  }

  static List<Map>? _rows(Object? value) =>
      value is List ? value.whereType<Map>().toList(growable: false) : null;

  static Map? _decode(String? body) {
    if (body == null) return null;
    try {
      final decoded = jsonDecode(body.trim());
      return decoded is Map ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static String? _number(Object? value) {
    final text = value is int ? '$value' : value;
    return text is String && _digits.hasMatch(text) ? text : null;
  }

  static String? _text(Object? value) =>
      value is String && value.isNotEmpty && value.length <= 2048
      ? value
      : null;

  static bool _isSite(Uri uri) =>
      uri.scheme == 'https' &&
      uri.port == 443 &&
      uri.host == _origin.host &&
      uri.userInfo.isEmpty;

  static void _requireSite(Uri uri) {
    if (!_isSite(uri)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
  }

  static void _requireDownload(Uri uri) {
    if (uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        (uri.queryParameters.containsKey('access_token') &&
            uri.host != 'd.pcs.baidu.com') ||
        !const [
          'pcs.baidu.com',
          'baidupcs.com',
        ].any((host) => hostIn(uri, host))) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
  }

  static Uri _authorizedLink(Uri link, String accessToken) {
    if (!validBaiduPublicationToken(accessToken) ||
        link.host != 'd.pcs.baidu.com' ||
        link.queryParametersAll.containsKey('access_token')) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final query = Uri(queryParameters: {'access_token': accessToken}).query;
    return link.replace(query: link.hasQuery ? '${link.query}&$query' : query);
  }
}

final class _BaiduShare {
  const _BaiduShare({
    required this.page,
    required this.cookies,
    required this.id,
    required this.owner,
    required this.ticket,
    required this.rows,
  });

  final Uri page;
  final GuestShareSession cookies;
  final String id, owner;
  final String? ticket;
  final List<Map> rows;
}
