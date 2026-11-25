import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_catalogue_shares.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';
import 'publication_share_provider.dart';

const kanhaoshuPublicationSource = 'panda-kanhaoshu';
final kanhaoshuHome = Uri.https('http561856124.wordpress.com', '/');
final kanhaoshuEndpoint = Uri.https(
  'public-api.wordpress.com',
  '/wp/v2/sites/${kanhaoshuHome.host}/posts',
);
final _post = RegExp(r'^/20\d{2}/\d{2}/\d{2}/[^/]{1,160}/$');
final _extension = RegExp(
  r'\.(?:epub|pdf|mobi|azw3|azw)\s*[:：]?$',
  caseSensitive: false,
);
final _mirrors = RegExp(
  r'\s*\((?:z-library\.sk|1lib\.sk|z-lib\.sk)[^)]*\)$',
  caseSensitive: false,
);
final _credit = RegExp(r'\s+[（(]([^()（）]{1,60})[）)](?:\s+\d{4}-\d{2})?$');
final _creditWithCountry = RegExp(
  r'\s*\(\([一-龥]{1,3}\)\s*([^()（）]{1,40}?)\s+\d{4}-\d{2}$',
);
const _pageSize = 4;

final class KanhaoshuCatalogue implements ProgressivePublicationCatalogue {
  const KanhaoshuCatalogue(this.http);
  final PublicationHttp http;

  @override
  Future<void> check(CancellationToken token) => _listing('').check(token);

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
    Future<void> Function(List<PublicationEdition>)? onProgress,
  }) => _listing(filter == null ? query : '').search(
    query,
    token,
    maxPages: maxPages,
    allowed: allowed,
    filter: filter,
    onProgress: onProgress,
  );

  PublicListingCatalogue _listing(String plainQuery) => PublicListingCatalogue(
    http,
    address: (query, page) => kanhaoshuEndpoint.replace(
      queryParameters: {
        if (query.isNotEmpty) 'search': query,
        'per_page': '$_pageSize',
        'page': '$page',
        '_fields': 'id,link,content',
      },
    ),
    parse: (body) {
      final data = parseKanhaoshuCatalogue(body);
      return (
        books: data.books.where((book) => book.matches(plainQuery)).toList(),
        hasNext: data.hasNext,
      );
    },
  );
}

PublicationListingPage parseKanhaoshuCatalogue(String body) {
  final data = jsonDecode(body);
  if (data is! List || data.length > _pageSize) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final entries = <Uri, PublicationEdition>{};
  for (final post in data) {
    if (post case {
      'link': final String link,
      'content': {'rendered': final String markup},
    }) {
      final page = publicListingLink(kanhaoshuHome, link, _post);
      if (page == null) continue;
      final paragraphs = html.parseFragment(markup).querySelectorAll('p');
      for (final paragraph in paragraphs) {
        final book = _edition(page, paragraph);
        if (book != null) entries[book.resources.single.link] = book;
      }
    }
  }
  return (books: entries.values.toList(), hasNext: data.length == _pageSize);
}

PublicationEdition? _edition(Uri page, dom.Element paragraph) {
  final anchor = paragraph.querySelectorAll('a[href]').singleOrNull;
  if (anchor == null) return null;
  final heading = paragraph.nodes
      .takeWhile(
        (node) =>
            node != anchor && (node is! dom.Element || node.localName != 'br'),
      )
      .map((node) => node.text ?? '')
      .join()
      .trim();
  final extension = _extension.firstMatch(heading);
  if (extension == null) return null;
  final format = PublicationFormat.fromName(
    extension[0]!.replaceFirst(RegExp(r'\s*[:：]$'), ''),
  );
  if (format == null) return null;
  final resource = publishedCatalogueShare(
    kanhaoshuPublicationSource,
    anchor.attributes['href'],
    provider: PublicationShareProvider.ctfile,
    format: format,
  );
  if (resource == null) return null;
  final text = heading
      .substring(0, extension.start)
      .trim()
      .replaceFirst(_mirrors, '');
  final credit =
      _credit.firstMatch(text) ?? _creditWithCountry.firstMatch(text);
  final title = publicationLabel(
    credit == null ? text : text.substring(0, credit.start),
  );
  if (title.isEmpty) return null;
  return PublicationEdition(
    id: publicationId('$kanhaoshuPublicationSource\n${resource.link}'),
    title: title,
    author: publicationLabel(credit?[1]),
    page: page,
    resources: [resource],
  );
}
