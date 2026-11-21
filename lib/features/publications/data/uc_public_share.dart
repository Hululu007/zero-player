import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_http.dart';

final class UcPublicShare {
  UcPublicShare(this.http);

  final PublicationHttp http;
  static final _shareOrigin = Uri.https('drive.uc.cn', '/');
  static final _identifier = RegExp(r'^[A-Za-z0-9_-]{1,80}$');
  static const _pageSize = 30;
  static const _maxPages = 8;
  static const _directoryRequests = 20;

  Future<List<PublicationSharedFile>> inspect(
    Uri link,
    String? code,
    CancellationToken token,
  ) async {
    final share = _shareId(link);
    final ticket = await _ticket(share, code, token);
    final pending = Queue.of([('0', 1)]);
    final folders = {'0'};
    final files = <String, PublicationSharedFile>{};
    for (
      var request = 0;
      request < _directoryRequests && pending.isNotEmpty;
      request++
    ) {
      final (parent, number) = pending.removeFirst();
      final rows = await _page(share, ticket, parent, number, token);
      for (final row in rows) {
        final id = row['fid'];
        if (id is! String || !_identifier.hasMatch(id)) continue;
        if (row['dir'] == true) {
          if (folders.length < _directoryRequests && folders.add(id)) {
            pending.add((id, 1));
          }
        } else if (_book(row, parent, id) case final file?) {
          files.putIfAbsent('$parent:$id', () => file);
        }
      }
      if (rows.length == _pageSize && number < _maxPages) {
        pending.add((parent, number + 1));
      }
    }
    return files.values.toList(growable: false);
  }

  Future<PublicationDownload> resolve(
    AcquisitionCandidate candidate,
    String? code,
    CancellationToken token,
  ) async {
    final parts = candidate.fileId?.split(':');
    if (parts == null ||
        parts.length != 2 ||
        parts.any((part) => !_identifier.hasMatch(part))) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final share = _shareId(candidate.link);
    final ticket = await _ticket(share, code, token);
    final parent = parts[0];
    final id = parts[1];
    for (var number = 1; number <= _maxPages; number++) {
      final rows = await _page(share, ticket, parent, number, token);
      final row = rows.where((row) => row['fid'] == id).firstOrNull;
      if (row != null) {
        final file = _book(row, parent, id);
        final fileToken = _boundedToken(row['share_fid_token']);
        if (file == null ||
            !candidate.matchesSharedFile(file) ||
            fileToken == null) {
          throw const PublicationFailure(PublicationProblem.invalid);
        }
        return _download(share, ticket, id, fileToken, token);
      }
      if (rows.length < _pageSize) break;
    }
    throw const PublicationFailure(PublicationProblem.missing);
  }

  PublicationSharedFile? _book(Map row, String parent, String id) {
    final name = publicationLabel(row['file_name']);
    final format = PublicationFormat.fromName(name);
    final size = row['size'];
    if (row['dir'] != false ||
        format == null ||
        size is! int ||
        size <= 0 ||
        size > format.maxBytes) {
      return null;
    }
    return (name: name, id: '$parent:$id', format: format, bytes: size);
  }

  String _shareId(Uri link) {
    final path = link.pathSegments;
    if (link.origin != _shareOrigin.origin ||
        path.length != 2 ||
        path.first != 's' ||
        !_identifier.hasMatch(path.last)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    return path.last;
  }

  String? _boundedToken(Object? value) =>
      value is String && value.isNotEmpty && value.length <= 2048
      ? value
      : null;

  Future<String> _ticket(
    String share,
    String? code,
    CancellationToken token,
  ) async {
    final (result, _) = await _request(
      'share/sharepage/token',
      token,
      body: {
        'pwd_id': share,
        'passcode': code ?? '',
        'share_for_transfer': true,
      },
    );
    final data = result['data'];
    final ticket = data is Map ? _boundedToken(data['stoken']) : null;
    if (ticket != null) return ticket;
    throw PublicationFailure(
      data is Map && data['need_passcode'] == true
          ? PublicationProblem.shareCode
          : PublicationProblem.invalid,
    );
  }

  Future<List<Map>> _page(
    String share,
    String ticket,
    String parent,
    int number,
    CancellationToken token,
  ) async {
    final (result, _) = await _request(
      'transfer_share/detail',
      token,
      query: {
        'entry': 'ft',
        'pwd_id': share,
        'pdir_fid': parent,
        'stoken': ticket,
        'fetch_file_list': '1',
        'passcode': '',
        '_page': '$number',
        '_size': '$_pageSize',
        '_fetch_total': '1',
        '_fetch_task': '1',
        '_fetch_share': '1',
        '_sort': '',
      },
    );
    final data = result['data'];
    final detail = data is Map ? data['detail_info'] : null;
    final rows =
        (data is Map ? data['list'] : null) ??
        (detail is Map ? detail['list'] : null);
    if (rows is! List || rows.length > _pageSize) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    return rows.whereType<Map>().toList(growable: false);
  }

  Future<PublicationDownload> _download(
    String share,
    String ticket,
    String id,
    String fileToken,
    CancellationToken token,
  ) async {
    final (result, cookies) = await _request(
      'file/download',
      token,
      query: {'entry': 'ft'},
      body: {
        'pwd_id': share,
        'stoken': ticket,
        'fids': [id],
        'fids_token': [fileToken],
      },
    );
    final files = result['data'];
    final row = files is List && files.length == 1 ? files.single : null;
    final raw = row is Map && row['fid'] == id ? row['download_url'] : null;
    final address = raw is String && raw.length <= 8192
        ? Uri.tryParse(raw)
        : null;
    if (address == null ||
        address.scheme != 'https' ||
        address.host != 'dl-uf-zb.pds.uc.cn' ||
        address.port != 443 ||
        address.userInfo.isNotEmpty ||
        address.hasFragment) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    return bindPublicationGuest(address, _shareOrigin, 'uc.cn', cookies);
  }

  Future<(Map, List<Cookie>)> _request(
    String endpoint,
    CancellationToken token, {
    Map<String, String> query = const {},
    Map<String, Object?>? body,
  }) async {
    final address = Uri.https('pc-api.uc.cn', '/1/clouddrive/$endpoint', {
      'pr': 'UCBrowser',
      'fr': 'pc',
      ...query,
    });
    final response = await http.open(
      address,
      token,
      json: body,
      referer: _shareOrigin,
      redirect: false,
      interactive: true,
    );
    final status = response.response.statusCode;
    final mime = response.response.headers.contentType?.mimeType;
    if (mime != 'application/json') {
      await discardPublicationResponse(response);
      if (mime == 'text/html' && status == HttpStatus.ok) {
        throw const PublicationFailure(PublicationProblem.challenge);
      }
      throw publicationHttpFailure(response);
    }
    final text = await http.readText(
      response,
      token,
      maxBytes: 512 << 10,
      acceptedStatuses: const {200, 400, 401, 403, 404, 410},
    );
    final Object? result = jsonDecode(text);
    if (result is! Map) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    if (status != HttpStatus.ok ||
        result['code'] != 0 ||
        result['status'] != 200) {
      throw _failure(result, status);
    }
    return (result, response.response.cookies);
  }

  PublicationFailure _failure(Map data, int status) {
    final message = publicationLabel(data['message']).toLowerCase();
    return PublicationFailure(switch ((data['code'], status)) {
      (23018, _) => PublicationProblem.guestLimit,
      (31001, _) || (_, 401) => PublicationProblem.login,
      (14001 || 14013 || 41020, _) ||
      (_, 404 || 410) => PublicationProblem.missing,
      _ when message.contains('提取码') || message.contains('passcode') =>
        PublicationProblem.shareCode,
      _ when message.contains('验证码') || message.contains('captcha') =>
        PublicationProblem.challenge,
      (_, 403) => PublicationProblem.challenge,
      _ => PublicationProblem.unsupported,
    });
  }
}
