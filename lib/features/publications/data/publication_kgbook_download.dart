import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_http.dart';
import 'publication_kgbook_rows.dart';

final class KgbookDownloads {
  KgbookDownloads(this.http);
  final PublicationHttp http;
  final _recent =
      <Uri, ({Map<PublicationFormat, Uri> links, DateTime expires})>{};
  Future<Map<String, Object?>>? _verifiedEntries;

  Future<List<PublicationResource>> resources(
    Uri page,
    CancellationToken token,
  ) async => [
    for (final format in (await _links(page, token)).keys)
      PublicationResource(
        source: kgbookSource,
        link: page,
        label: '下载 ${format.label}',
        format: format,
      ),
  ];

  Future<PublicationDownload> resolve(
    AcquisitionCandidate candidate,
    CancellationToken token,
  ) async {
    final page = candidate.link;
    if (candidate.source != kgbookSource ||
        candidate.page != page ||
        candidate.fileId != null) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final format = candidate.format;
    final link = (await _links(page, token))[format];
    if (link == null) {
      throw const PublicationFailure(PublicationProblem.noPublishedResources);
    }
    return PublicationDownload(
      link,
      referer: page,
      detectGuestQuota: true,
      preferWhole: true,
      rangeChunkBytes: 256 << 10,
      rangeTarget: (uri) => _file(uri, format),
      mapRedirect: _fileRedirect,
      scope: (uri) {
        final sameEntry =
            _entryPaths.contains(link.path) &&
            _entryPaths.contains(uri.path) &&
            uri.queryParametersAll.entries.length == 3 &&
            uri.query == link.query;
        if (!kgbookHost(uri) ||
            uri.host != link.host ||
            uri.hasFragment ||
            !(uri == link || sameEntry || _file(uri, format))) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
    );
  }

  Future<Map<PublicationFormat, Uri>> _links(
    Uri page,
    CancellationToken token,
  ) async {
    final book = kgbookBookNumber(page);
    if (book == null) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    token.check();
    http.authorize(page);
    final recent = _recent.remove(page);
    if (recent != null && recent.expires.isAfter(DateTime.now())) {
      _recent[page] = recent;
      return recent.links;
    }
    final known = await _verifiedLinks(page, book);
    token.check();
    if (known.isNotEmpty) return known;
    void restrict(Uri uri) {
      if (!kgbookPublicAddress(uri) || uri.path != page.path) {
        throw const PublicationFailure(PublicationProblem.unsupported);
      }
    }

    Future<Map<PublicationFormat, Uri>> load(Uri address) =>
        withPublicationRequestDeadline(token, const Duration(seconds: 12), (
          request,
        ) async {
          final response = await http.open(
            address,
            request,
            scope: restrict,
            interactive: true,
            acceptGzip: true,
          );
          final body = await http.readText(
            response,
            request,
            maxBytes: 384 << 10,
            scope: restrict,
            allowGzip: true,
          );
          final links = parseKgbookDownloadLinks(body, response.uri, book);
          final expires = kgbookFreshUntil(
            response.response.headers,
            DateTime.now(),
          );
          if (links.isNotEmpty && expires != null) {
            _recent[page] = (links: links, expires: expires);
            if (_recent.length > 24) _recent.remove(_recent.keys.first);
          }
          return links;
        });
    try {
      return await load(page);
    } on Exception catch (error) {
      if (!isPublicationNetworkFailure(error)) rethrow;
      final alias = page.host == 'kgbook.com' ? 'www.kgbook.com' : 'kgbook.com';
      return load(page.replace(host: alias));
    }
  }

  Future<Map<PublicationFormat, Uri>> _verifiedLinks(
    Uri page,
    String book,
  ) async {
    final entries = (await (_verifiedEntries ??=
        _loadVerifiedEntries()))[page.path];
    if (entries is! Map) return const {};
    final canonical = Uri.https('kgbook.com', page.path);
    return {
      for (final format in PublicationFormat.values)
        if (entries[format.name] case final String published)
          if (canonical.resolve(published) case final Uri link
              when kgbookHost(link) && !link.hasFragment && _entry(link, book))
            format: link,
    };
  }

  Future<Map<String, Object?>> _loadVerifiedEntries() async {
    final json = await rootBundle.loadString(
      'assets/catalogs/books/kgbook-entries.json',
    );
    return (jsonDecode(json) as Map).cast<String, Object?>();
  }
}

Map<PublicationFormat, Uri> parseKgbookDownloadLinks(
  String body,
  Uri page,
  String book,
) {
  final links = <PublicationFormat, Uri>{};
  final document = html.parse(body);
  for (final anchor in document.querySelectorAll('a[href]')) {
    final suffix = _formatLabel.firstMatch(anchor.text.trim())?[1];
    if (suffix == null) continue;
    final format = PublicationFormat.fromName('file.$suffix')!;
    final href = anchor.attributes['href']!;
    if (href.length > 1024) continue;
    final reference = Uri.tryParse(href);
    if (reference == null) continue;
    final target = page.resolveUri(reference);
    if (!kgbookHost(target) ||
        target.hasFragment ||
        !(_file(target, format) || _entry(target, book))) {
      continue;
    }
    links.putIfAbsent(format, () => target);
  }
  return links;
}

final _formatLabel = RegExp(
  r'^(?:\d+寸\s*)?(azw3?|mobi|epub|pdf|zip)\s*(?:格式)?$',
  caseSensitive: false,
);
const _entryPaths = {'/e/DownSys/GetDown', '/e/DownSys/GetDown/'};
final _number = RegExp(r'^[0-9]{1,10}$');
final _fileFolder = RegExp(r'^[a-zA-Z0-9_-]+$');
final _unsafeFileName = RegExp(r'[/\\%\x00-\x1f\x7f-\x9f]');
final _han = RegExp(r'\p{Script=Han}', unicode: true);

bool _entry(Uri uri, String book) {
  if (!_entryPaths.contains(uri.path)) return false;
  final fields = uri.queryParametersAll;
  return fields.length == 3 &&
      fields.values.every(
        (values) => values.length == 1 && _number.hasMatch(values.single),
      ) &&
      fields['id']?.single == book &&
      fields.containsKey('classid') &&
      fields.containsKey('pathid');
}

bool _file(Uri uri, PublicationFormat format) {
  final path = uri.pathSegments;
  if (uri.hasQuery || !_fileDirectory(path)) return false;
  final name = path.last;
  return name.length <= 240 &&
      !_unsafeFileName.hasMatch(name) &&
      format.accepts(PublicationFormat.fromName(name));
}

bool _fileDirectory(List<String> path) =>
    path.length >= 3 &&
    path[0] == 'd' &&
    path[1] == 'file' &&
    path.skip(2).take(path.length - 3).every(_fileFolder.hasMatch);

// The site sends raw UTF-8 filenames in Location headers, which Dart exposes
// as Latin-1. Repair the filename before applying the file scope.
Uri _fileRedirect(Uri uri) {
  final path = uri.pathSegments;
  if (!kgbookPublicAddress(uri) || !_fileDirectory(path)) return uri;
  final name = path.last;
  if (name.codeUnits.any((byte) => byte > 255)) return uri;
  try {
    final decoded = utf8.decode(latin1.encode(name));
    if (_han.hasMatch(decoded) && !_unsafeFileName.hasMatch(decoded)) {
      return uri.replace(
        pathSegments: [...path.take(path.length - 1), decoded],
      );
    }
  } on FormatException {
    // The original address may already contain an encoded, valid filename.
  }
  return uri;
}

DateTime? kgbookFreshUntil(HttpHeaders headers, DateTime now) {
  final control =
      headers[HttpHeaders.cacheControlHeader]?.join(',').toLowerCase() ?? '';
  final directives = control
      .split(',')
      .map((part) => part.split('=').first.trim());
  if (directives.any(const {'no-store', 'no-cache', 'private'}.contains) ||
      (headers[HttpHeaders.varyHeader] ?? const []).join(',').contains('*') ||
      headers[HttpHeaders.setCookieHeader] != null) {
    return null;
  }
  final age = int.tryParse(headers.value(HttpHeaders.ageHeader) ?? '') ?? 0;
  if (age < 0) return null;
  final maxAge = RegExp(
    r'(?:^|,)\s*max-age\s*=\s*([0-9]+)\s*(?:,|$)',
  ).firstMatch(control);
  var seconds = int.tryParse(maxAge?[1] ?? '');
  if (seconds == null) {
    if (directives.contains('max-age')) return null;
    final modified = headers.value(HttpHeaders.lastModifiedHeader);
    if (modified == null) return null;
    try {
      seconds = now.difference(HttpDate.parse(modified)).inSeconds ~/ 10;
    } on HttpException {
      return null;
    }
  }
  final fresh = min(60, seconds - age);
  return fresh > 0 ? now.add(Duration(seconds: fresh)) : null;
}
