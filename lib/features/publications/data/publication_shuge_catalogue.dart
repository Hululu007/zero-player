import 'dart:convert';

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';

const shugeSource = 'shuge-open';
final shugeCatalogueEndpoint = Uri.https('api.shuge.org', '/query/');
final _resourceId = RegExp(r'^(?:SJ|ZH)[0-9]{8}$');
final _shortId = RegExp(r'^[A-Za-z0-9_-]{1,40}$');
final _shareId = RegExp(r'^[A-Za-z0-9_-]{4,40}$');
final _landingPath = RegExp(r'^/dl/(?:[0-9]{1,2}/)?$');
final _licence = RegExp(
  r'^(?:CC0(?: 1\.0)?|CC BY(?:-SA|-ND|-NC(?:-SA|-ND)?)? (?:2\.0|2\.5|3\.0|4\.0)|公共领域|Public Domain(?: Mark 1\.0)?)$',
  caseSensitive: false,
);

typedef ShugeRecord = ({
  String id,
  String title,
  String author,
  String edition,
  String licence,
  Uri page,
  Uri? share,
});
typedef ShugeStorageShare = ({String host, String id});
typedef _ShugeFile = ({
  Uri link,
  String name,
  int size,
  PublicationFormat format,
});

final class ShugeCatalogue implements DownloadablePublicationCatalogue {
  const ShugeCatalogue(this.http);
  final PublicationHttp http;

  @override
  Future<void> check(CancellationToken token) async {
    await _page('', 1, token, limit: 1);
  }

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
  }) async {
    final result = <PublicationEdition>[];
    final seen = <String>{};
    var remainingChecks = 6;
    for (var index = 1; index <= maxPages; index++) {
      final page = await _page(query, index, token);
      for (final row in page.items) {
        token.check();
        final record = shugeRecord(row);
        if (record == null ||
            filter?.matchesFields(title: record.title, author: record.author) ==
                false ||
            !allowed('${record.title} ${record.author}') ||
            !seen.add(record.id)) {
          continue;
        }
        List<_ShugeFile> files = const [];
        if (record.share != null && remainingChecks > 0) {
          remainingChecks--;
          try {
            files = await _files(record, token);
          } on RequestCancelled {
            rethrow;
          } on Exception {
            // The official book page remains useful if its storage is offline.
          }
        }
        if (files.isEmpty) {
          result.add(_edition(record));
        } else {
          result.addAll(files.map((file) => _edition(record, file)));
        }
      }
      if (!page.hasNext || page.items.isEmpty) break;
    }
    return result;
  }

  @override
  Future<PublicationDownload> download(
    AcquisitionCandidate candidate,
    CancellationToken token,
  ) async {
    final id = candidate.fileId;
    if (id == null || !_resourceId.hasMatch(id)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final path = '/api/$id.json';
    final raw = await http.text(
      Uri.https('api.shuge.org', path),
      token,
      maxBytes: 256 << 10,
      scope: (uri) => _apiScope(uri, path),
    );
    final book = shugeRecord(jsonDecode(raw));
    if (book == null ||
        book.id != id ||
        book.share == null ||
        book.page != candidate.page) {
      throw const PublicationFailure(PublicationProblem.missing);
    }
    final files = await _files(book, token);
    final file = files
        .where(
          (item) =>
              item.link == candidate.link &&
              item.size == candidate.bytes &&
              item.format == candidate.format &&
              item.name == candidate.sharedFileName,
        )
        .firstOrNull;
    if (file == null) {
      throw const PublicationFailure(PublicationProblem.missing);
    }
    return PublicationDownload(
      file.link,
      scope: (target) {
        if (target != file.link) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
    );
  }

  Future<({List items, bool hasNext})> _page(
    String query,
    int page,
    CancellationToken token, {
    int limit = 12,
  }) async {
    final endpoint = shugeCatalogueEndpoint.replace(
      queryParameters: {
        if (query.isNotEmpty) 'q': query,
        'view': 'full',
        'page': '$page',
        'per_page': '$limit',
      },
    );
    final data = jsonDecode(
      await http.text(
        endpoint,
        token,
        maxBytes: 512 << 10,
        scope: (uri) => _apiScope(uri, '/query/'),
      ),
    );
    if (data case {
      'success': true,
      'items': final List items,
      'pagination': {'page': final int current, 'has_next': final bool more},
    } when current == page && items.length <= limit) {
      return (items: items, hasNext: more);
    }
    throw const PublicationFailure(PublicationProblem.invalid);
  }

  Future<List<_ShugeFile>> _files(
    ShugeRecord item,
    CancellationToken token,
  ) async {
    final reference = item.share;
    if (reference == null) return const [];
    final response = await http.open(
      reference,
      token,
      scope: (uri) {
        if (uri == reference || _isLanding(uri)) return;
        throw const PublicationFailure(PublicationProblem.unsupported);
      },
    );
    final choices = response.response.statusCode == 200
        ? shugeStorageShares(response.uri)
        : const <ShugeStorageShare>[];
    final failure = response.response.statusCode != 200
        ? publicationHttpFailure(response)
        : null;
    await discardPublicationResponse(response);
    if (failure != null) throw failure;
    for (final share in choices) {
      token.check();
      try {
        final files = await _storageFiles(share, token);
        if (files.isNotEmpty) return files;
      } on RequestCancelled {
        rethrow;
      } on PublicationFailure catch (error) {
        // A challenge, login, or limit applies to this published link.
        if (error.problem != PublicationProblem.missing &&
            error.problem != PublicationProblem.unsupported) {
          rethrow;
        }
      }
    }
    return const [];
  }

  Future<List<_ShugeFile>> _storageFiles(
    ShugeStorageShare share,
    CancellationToken token,
  ) async {
    final info = await _storage(share, 'get', token);
    if (info['is_dir'] == false) {
      final file = _file(share, info);
      return [?file];
    }
    if (info['is_dir'] != true) return const [];
    final data = await _storage(share, 'list', token);
    final entries = data['content'];
    if (entries is! List || entries.length > 20) return const [];
    final names = {
      for (final row in entries)
        if (row is Map && row['is_dir'] == false && _bookFileName(row['name']))
          row['name'] as String,
    };
    final files = <_ShugeFile>[];
    for (final name in names.take(4)) {
      final file = _file(
        share,
        await _storage(share, 'get', token, name: name),
        child: name,
      );
      if (file != null) files.add(file);
    }
    return files;
  }

  Future<Map> _storage(
    ShugeStorageShare share,
    String method,
    CancellationToken token, {
    String? name,
  }) async {
    final endpoint = Uri.https(share.host, '/api/fs/$method');
    final child = name == null ? '' : '/$name';
    final path = '/@s/${share.id}$child';
    void scope(Uri uri) {
      if (uri != endpoint) {
        throw const PublicationFailure(PublicationProblem.unsupported);
      }
    }

    final payload = await http.open(
      endpoint,
      token,
      json: {
        'path': path,
        'password': '',
        if (method == 'list') ...{'page': 1, 'per_page': 20, 'refresh': false},
      },
      scope: scope,
      redirect: false,
      interactive: true,
    );
    final raw = jsonDecode(
      await http.readText(payload, token, maxBytes: 256 << 10, scope: scope),
    );
    if (raw case {'code': 200, 'data': final Map result}) return result;
    if (raw case {'code': 401 || 403}) {
      throw const PublicationFailure(PublicationProblem.login);
    }
    if (raw case {'code': 429}) {
      throw const PublicationFailure(PublicationProblem.rateLimit);
    }
    throw const PublicationFailure(PublicationProblem.missing);
  }

  static void _apiScope(Uri uri, String path) {
    if (!_publicHttps(uri) || uri.host != 'api.shuge.org' || uri.path != path) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
  }
}

ShugeRecord? shugeRecord(Object? value) {
  if (value case {
    'resource_id': final String id,
    'resource_type': '书籍' || '字画',
    'resource_name': final String rawTitle,
    'intro_url': final String url,
  } when _resourceId.hasMatch(id)) {
    final row = value as Map;
    final page = Uri.tryParse(url);
    final title = publicationLabel(rawTitle);
    if (page == null ||
        !_publicHttps(page) ||
        page.host != 'www.shuge.org' ||
        page.hasQuery ||
        !RegExp(r'^/view/[A-Za-z0-9_-]+/$').hasMatch(page.path) ||
        title.isEmpty) {
      return null;
    }
    final licence = publicationLabel(row['license']);
    final responsibility = row['responsibility'];
    final authors = responsibility is List
        ? responsibility
              .whereType<Map>()
              .map((person) => publicationLabel(person['name']))
              .where((person) => person.isNotEmpty)
              .take(4)
              .join('、')
        : '';
    final raw = row['download_url'];
    final link = raw is String ? Uri.tryParse(raw) : null;
    final share =
        _licence.hasMatch(licence) &&
            link != null &&
            _publicHttps(link) &&
            link.host == 's.shuge.org' &&
            !link.hasQuery &&
            link.pathSegments.length == 1 &&
            _shortId.hasMatch(link.pathSegments.first)
        ? link
        : null;
    return (
      id: id,
      title: title,
      author: authors,
      edition: publicationLabel(row['edition_info']),
      licence: licence,
      page: page,
      share: share,
    );
  }
  return null;
}

List<ShugeStorageShare> shugeStorageShares(Uri uri) {
  if (!_isLanding(uri)) return const [];
  return [
    for (final (key, host) in const [
      ('sj', 'du.shuge.org'),
      ('yun', 'yun.shuge.org'),
    ])
      if (uri.queryParametersAll[key]?.singleOrNull case final String id
          when _shareId.hasMatch(id))
        (host: host, id: id),
  ];
}

bool _isLanding(Uri target) =>
    _publicHttps(target) &&
    target.host == 'f.shuge.org' &&
    _landingPath.hasMatch(target.path);
bool _publicHttps(Uri uri) =>
    uri.scheme == 'https' &&
    uri.port == 443 &&
    uri.userInfo.isEmpty &&
    !uri.hasFragment;

bool _bookFileName(Object? raw) =>
    raw is String &&
    raw.isNotEmpty &&
    raw.length <= 250 &&
    !RegExp(r'[/\\\x00-\x1f\x7f]').hasMatch(raw) &&
    const {
      PublicationFormat.pdf,
      PublicationFormat.epub,
    }.contains(PublicationFormat.fromName(raw));

_ShugeFile? _file(ShugeStorageShare share, Map info, {String? child}) {
  final name = info['name'];
  final size = info['size'];
  final raw = info['raw_url'];
  if (info['is_dir'] != false ||
      !_bookFileName(name) ||
      size is! int ||
      size <= 0 ||
      raw is! String) {
    return null;
  }
  final format = PublicationFormat.fromName(name as String)!;
  if (size > format.maxBytes || (child != null && child != name)) return null;
  final url = Uri.tryParse(raw);
  final parts = url?.pathSegments;
  if (url == null ||
      !_publicHttps(url) ||
      url.hasQuery ||
      url.host != share.host ||
      parts == null ||
      parts.length != 3 ||
      parts.first != 'sd' ||
      parts[1] != share.id ||
      parts.last != (child ?? '')) {
    return null;
  }
  return (link: url, name: name, size: size, format: format);
}

PublicationEdition _edition(ShugeRecord item, [_ShugeFile? file]) =>
    PublicationEdition(
      id: publicationId('shuge:${item.id}\n${file?.name ?? ''}'),
      title: item.title,
      author: item.author,
      language: '中文',
      edition: file?.name ?? item.edition,
      license: item.licence,
      page: item.page,
      candidates: [
        if (file != null)
          AcquisitionCandidate(
            source: shugeSource,
            link: file.link,
            page: item.page,
            format: file.format,
            bytes: file.size,
            fileId: item.id,
            sharedFileName: file.name,
          ),
      ],
    );
