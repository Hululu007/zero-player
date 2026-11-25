import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'cloud_shared_file.dart';
import 'publication_http.dart';

typedef _QuarkPage = ({List<Map> rows, bool more});

final class QuarkPublicShare {
  QuarkPublicShare(this.http);
  final PublicationHttp http;
  static final _origin = Uri.https('pan.quark.cn', '/');
  static final _api = Uri.https('drive-pc.quark.cn', '/1/clouddrive/');
  static final _fid = RegExp(r'^[A-Za-z0-9_-]{1,80}$');
  static final _cdn = RegExp(r'^dl-guest-[a-z0-9-]+\.drive\.quark\.cn$');
  static const _pageSize = 100;
  static const _maxPagesPerFolder = 8;
  static const _directoryBudget = 20;

  Future<List<PublicationSharedFile>> inspect(
    Uri link,
    String? code,
    CancellationToken token,
  ) => _inspect(link, code, token, (file, _) => sharedPublication(file));

  Future<List<CloudSharedFile>> inspectResources(
    Uri link,
    String? code,
    CancellationToken token,
  ) => _inspect(link, code, token, (file, _) => file);

  Future<CloudShareListing> inspectTree(
    Uri link,
    String? code,
    CancellationToken token, {
    bool preview = false,
  }) async {
    var truncated = false;
    final files = await _inspect(
      link,
      code,
      token,
      CloudShareItem.new,
      preview: preview,
      onLimit: () => truncated = true,
    );
    return (files: files, truncated: truncated);
  }

  Future<List<T>> _inspect<T>(
    Uri link,
    String? code,
    CancellationToken token,
    T? Function(CloudSharedFile, List<String>) select, {
    void Function()? onLimit,
    bool preview = false,
  }) async {
    final id = _shareId(link);
    final ticket = await _ticket(id, code, token);
    final folders = Queue.of([('0', 1, const <String>[])]);
    final seen = {'0'};
    final files = <T>[];
    for (
      var requests = 0;
      requests < (preview ? 8 : _directoryBudget) && folders.isNotEmpty;
      requests++
    ) {
      final (parent, index, path) = folders.removeFirst();
      final page = await _page(id, ticket, parent, index, token);
      for (final row in page.rows) {
        final fid = row['fid'];
        if (fid is! String || !_fid.hasMatch(fid)) continue;
        if (row['dir'] == true) {
          if (seen.contains(fid)) continue;
          final folder = publicationLabel(row['file_name']);
          if (seen.length >= _directoryBudget) {
            onLimit?.call();
            continue;
          }
          seen.add(fid);
          folders.add((fid, 1, [...path, folder.isEmpty ? fid : folder]));
        } else if (_file(row, parent, fid) case final info?) {
          final file = select(info, path);
          if (file == null) continue;
          files.add(file);
          if (files.length >= (preview ? 6 : 600)) {
            onLimit?.call();
            return files;
          }
        }
      }
      if (page.more) {
        if (index < _maxPagesPerFolder) {
          folders.add((parent, index + 1, path));
        } else {
          onLimit?.call();
        }
      }
    }
    if (folders.isNotEmpty) onLimit?.call();
    return files;
  }

  Future<PublicationDownload> resolve(
    AcquisitionCandidate candidate,
    String? code,
    CancellationToken token,
  ) => _resolve(candidate.link, candidate.fileId, code, token, (file) {
    final book = sharedPublication(file);
    return book != null && candidate.matchesSharedFile(book);
  });

  Future<PublicationDownload> resolveResource(
    Uri link,
    CloudSharedFile file,
    String? code,
    CancellationToken token,
  ) => _resolve(link, file.id, code, token, (current) => current == file);

  Future<PublicationDownload> _resolve(
    Uri link,
    String? fileId,
    String? code,
    CancellationToken token,
    bool Function(CloudSharedFile) matches,
  ) async {
    final parts = fileId?.split(':');
    if (parts == null ||
        parts.length != 2 ||
        parts.any((part) => !_fid.hasMatch(part))) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final id = _shareId(link);
    final ticket = await _ticket(id, code, token);
    final parent = parts[0];
    final fid = parts[1];
    for (var index = 1; index <= _maxPagesPerFolder; index++) {
      final page = await _page(id, ticket, parent, index, token);
      final row = page.rows.where((row) => row['fid'] == fid).firstOrNull;
      if (row != null) {
        final file = _file(row, parent, fid);
        final fileTicket = row['share_fid_token'];
        if (row['dir'] == true ||
            file == null ||
            !matches(file) ||
            !_isTicket(fileTicket)) {
          throw const PublicationFailure(PublicationProblem.invalid);
        }
        return _download(id, ticket, fid, fileTicket as String, token);
      }
      if (!page.more) break;
    }
    throw const PublicationFailure(PublicationProblem.missing);
  }

  CloudSharedFile? _file(Map row, String parent, String fid) {
    final name = publicationLabel(row['file_name']);
    final bytes = row['size'];
    if (row['dir'] == true || name.isEmpty || bytes is! int || bytes < 1) {
      return null;
    }
    return (name: name, id: '$parent:$fid', bytes: bytes);
  }

  String _shareId(Uri link) {
    final path = link.pathSegments;
    if (link.origin != _origin.origin ||
        path.length != 2 ||
        path.first != 's' ||
        !_fid.hasMatch(path.last)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    return path.last;
  }

  bool _isTicket(Object? value) =>
      value is String && value.isNotEmpty && value.length <= 2048;

  Future<String> _ticket(
    String id,
    String? code,
    CancellationToken token,
  ) async {
    final (result, _) = await _request(
      'share/sharepage/token',
      token,
      body: {
        'pwd_id': id,
        'passcode': code ?? '',
        'support_visit_limit_private_share': true,
      },
    );
    final data = result['data'];
    final ticket = data is Map ? data['stoken'] : null;
    if (!_isTicket(ticket)) {
      throw PublicationFailure(
        data is Map && data['need_passcode'] == true
            ? PublicationProblem.shareCode
            : PublicationProblem.invalid,
      );
    }
    return ticket as String;
  }

  Future<_QuarkPage> _page(
    String id,
    String ticket,
    String parent,
    int index,
    CancellationToken token,
  ) async {
    final (result, _) = await _request(
      'share/sharepage/detail',
      token,
      query: {
        'pwd_id': id,
        'stoken': ticket,
        'pdir_fid': parent,
        'ver': '2',
        '_page': '$index',
        '_size': '$_pageSize',
        '_fetch_total': '1',
        '_sort': 'file_type:asc,file_name:asc',
      },
    );
    final data = result['data'];
    final rows = data is Map ? data['list'] : null;
    if (rows is! List || rows.length > _pageSize) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    final metadata = result['metadata'];
    final total = metadata is Map ? metadata['_total'] : null;
    return (
      rows: rows.whereType<Map>().toList(),
      more: total is int ? index * _pageSize < total : rows.length == _pageSize,
    );
  }

  Future<PublicationDownload> _download(
    String id,
    String ticket,
    String fid,
    String fileTicket,
    CancellationToken token,
  ) async {
    final (result, cookies) = await _request(
      'file/download',
      token,
      query: {'sys': 'win32', 've': '3.23.2'},
      body: {
        'pwd_id': id,
        'stoken': ticket,
        'fids': [fid],
        'fids_token': [fileTicket],
        'speedup_session': '',
        'token': '',
      },
    );
    final files = result['data'];
    final row = files is List && files.length == 1 ? files.first : null;
    final raw = row is Map && row['fid'] == fid ? row['download_url'] : null;
    final url = raw is String && raw.length <= 8192 ? Uri.tryParse(raw) : null;
    if (url == null ||
        url.scheme != 'https' ||
        url.port != 443 ||
        url.hasFragment ||
        url.userInfo.isNotEmpty ||
        !_cdn.hasMatch(url.host)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    return bindPublicationGuest(url, _origin, 'quark.cn', cookies);
  }

  Future<(Map, List<Cookie>)> _request(
    String path,
    CancellationToken token, {
    Map<String, String> query = const {},
    Map<String, Object?>? body,
  }) async {
    final endpoint = _api
        .resolve(path)
        .replace(queryParameters: {'pr': 'ucpro', 'fr': 'pc', ...query});
    final response = await http.open(
      endpoint,
      token,
      json: body,
      referer: _origin,
      redirect: false,
      interactive: true,
    );
    final status = response.response.statusCode;
    final mime = response.response.headers.contentType?.mimeType;
    // The API also uses HTTP 400 to carry structured guest-limit failures.
    final guestFailure =
        status == HttpStatus.badRequest && mime == 'application/json';
    if (status == HttpStatus.ok && mime == 'text/html') {
      await discardPublicationResponse(response);
      throw const PublicationFailure(PublicationProblem.challenge);
    }
    final text = await http.readText(
      response,
      token,
      maxBytes: 768 << 10,
      acceptedStatuses: guestFailure
          ? const {HttpStatus.badRequest}
          : const {HttpStatus.ok},
    );
    final Object? result = jsonDecode(text);
    if (result is! Map) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    if (guestFailure || result['code'] != 0 || result['status'] != 200) {
      throw _failure(result);
    }
    return (result, response.response.cookies);
  }

  PublicationFailure _failure(Map result) {
    final message = publicationLabel(result['message']).toLowerCase();
    final problem = switch ((result['code'], result['status'])) {
      (23018, _) => PublicationProblem.guestLimit,
      (31001, _) || (_, 401) => PublicationProblem.login,
      // Protected shares use business status 404 for both code errors.
      (41007 || 41008, _) => PublicationProblem.shareCode,
      (_, 404 || 410) => PublicationProblem.missing,
      (_, 429) => PublicationProblem.rateLimit,
      _ when message.contains('提取码') || message.contains('passcode') =>
        PublicationProblem.shareCode,
      _ when message.contains('验证码') || message.contains('captcha') =>
        PublicationProblem.challenge,
      (_, 403) => PublicationProblem.challenge,
      _ => PublicationProblem.unsupported,
    };
    return PublicationFailure(problem);
  }
}
