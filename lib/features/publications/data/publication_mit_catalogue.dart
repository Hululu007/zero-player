import 'dart:convert';

import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';

const mitOcwPublicationSource = 'panda-mit-ocw';
final mitOcwHome = Uri.https('ocw.mit.edu', '/');
final mitOcwEndpoint = Uri.https(
  'api.learn.mit.edu',
  '/api/v1/learning_resources_search/',
);
final _coursePath = RegExp(r'^/courses/[a-z0-9][a-z0-9-]{1,220}/$');
final _pdfName = RegExp(
  r'^[^/\\\x00-\x1f\x7f]{1,235}\.pdf$',
  caseSensitive: false,
);
const _pageSize = 10;

final class MitOcwCatalogue
    implements
        ProgressivePublicationCatalogue,
        ResourcePublicationCatalogue,
        SharedPublicationCatalogue,
        DownloadablePublicationCatalogue {
  const MitOcwCatalogue(this.http);

  final PublicationHttp http;

  PublicListingCatalogue get _listing => PublicListingCatalogue(
    http,
    address: (query, page) => mitOcwEndpoint.replace(
      queryParameters: {
        'platform': 'ocw',
        'resource_type': 'course',
        'limit': '$_pageSize',
        if (page > 1) 'offset': '${(page - 1) * _pageSize}',
        if (query.isNotEmpty) 'q': query,
      },
    ),
    parse: parseMitOcwCatalogue,
    maxBytes: 1 << 20,
  );

  @override
  Future<void> check(CancellationToken token) => _listing.check(token);

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
    Future<void> Function(List<PublicationEdition>)? onProgress,
  }) => _listing.search(
    query,
    token,
    maxPages: maxPages,
    allowed: allowed,
    filter: filter,
    onProgress: onProgress,
  );

  @override
  Future<List<PublicationResource>> loadResources(
    Uri page,
    CancellationToken token,
  ) {
    if (publicListingLink(mitOcwHome, page.toString(), _coursePath) != page) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    return _readFiles(page, token);
  }

  Future<List<PublicationResource>> _readFiles(
    Uri page,
    CancellationToken token,
  ) async => parseMitOcwResources(
    page,
    await publicListingText(
      http,
      page.resolve('download/'),
      token,
      maxBytes: 2 << 20,
    ),
  );

  @override
  void restrictShare(Uri? page, Uri link) {
    if (page == null ||
        publicListingLink(mitOcwHome, page.toString(), _coursePath) != page ||
        _coursePdf(page, link.toString()) != link) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
  }

  @override
  Future<PublicationDownload> download(
    AcquisitionCandidate candidate,
    CancellationToken token,
  ) async {
    restrictShare(candidate.page, candidate.link);
    if (candidate.source != mitOcwPublicationSource ||
        candidate.format != PublicationFormat.pdf) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final files = await _readFiles(candidate.page!, token);
    if (!files.any((file) => file.link == candidate.link)) {
      throw const PublicationFailure(PublicationProblem.missing);
    }
    return PublicationDownload(
      candidate.link,
      scope: (target) {
        if (target != candidate.link) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
    );
  }
}

PublicationListingPage parseMitOcwCatalogue(String body) {
  final json = jsonDecode(body);
  if (json case {'results': final List results, 'next': final Object? next}) {
    final books = <Uri, PublicationEdition>{};
    for (final row in results) {
      if (row case {
        'resource_type': 'course',
        'platform': {'code': 'ocw'},
        'published': true,
        'title': final String title,
        'url': final String address,
      }) {
        final page = publicListingLink(mitOcwHome, address, _coursePath);
        final name = publicationLabel(title);
        if (page == null || name.isEmpty) continue;
        final run = switch (row['runs']) {
          [final Map run, ...] => run,
          _ => const <String, Object?>{},
        };
        final instructors = switch (run['instructors']) {
          final List names => [
            for (final name in names)
              if (name case {'full_name': final String fullName}) fullName,
          ].join('、'),
          _ => '',
        };
        final edition = [
          publicationLabel(run['semester']),
          if (run['year'] case final int year) '$year',
        ].where((part) => part.isNotEmpty).join(' ');
        final image = switch (row['image']) {
          {'url': final String url} => url,
          _ => null,
        };
        books[page] = PublicationEdition(
          id: publicationId('$mitOcwPublicationSource\n$page'),
          title: name,
          author: publicationLabel(instructors),
          edition: edition,
          publisher: 'MIT OpenCourseWare',
          cover: publicationCoverUrl(
            page,
            image,
            (uri) =>
                uri.origin == mitOcwHome.origin &&
                uri.path.startsWith(page.path),
          ),
          page: page,
          resources: [
            PublicationResource.lookup(
              source: mitOcwPublicationSource,
              link: page,
            ),
          ],
        );
      }
    }
    return (
      books: books.values.toList(),
      hasNext: next is String && next.isNotEmpty,
    );
  }
  throw const PublicationFailure(PublicationProblem.invalid);
}

List<PublicationResource> parseMitOcwResources(Uri page, String body) {
  final document = html.parse(body);
  final files = <Uri, PublicationResource>{};
  for (final item in document.querySelectorAll('.resource-item')) {
    final name = publicationLabel(
      item.querySelector('.resource-list-title')?.text,
    );
    for (final anchor in item.querySelectorAll('a[href]')) {
      final uri = _coursePdf(page, anchor.attributes['href']);
      if (uri == null) continue;
      files[uri] = PublicationResource(
        source: mitOcwPublicationSource,
        link: uri,
        label: name.isEmpty ? uri.pathSegments.last : name,
        format: PublicationFormat.pdf,
        canListFiles: true,
      );
    }
  }
  return files.values.toList();
}

Uri? _coursePdf(Uri course, String? raw) {
  if (raw == null || raw.length > 512) return null;
  final path = Uri.tryParse(raw.trim());
  if (path == null) return null;
  final uri = course.resolveUri(path);
  return uri.scheme == 'https' &&
          uri.origin == mitOcwHome.origin &&
          uri.userInfo.isEmpty &&
          !uri.hasQuery &&
          !uri.hasFragment &&
          uri.pathSegments.length == 3 &&
          uri.path.startsWith(course.path) &&
          _pdfName.hasMatch(uri.pathSegments.last)
      ? uri
      : null;
}
