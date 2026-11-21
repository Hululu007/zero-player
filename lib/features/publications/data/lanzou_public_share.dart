import 'dart:async';
import 'dart:convert';

import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_http.dart';
import 'publication_share_provider.dart';

typedef LanzouFile = ({String name, String? id, Uri address});

/// Recognizes only the data fields of public sharing forms. Page script is
/// never evaluated. Account/verification flows have no counterpart here.
final class LanzouPublicShare {
  LanzouPublicShare(this.http);
  final PublicationHttp http;

  Future<List<LanzouFile>> inspect(
    Uri link,
    String? code,
    CancellationToken token,
  ) => _inspect(
    link,
    code,
    token,
    GuestShareSession((uri) => uri.host == link.host),
  );

  Future<List<LanzouFile>> _inspect(
    Uri link,
    String? code,
    CancellationToken token,
    GuestShareSession guest, {
    String? requested,
  }) async {
    final content = await _page(link, token, guest);
    if (content.contains('filemoreajax.php')) {
      return _members(link, content, code, token, guest, requested: requested);
    }
    final doc = html.parse(content);
    final title = publicationLabel(
      doc.querySelector('#filenajax,.n_box_3fn,.filethetext')?.text ??
          doc.querySelector('title')?.text,
    );
    if (title.isEmpty ||
        (!content.contains('downprocess') &&
            doc.querySelector('iframe[src]') == null)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    if (_needsCode(content) && (code == null || code.isEmpty)) {
      throw const PublicationFailure(PublicationProblem.shareCode);
    }
    return [(name: title, id: null, address: link)];
  }

  Future<List<LanzouFile>> _members(
    Uri link,
    String page,
    String? code,
    CancellationToken token,
    GuestShareSession guest, {
    String? requested,
  }) async {
    if (_needsCode(page) && (code == null || code.isEmpty)) {
      throw const PublicationFailure(PublicationProblem.shareCode);
    }
    final endpoint = _endpoint(link, page, 'filemoreajax');
    final required = [
      for (final key in ['lx', 'fid', 't', 'k']) (key, _value(page, key)),
    ];
    if (required.any((field) => field.$2 == null)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final files = <String, LanzouFile>{};
    for (var index = 1; index <= 8; index++) {
      token.check();
      if (index > 1) {
        await Future<void>.delayed(const Duration(milliseconds: 650));
      }
      final list = await _post(endpoint, link, token, guest, {
        for (final (key, value) in required) key: value!,
        'pg': '$index',
        'pwd': code ?? '',
      });
      final status = int.tryParse('${list['zt']}');
      final items = list['text'];
      if (status == 2 || (items is List && items.isEmpty)) break;
      if (status == 3) {
        throw const PublicationFailure(PublicationProblem.shareCode);
      }
      if (status == 4) {
        if (files.isNotEmpty) break;
        throw const PublicationFailure(PublicationProblem.rateLimit);
      }
      if (status != 1 || items is! List) {
        throw const PublicationFailure(PublicationProblem.unsupported);
      }
      final startCount = files.length;
      for (final item in items.take(128).whereType<Map>()) {
        final name = publicationLabel(item['name_all'] ?? item['name']);
        final ref = item['id'];
        if (name.isEmpty ||
            ref is! String ||
            ref.length > 2048 ||
            !RegExp(r'^i[A-Za-z0-9]{4,60}(?:\?[^#\s]*)?$').hasMatch(ref)) {
          continue;
        }
        final address = link.resolve('/$ref');
        final id = address.path.substring(1);
        files.putIfAbsent(id, () => (name: name, id: id, address: address));
      }
      if (files.containsKey(requested) ||
          files.length == startCount ||
          files.length >= 128) {
        break;
      }
    }
    return files.values.toList(growable: false);
  }

  Future<PublicationDownload> resolve(
    AcquisitionCandidate candidate,
    String? code,
    CancellationToken token,
  ) async {
    final guest = GuestShareSession((uri) => uri.host == candidate.link.host);
    final files = await _inspect(
      candidate.link,
      code,
      token,
      guest,
      requested: candidate.fileId,
    );
    final selected = files
        .where((file) => file.id == candidate.fileId)
        .firstOrNull;
    if (selected == null) {
      throw const PublicationFailure(PublicationProblem.missing);
    }
    if (PublicationFormat.fromName(selected.name) != candidate.format ||
        (candidate.sharedFileName != null &&
            selected.name != candidate.sharedFileName)) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    return resolveFile(selected, code, token, guest: guest);
  }

  Future<PublicationDownload> resolveFile(
    LanzouFile file,
    String? code,
    CancellationToken token, {
    GuestShareSession? guest,
  }) async {
    var referer = file.address;
    final session =
        guest ?? GuestShareSession((uri) => uri.host == referer.host);
    var page = await _page(referer, token, session);
    final needsCode = _needsCode(page);
    final iframe = html
        .parse(page)
        .querySelector('iframe[src]')
        ?.attributes['src'];
    if (!needsCode && iframe != null && iframe.isNotEmpty) {
      final framed = referer.resolve(iframe);
      _scope(referer, framed);
      page = await _page(framed, token, session, referer: referer);
      referer = framed;
    }
    final endpoint = _endpoint(referer, page, '(?:ajaxm|ajaxfile)');
    final sign = _value(page, 'sign') ?? _value(page, 'wp_sign');
    if (sign == null) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final protected = needsCode || _needsCode(page);
    if (protected && (code == null || code.isEmpty)) {
      throw const PublicationFailure(PublicationProblem.shareCode);
    }
    final key = _value(page, 'websignkey') ?? _value(page, 'ajaxdata');
    if (!protected && key == null) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final result = await _post(endpoint, referer, token, session, {
      'action': 'downprocess',
      'sign': sign,
      'kd': '1',
      if (protected)
        'p': code!
      else ...{
        'websignkey': key!,
        'websign': _value(page, 'websign') ?? '',
        'ves': '1',
        if (_value(page, 'signs') ?? _value(page, 'ajaxdata')
            case final String signs)
          'signs': signs,
      },
    });
    return _download(result, referer, protected, session);
  }

  PublicationDownload _download(
    Map result,
    Uri referer,
    bool protected,
    GuestShareSession guest,
  ) {
    final status = int.tryParse('${result['zt']}');
    if (status != 1) {
      throw PublicationFailure(switch (status) {
        3 when protected => PublicationProblem.shareCode,
        4 => PublicationProblem.rateLimit,
        _ => PublicationProblem.unsupported,
      });
    }
    final origin = Uri.tryParse(
      result['dom'] is String ? result['dom'] as String : '',
    );
    final path = result['url'];
    if (origin == null ||
        !_downloadOrigin(origin) ||
        path is! String ||
        path.length > 2048 ||
        path.isEmpty ||
        !RegExp(r'^[A-Za-z0-9_%.~/-]*(?:\?[^#\s]+)?$').hasMatch(path) ||
        path.startsWith('/') ||
        Uri.decodeComponent(path.split('?').first)
            .split('/')
            .any(
              (segment) =>
                  segment == '.' || segment == '..' || segment.contains('\\'),
            )) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    return PublicationDownload(
      origin.resolve('/file/$path'),
      guest: guest.freeze(),
      referer: referer,
      scope: (target) {
        if (!_downloadOrigin(target)) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
    );
  }

  Future<String> _page(
    Uri uri,
    CancellationToken token,
    GuestShareSession session, {
    Uri? referer,
  }) async {
    final page = await http.text(
      uri,
      token,
      scope: (target) => _scope(uri, target),
      guest: session,
      referer: referer,
    );
    if (RegExp(
      r'<(?:input|img)[^>]+(?:captcha|verifycode)',
      caseSensitive: false,
    ).hasMatch(page)) {
      throw const PublicationFailure(PublicationProblem.challenge);
    }
    if (page.contains('分享已取消') || page.contains('文件不存在')) {
      throw const PublicationFailure(PublicationProblem.missing);
    }
    return page;
  }

  Future<Map> _post(
    Uri endpoint,
    Uri referer,
    CancellationToken token,
    GuestShareSession guest,
    Map<String, String> fields,
  ) async {
    final value = await http.text(
      endpoint,
      token,
      guest: guest,
      referer: referer,
      form: fields,
      maxBytes: 256 << 10,
      scope: (target) => _scope(referer, target, api: true),
    );
    final parsed = jsonDecode(value);
    if (parsed is! Map) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    return parsed;
  }

  bool _needsCode(String page) => RegExp(
    r'''(?:name|id)=["'](?:pwd|pwbox)["']|function\s+down_p\(''',
  ).hasMatch(page);

  Uri _endpoint(Uri base, String source, String script) {
    final field = RegExp(
      '''["']([^"'\\s]*$script\\.php(?:\\?file=\\d+)?)['"]''',
    ).firstMatch(source)?[1];
    if (field == null) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final result = base.resolve(field);
    _scope(base, result, api: true);
    return result;
  }

  String? _value(String page, String name) {
    final field = RegExp(
      '''(?:["']?$name["']?\\s*:\\s*|(?:var|let|const)\\s+$name\\s*=\\s*)(?:["']([!-~]{0,512}?)["']|(\\w{1,64}))''',
    ).firstMatch(page);
    if (field == null) return null;
    if (field[1] != null) return field[1];
    final value = field[2]!;
    if (RegExp(r'^\d+$').hasMatch(value)) return value;
    return RegExp(
      '''(?:var|let|const)\\s+$value\\s*=\\s*(?:['"]([!-~]{1,512}?)['"]|(\\d{1,20}))''',
    ).firstMatch(page)?.groups([1, 2]).whereType<String>().firstOrNull;
  }

  bool _downloadOrigin(Uri uri) =>
      uri.scheme == 'https' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      (isLanzouShare(uri) ||
          hostIn(uri, 'woozooo.com') ||
          hostIn(uri, 'lanzn.com') ||
          hostIn(uri, 'lanrar.com') ||
          hostIn(uri, 'bakstotre.com'));

  void _scope(Uri base, Uri target, {bool api = false}) {
    if (target.scheme != 'https' ||
        target.port != 443 ||
        (base.origin != target.origin &&
            !(api && target.host == 'apifile.woozooo.com'))) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
  }
}
