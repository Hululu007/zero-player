import 'dart:convert';

import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';

const openStaxSource = 'openstax-textbooks';
const _host = 'openstax.org';
const _assetHost = 'assets.openstax.org';
const _apiPath = '/apps/cms/api/v2/pages/';
const _fields =
    'title,book_state,pdf_url,license_url,authors,'
    'print_isbn_13,print_softcover_isbn_13,digital_isbn_13,publish_date,'
    'last_updated_pdf,require_login_message_text,cover_url,description';
final openStaxCatalogueEndpoint = Uri.https(_host, _apiPath);
final _slug = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');
final _reference = RegExp(r'^([1-9][0-9]{0,8}):[a-f0-9]{16}$');
final _ccPath = RegExp(
  r'^/licenses/(by(?:-sa|-nd|-nc(?:-sa|-nd)?)?)/(2\.0|2\.5|3\.0|4\.0)/?$',
);

final class OpenStaxCatalogue implements DownloadablePublicationCatalogue {
  const OpenStaxCatalogue(this.http);
  final PublicationHttp http;
  static const _pageSize = 50;
  static const _maxCatalogueEntries = 5000;

  @override
  Future<void> check(CancellationToken token) async {
    await _page(0, 1, token);
  }

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
  }) async {
    final editions = <String, PublicationEdition>{};
    // The public API's text index does not search author names or ISBNs.
    // Filter the small publisher catalogue locally for all three query types.
    var offset = 0;
    for (
      var index = 0;
      offset < _maxCatalogueEntries && (query.isNotEmpty || index < maxPages);
      index++
    ) {
      final page = await _page(offset, _pageSize, token);
      for (final row in page.items) {
        token.check();
        final edition = parseOpenStaxEdition(row, filter == null ? query : '');
        if (edition == null ||
            filter?.matches(edition) == false ||
            !allowed('${edition.title} ${edition.author}')) {
          continue;
        }
        editions.putIfAbsent(edition.id, () => edition);
      }
      offset += page.items.length;
      if (editions.length >= 24 || page.items.isEmpty || offset >= page.total) {
        break;
      }
    }
    return editions.values.take(24).toList();
  }

  @override
  Future<PublicationDownload> download(
    AcquisitionCandidate candidate,
    CancellationToken token,
  ) async {
    final match = _reference.firstMatch(candidate.fileId ?? '');
    if (match == null ||
        candidate.source != openStaxSource ||
        candidate.format != PublicationFormat.pdf ||
        !openStaxPdf(candidate.link)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final endpoint = Uri.https(_host, '$_apiPath${match[1]}/', {
      'fields': _fields,
    });
    final data = await _json(endpoint, token);
    final current = parseOpenStaxEdition(data, '')?.candidates.firstOrNull;
    if (current == null ||
        current.id != candidate.id ||
        current.link != candidate.link ||
        current.page != candidate.page) {
      throw const PublicationFailure(PublicationProblem.missing);
    }
    return PublicationDownload(
      current.link,
      scope: (uri) {
        if (uri != current.link) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
    );
  }

  Future<({List<Object?> items, int total})> _page(
    int offset,
    int limit,
    CancellationToken token,
  ) async {
    final endpoint = openStaxCatalogueEndpoint.replace(
      queryParameters: {
        'type': 'books.Book',
        'fields': _fields,
        'order': 'title,id',
        'offset': '$offset',
        'limit': '$limit',
      },
    );
    final data = await _json(endpoint, token);
    if (data
        case {
          'items': final List<Object?> items,
          'meta': {'total_count': final int total},
        }
        when total >= 0 &&
            total <= _maxCatalogueEntries &&
            items.length <= limit &&
            items.length <= total - offset) {
      return (items: items, total: total);
    }
    throw const PublicationFailure(PublicationProblem.invalid);
  }

  Future<Object?> _json(Uri endpoint, CancellationToken token) async {
    final raw = await http.text(
      endpoint,
      token,
      maxBytes: 768 << 10,
      deadline: publicationCatalogueDeadline,
      scope: (uri) {
        if (uri != endpoint) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
    );
    return jsonDecode(raw);
  }
}

PublicationEdition? parseOpenStaxEdition(Object? raw, String query) {
  if (raw is! Map ||
      raw['id'] is! int ||
      raw['book_state'] != 'live' ||
      raw['meta'] is! Map) {
    return null;
  }
  final id = raw['id'] as int;
  final meta = raw['meta'] as Map;
  final slug = meta['slug'];
  if (id < 1 ||
      id > 999999999 ||
      meta['type'] != 'books.Book' ||
      slug is! String ||
      slug.length > 150 ||
      !_slug.hasMatch(slug)) {
    return null;
  }
  final title = publicationLabel(raw['title']);
  final page = Uri.https(_host, '/details/books/$slug');
  if (title.isEmpty || meta['html_url'] != page.toString()) return null;
  final license = _openStaxLicense(raw['license_url']);
  final pdf = Uri.tryParse(publicationLabel(raw['pdf_url'], max: 2048));
  final version = publicationLabel(raw['last_updated_pdf'], max: 40);
  final login = raw['require_login_message_text'];
  final authors = raw['authors'];
  final names = authors is List
      ? [
          for (final row in authors)
            if (row case {
              'type': 'author',
              'value': {'name': final String name},
            })
              publicationLabel(name, max: 100),
        ].where((name) => name.isNotEmpty)
      : const <String>[];
  final isbns = {
    for (final key in [
      'digital_isbn_13',
      'print_isbn_13',
      'print_softcover_isbn_13',
    ])
      if (normalizedIsbn(publicationLabel(raw[key])) case final isbn
          when isbn.isNotEmpty)
        isbn,
  };
  final isbnQuery = normalizedIsbn(query);
  final edition = PublicationEdition(
    id: publicationId('openstax:$id'),
    title: title,
    author: names.take(3).join('、'),
    isbn: isbns.firstOrNull ?? '',
    alternateIsbns: isbns.skip(1).toList(),
    language: publicationLabel(meta['locale'], max: 24),
    edition: publicationLabel(raw['publish_date'], max: 20),
    license: license,
    publisher: 'OpenStax',
    description: publicationLabel(
      html.parseFragment(publicationLabel(raw['description'], max: 5000)).text,
      max: 1200,
    ),
    cover: publicationCoverUrl(
      page,
      raw['cover_url'],
      (uri) =>
          uri.host == _assetHost &&
          RegExp(
            r'\.(?:jpe?g|png|webp)$',
            caseSensitive: false,
          ).hasMatch(uri.path),
    ),
    page: page,
    candidates: [
      if (license.isNotEmpty &&
          pdf != null &&
          openStaxPdf(pdf) &&
          (login == null || (login is String && login.trim().isEmpty)))
        AcquisitionCandidate(
          source: openStaxSource,
          link: pdf,
          format: PublicationFormat.pdf,
          page: page,
          fileId: '$id:${publicationId('$pdf\n$version').substring(0, 16)}',
        ),
    ],
  );
  final read = '$title ${names.join(' ')}'.toLowerCase();
  final matched = isbnQuery.isNotEmpty
      ? isbns.contains(isbnQuery)
      : query.toLowerCase().split(RegExp(r'\s+')).every(read.contains);
  return matched ? edition : null;
}

String _openStaxLicense(Object? value) {
  if (value is! String) return '';
  final uri = Uri.tryParse(value);
  if (uri == null || !_plainHttps(uri) || uri.host != 'creativecommons.org') {
    return '';
  }
  final match = _ccPath.firstMatch(uri.path);
  return match == null ? '' : 'CC ${match[1]!.toUpperCase()} ${match[2]}';
}

bool openStaxPdf(Uri uri) {
  final parts = uri.pathSegments;
  return _plainHttps(uri) &&
      uri.host == _assetHost &&
      parts.length == 4 &&
      parts[0] == 'oscms-prodcms' &&
      parts[1] == 'media' &&
      parts[2] == 'documents' &&
      !RegExp(r'[/\\\x00-\x1f\x7f]').hasMatch(parts[3]) &&
      PublicationFormat.fromName(parts[3]) == PublicationFormat.pdf;
}

bool _plainHttps(Uri uri) =>
    uri.scheme == 'https' &&
    uri.port == 443 &&
    uri.userInfo.isEmpty &&
    !uri.hasFragment &&
    !uri.hasQuery;
