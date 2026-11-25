import 'dart:convert';

import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';

const cnpereadingPublicationSource = 'panda-cnpereading';
final cnpereadingHome = Uri.https('www.cnpereading.com', '/');
final cnpereadingEndpoint = cnpereadingHome.resolve('api/search/title');
final _bookId = RegExp(r'^(?:[a-f0-9]{24}|[a-f0-9]{32})$');
final _coverPath = RegExp(r'^/meta/cover/[a-zA-Z0-9/_-]+\.(?:jpe?g|png|webp)$');

final class CnpereadingCatalogue implements ProgressivePublicationCatalogue {
  const CnpereadingCatalogue(this.http);

  final PublicationHttp http;

  PublicListingCatalogue _listing(PublicationSearchField? field) =>
      PublicListingCatalogue(
        http,
        address: (_, _) => cnpereadingEndpoint,
        referer: cnpereadingHome,
        requestForm: (query, page) => {
          'keyword': field == PublicationSearchField.author ? '' : query,
          if (field == PublicationSearchField.author) 'author': query,
          'currentPage': '$page',
          'perPageRows': '20',
          'catalog': 'ALL',
          'onlyKeyword': 'true',
        },
        parse: parseCnpereadingCatalogue,
      );

  @override
  Future<void> check(CancellationToken token) => _listing(null).check(token);

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
    Future<void> Function(List<PublicationEdition>)? onProgress,
  }) => _listing(filter?.field).search(
    filter?.field == PublicationSearchField.isbn ? filter!.isbn : query,
    token,
    maxPages: maxPages,
    allowed: allowed,
    filter: filter,
    onProgress: onProgress,
  );
}

PublicationListingPage parseCnpereadingCatalogue(String body) {
  final payload = jsonDecode(body);
  if (payload case {
    'records': final List rows,
    'currentPage': final int page,
    'perPageRows': final int pageSize,
    'numberFound': final int count,
  }) {
    final books = <String, PublicationEdition>{};
    for (final row in rows) {
      if (row case {
        'contentId': final String id,
        'productType': '1' || 1,
        'show': true,
      } when _bookId.hasMatch(id)) {
        final title = _label(row['contentTitle']);
        if (title.isEmpty) continue;
        final link = cnpereadingHome.resolve('bookDetail/$id');
        final cover = publicationCoverUrl(
          link,
          row['contentCover'],
          (uri) =>
              uri.origin == cnpereadingHome.origin &&
              _coverPath.hasMatch(uri.path),
        );
        books[id] = PublicationEdition(
          id: publicationId('$cnpereadingPublicationSource\n$id'),
          title: title,
          author: _label(row['contentAuthor']),
          isbn: normalizedIsbn(publicationLabel(row['SISBN'])),
          publisher: _label(row['publisherName']),
          page: link,
          cover: cover == null
              ? null
              : cnpereadingHome.resolve('/source${cover.path}'),
        );
      }
    }
    return (books: books.values.toList(), hasNext: page * pageSize < count);
  }
  throw const PublicationFailure(PublicationProblem.invalid);
}

String _label(Object? value) => publicationLabel(
  value is String && (value.contains('<') || value.contains('&'))
      ? html.parseFragment(value).text
      : value,
);
