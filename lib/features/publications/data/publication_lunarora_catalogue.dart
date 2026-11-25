import 'dart:convert';

import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_catalogue_shares.dart';
import 'publication_http.dart';
import 'publication_share_provider.dart';

const lunaroraSource = 'lunarora-public-catalogue';
final lunaroraCatalogueEndpoint = Uri.https('lunarora.com', '/books');
final _searchEndpoint = Uri.https('lunarora.com', '/api/v2/search');
final _bookId = RegExp(r'^(?:[0-9]{9}[0-9X]|[0-9]{13}|GJ[0-9]{11})$');
const _searchLimit = 20;

final class LunaroraCatalogue
    implements ResourcePublicationCatalogue, SharedPublicationCatalogue {
  const LunaroraCatalogue(this.http);

  final PublicationHttp http;

  @override
  void restrictShare(Uri? page, Uri link) {
    if (!_bookPage(page) ||
        !supportsCatalogueShareDownload(lunaroraSource, link)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
  }

  @override
  Future<List<PublicationResource>> loadResources(
    Uri page,
    CancellationToken token,
  ) async {
    if (!_bookPage(page)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final book = html
        .parse(await _read(page, token))
        .querySelector('main.book-detail-main');
    if (book == null) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    final resources = <Uri, PublicationResource>{};
    for (final row
        in book
            .querySelectorAll('.download-section .download-link-card')
            .take(12)) {
      final href = row
          .querySelector('a.download-btn[href]')
          ?.attributes['href'];
      final address = Uri.tryParse(href ?? '');
      if (address == null) continue;
      final resource = publishedCatalogueShare(
        lunaroraSource,
        href,
        provider: PublicationShareProvider.of(address),
        baiduDownloads: true,
        code: row.querySelector('.extraction-code code')?.text.trim(),
      );
      if (resource != null) {
        resources.putIfAbsent(resource.link, () => resource);
      }
    }
    return resources.values.toList();
  }

  @override
  Future<void> check(CancellationToken token) async {
    await _search('图书', token, limit: 1);
  }

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
  }) async {
    final isbn = filter?.isbn ?? normalizedIsbn(query);
    if (isbn.isNotEmpty) query = isbn;
    final queryLength = query.runes.length;
    if (queryLength > 80) return const [];
    final editions = queryLength < 2
        ? (await _browse(
            token,
          )).where((edition) => edition.matches(query, filter: filter))
        : await _search(query, token);
    return [
      for (final edition in editions)
        if ((filter?.matches(edition) ?? true) &&
            allowed('${edition.title} ${edition.author}'))
          edition,
    ];
  }

  Future<List<PublicationEdition>> _search(
    String query,
    CancellationToken token, {
    int limit = _searchLimit,
  }) async {
    final address = _searchEndpoint.replace(
      queryParameters: {'q': query, 'limit': '$limit'},
    );
    Future<List<PublicationEdition>> attempt() async => parseLunaroraSearch(
      jsonDecode(
        await _read(address, token, deadline: const Duration(seconds: 10)),
      ),
    );
    try {
      return await attempt();
    } on Exception catch (error) {
      token.check();
      if (!isPublicationNetworkFailure(error)) rethrow;
      return attempt();
    }
  }

  Future<List<PublicationEdition>> _browse(CancellationToken token) async {
    // The public SSR directory embeds the first batch; its infinite-scroll
    // requests are separate from the documented, non-paginated Search API.
    final editions = parseLunaroraDirectory(
      await _read(lunaroraCatalogueEndpoint, token),
    );
    if (editions.isEmpty) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    return editions;
  }

  Future<String> _read(
    Uri address,
    CancellationToken token, {
    Duration deadline = publicationCatalogueDeadline,
  }) => http.text(
    address,
    token,
    maxBytes: 512 << 10,
    deadline: deadline,
    allowGzip: true,
    scope: (target) {
      if (target != address) {
        throw const PublicationFailure(PublicationProblem.unsupported);
      }
    },
  );
}

List<PublicationEdition> parseLunaroraSearch(Object? payload) {
  if (payload case {
    'apiVersion': '2',
    'contentLanguage': 'zh-CN',
    'count': final int count,
    'results': final List rows,
  } when count == rows.length && count <= _searchLimit) {
    final editions = <String, PublicationEdition>{};
    for (final row in rows) {
      if (row case {
        'type': 'Book',
        'catalogId': final String id,
        'bookUrl': final String url,
        'title': final String title,
      }) {
        final edition = _edition(
          id,
          url,
          title,
          author: row['authorsText'],
          cover: row['coverUrl'],
          description: row['description'],
          tags: row['tags'],
          rating: row['rating'],
          downloads: row['hasDownloadLinks'] == true
              ? row['downloadLinks']
              : null,
          lookup: row['hasDownloadLinks'] == true,
        );
        if (edition != null) {
          editions.putIfAbsent(edition.id, () => edition);
        }
      }
    }
    if (count != 0 && editions.isEmpty) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    return editions.values.toList();
  }
  throw const PublicationFailure(PublicationProblem.invalid);
}

List<PublicationEdition> parseLunaroraDirectory(String body) {
  final document = html.parse(body);
  final editions = <String, PublicationEdition>{};
  final links = document.querySelectorAll(
    'section.book-page-group a[data-book-isbn][href]',
  );
  for (final link in links) {
    final edition = _edition(
      link.attributes['data-book-isbn']!,
      link.attributes['href']!,
      link.querySelector('h3.title')?.text,
      author: link.querySelector('.author')?.text,
      cover: link.querySelector('img')?.attributes['src'],
      description: link.querySelector('.overlay-description')?.text,
      lookup: true,
    );
    if (edition != null) {
      editions.putIfAbsent(edition.id, () => edition);
    }
  }
  return editions.values.toList();
}

PublicationEdition? _edition(
  String id,
  String href,
  String? rawTitle, {
  Object? author,
  Object? cover,
  Object? description,
  Object? tags,
  Object? rating,
  Object? downloads,
  bool lookup = false,
}) {
  if (!_bookId.hasMatch(id) || href.length > 256) return null;
  final reference = Uri.tryParse(href);
  if (reference == null) return null;
  final page = lunaroraCatalogueEndpoint.resolveUri(reference);
  final expected = Uri.https('lunarora.com', '/book/$id');
  final title = publicationLabel(rawTitle);
  if (page != expected || title.isEmpty) return null;
  final resources = <Uri, PublicationResource>{
    if (downloads is List)
      for (final resource in downloads.take(12).map(_resource).nonNulls)
        resource.link: resource,
  };
  return PublicationEdition(
    id: publicationId('$lunaroraSource\n$id'),
    title: title,
    author: publicationLabel(author),
    isbn: normalizedIsbn(id),
    language: 'zh-CN',
    cover: publicationCoverUrl(
      page,
      cover,
      (uri) => uri.host == 'covers.lunarora.com',
    ),
    description: publicationLabel(description, max: 650),
    tags: tags is List
        ? tags
              .take(12)
              .map((tag) => publicationLabel(tag, max: 64))
              .where((tag) => tag.isNotEmpty)
              .toList()
        : const [],
    rating: rating is num && rating > 0 && rating <= 10 ? '豆瓣评分 $rating' : '',
    page: page,
    resources: [
      ...resources.values,
      if (lookup && resources.isEmpty)
        PublicationResource.lookup(source: lunaroraSource, link: page),
    ],
  );
}

PublicationResource? _resource(Object? value) {
  if (value case {'provider': final String provider, 'url': final String url}) {
    final kind = switch (provider) {
      'quark' => PublicationShareProvider.quark,
      'baidu' => PublicationShareProvider.baidu,
      'xunlei' => PublicationShareProvider.xunlei,
      _ => null,
    };
    if (kind == null) return null;
    final code = value['extractionCode'];
    final description = publicationLabel(value['description']).toLowerCase();
    return publishedCatalogueShare(
      lunaroraSource,
      url,
      provider: kind,
      baiduDownloads: true,
      code: code is String ? code : null,
      format: PublicationFormat.values
          .where((format) => format.name == description)
          .firstOrNull,
    );
  }
  return null;
}

bool _bookPage(Uri? page) {
  final id = page?.pathSegments.lastOrNull;
  return id != null &&
      _bookId.hasMatch(id) &&
      page == Uri.https('lunarora.com', '/book/$id');
}
