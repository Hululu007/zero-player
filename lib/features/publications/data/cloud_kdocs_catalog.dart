import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'cloud_resource_catalog.dart';
import 'publication_http.dart';
import 'publication_share_provider.dart';

Future<List<CloudResourceEntry>> readKdocsCloudCatalog(
  PublicationHttp http,
  Uri page,
  CancellationToken token,
) async {
  final share = page.pathSegments.last;
  final endpoint = Uri.https(page.host, '/api/v3/office/file/$share/open/db');
  final guest = GuestShareSession((target) => target.origin == page.origin);
  // The public viewer sets this marker when its optional single-sign-on
  // finishes without an account, then loads the read-only document.
  guest.receive(page, [
    Cookie('hadSingleSign', 'true')
      ..path = '/'
      ..secure = true,
  ]);
  final markup = await http.text(
    page,
    token,
    guest: guest,
    allowGzip: true,
    scope: (target) {
      if (target != page) {
        throw const PublicationFailure(PublicationProblem.login);
      }
    },
  );
  final session = await compute(_kdocsGuestSession, (markup, share));
  final response = await http.open(
    endpoint,
    token,
    guest: guest,
    referer: page,
    redirect: false,
    accept: 'application/octet-stream',
    scope: (target) {
      if (target != endpoint) {
        throw const PublicationFailure(PublicationProblem.unsupported);
      }
    },
    originHeaders: {
      'X-Csrf-Rand': session.csrf,
      'X-Forward-Region': session.region,
      'X-User-Query': page.query,
    },
    json: {
      'connid': session.connid,
      'group': session.group,
      'front_ver': session.version,
      'args': {
        'password': '',
        'readonly': true,
        'modifyPassword': '',
        'sync': true,
        'startVersion': 0,
        'endVersion': 0,
      },
      'ex_args': {
        'queryInitArgs': {
          'activeSheet': '坚持不付费！',
          'activeViewId': 'B',
          'cellLeftTop': {'row': 0, 'col': 0},
        },
      },
    },
  );
  final content = BytesBuilder(copy: false);
  if (response.response.statusCode != HttpStatus.ok ||
      response.response.headers.contentType?.mimeType !=
          'application/octet-stream') {
    await discardPublicationResponse(response);
    throw publicationHttpFailure(response);
  }
  await for (final part in response.body) {
    token.check();
    if (content.length + part.length > 4 << 20) {
      throw const FormatException('金山文档超过读取大小限制');
    }
    content.add(part);
  }
  token.check();
  return compute(parseKdocsCloudWorkbook, content.takeBytes());
}

typedef _KdocsSession = ({
  String csrf,
  String connid,
  String region,
  String group,
  String version,
});

_KdocsSession _kdocsGuestSession((String, String) input) {
  final (markup, share) = input;
  final script = html
      .parse(markup)
      .querySelectorAll('script')
      .where((item) => item.text.trimLeft().startsWith('window.__WPSENV__='))
      .firstOrNull
      ?.text
      .trimLeft();
  if (script == null) throw const FormatException('金山文档缺少访客会话');
  final start = 'window.__WPSENV__='.length;
  final end = RegExp(r';\s*window\.__WPSENV__\.').firstMatch(script)?.start;
  if (end == null) throw const FormatException('金山文档的访客会话格式已变更');
  final payload = jsonDecode(script.substring(start, end));
  if (payload
      case {
        'file_info': {
          'file': {
            'name': final String name,
            'attrs': {'link_range': 'anyone', 'link_id': final String id},
          },
        },
        'csrf_token': final String csrf,
        'conn_id': final String connid,
        'request_header_inject': {'x-forward-region': final String region},
        'user_group': final String group,
        'file_version': final String version,
      }
      when id == share &&
          name.endsWith('.dbt') &&
          [csrf, connid, region, group, version].every(_validValue)) {
    return (
      csrf: csrf,
      connid: connid,
      region: region,
      group: group,
      version: version,
    );
  }
  throw const FormatException('金山文档未返回可公开读取的表格');
}

bool _validValue(String value) =>
    RegExp(r'^[A-Za-z0-9._~/+=-]{1,256}$').hasMatch(value);

List<CloudResourceEntry> parseKdocsCloudWorkbook(Uint8List bytes) =>
    _KdocsWorkbook(bytes).read();

class _KdocsWorkbook {
  _KdocsWorkbook(this.bytes) : data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData data;
  final _fields = <String, int>{};

  List<CloudResourceEntry> read() {
    final start = _readFields();
    final row = _key('blockRowIndex');
    final previous = _key('prevStep');
    final cells = _key('cells');
    final boundaries = <int>[];
    for (var i = start; i + 10 <= bytes.length; i++) {
      if (_u16(i) == row && _u16(i + 4) == previous && _u16(i + 8) == cells) {
        boundaries.add(i);
      }
    }
    if (boundaries.isEmpty || boundaries.length > 5000) {
      throw const FormatException('金山文档工作簿缺少有效行');
    }
    final rows = <CloudResourceEntry>[];
    var handles = 0;
    final limit = [...boundaries.skip(1), bytes.length];
    for (final (index, from) in boundaries.indexed) {
      handles += _readRow(from + 10, limit[index], rows);
    }
    if (handles == 0 || handles != _countHyperlinks(start) || rows.isEmpty) {
      throw const FormatException('金山文档未返回完整的分享行');
    }
    return rows;
  }

  int _readFields() {
    if (bytes.length < 2) throw const FormatException('金山文档工作簿为空');
    final count = _u16(0);
    if (count == 0 || count > 4096) throw const FormatException('工作簿字段无效');
    var i = 2;
    for (var id = 1; id <= count; id++) {
      if (i + 5 > bytes.length || _u16(i) != id) {
        throw const FormatException('工作簿字段索引无效');
      }
      final length = bytes[i + 2];
      if (i + 5 + length > bytes.length) {
        throw const FormatException('工作簿字段不完整');
      }
      _fields.putIfAbsent(
        utf8.decode(bytes.sublist(i + 3, i + 3 + length)),
        () => id,
      );
      i += length + 5;
    }
    return i;
  }

  int _readRow(int from, int end, List<CloudResourceEntry> rows) {
    final textToken = _key('ExecTokenSTR');
    final str = _key('str');
    final afterText = _key('isSqLeading');
    var title = '';
    var handles = 0;
    for (var i = from; i + 10 < end; i++) {
      if (title.isEmpty && _u16(i) == textToken && _u16(i + 8) == str) {
        final text = _text(i + 10, end);
        if (text != null &&
            text.next + 2 <= end &&
            _u16(text.next) == afterText) {
          title = publicationLabel(text.value, max: 512);
        }
      }
      if (!_hyperlinkAt(i, end)) continue;
      handles++;
      final link = _readLink(i + _hyperlink.length, end);
      if (title.isEmpty || link == null) {
        throw const FormatException('金山文档的分享行缺少名称或地址');
      }
      if (PublicationShareProvider.of(link) !=
          PublicationShareProvider.direct) {
        rows.add(CloudResourceEntry(title, link, const []));
      }
    }
    return handles;
  }

  Uri? _readLink(int offset, int end) {
    if (offset + 4 > end ||
        _u16(offset) != _key('handle') ||
        _u16(offset + 2) != _key('displayText')) {
      return null;
    }
    final label = _text(offset + 4, end);
    if (label == null ||
        label.next + 2 > end ||
        _u16(label.next) != _key('address')) {
      return null;
    }
    final address = _text(label.next + 2, end);
    final link = address == null ? null : Uri.tryParse(address.value);
    if (link == null ||
        link.scheme != 'https' ||
        link.port != 443 ||
        link.userInfo.isNotEmpty ||
        link.host.isEmpty) {
      return null;
    }
    return link;
  }

  ({String value, int next})? _text(int offset, int end) {
    if (offset + 4 > end) return null;
    final length = data.getUint32(offset, Endian.little);
    final start = offset + 4;
    final next = start + length * 2;
    if (length > 2048 || next > end) return null;
    return (
      value: String.fromCharCodes([
        for (var i = start; i < next; i += 2) _u16(i),
      ]),
      next: next,
    );
  }

  static final _hyperlink = [
    for (final code in 'ET_HANDLE_DBHYPERLINK'.codeUnits) ...[code, 0],
  ];

  bool _hyperlinkAt(int offset, int end) {
    if (offset + _hyperlink.length > end || bytes[offset] != _hyperlink.first) {
      return false;
    }
    for (var i = 1; i < _hyperlink.length; i++) {
      if (bytes[offset + i] != _hyperlink[i]) return false;
    }
    return true;
  }

  int _countHyperlinks(int start) {
    var count = 0;
    for (var i = start; i < bytes.length; i++) {
      if (_hyperlinkAt(i, bytes.length)) count++;
    }
    return count;
  }

  int _key(String name) =>
      _fields[name] ?? (throw const FormatException('工作簿缺少必要字段'));

  int _u16(int offset) => data.getUint16(offset, Endian.little);
}
