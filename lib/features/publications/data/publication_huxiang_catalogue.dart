import 'dart:convert';

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';

const huxiangPublicationSource = 'panda-huxiangwenku';
final huxiangHome = Uri.https('www.huxiangwenku.cn', '/books');
final huxiangEndpoint = huxiangHome.resolve('/prod-api/web/search/book');
final _listEndpoint = huxiangHome.resolve('/prod-api/web/book/list');
final _bookId = RegExp(r'^[1-9][0-9]{0,19}$');
final _coverPath = RegExp(
  r'^/filepublic/\d{4}/\d{2}/\d{2}/[a-f0-9]{16,64}\.(?:jpe?g|png|webp)$',
);
const _pageSize = 20;

final class HuxiangCatalogue implements ProgressivePublicationCatalogue {
  const HuxiangCatalogue(this.http);

  final PublicationHttp http;

  PublicListingCatalogue _listing(bool browse) => PublicListingCatalogue(
    http,
    address: (_, page) => browse
        ? _listEndpoint.replace(
            queryParameters: {'pageNum': '$page', 'pageSize': '$_pageSize'},
          )
        : huxiangEndpoint,
    requestBody: browse
        ? null
        : (query, page) => {
            'text': query,
            'pageNum': page,
            'pageSize': _pageSize,
          },
    referer: huxiangHome,
    parse: parseHuxiangCatalogue,
  );

  @override
  Future<void> check(CancellationToken token) => _listing(true).check(token);

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
    Future<void> Function(List<PublicationEdition>)? onProgress,
  }) async {
    if (filter?.field == PublicationSearchField.isbn) return const [];
    return _listing(query.isEmpty).search(
      query,
      token,
      maxPages: maxPages,
      allowed: allowed,
      filter: filter,
      onProgress: onProgress,
    );
  }
}

PublicationListingPage parseHuxiangCatalogue(String body) {
  final data = jsonDecode(body);
  if (data case {
    'code': 200,
    'total': final int total,
    'rows': final List rows,
  }) {
    final books = <String, PublicationEdition>{};
    for (final row in rows) {
      if (row is! Map) continue;
      final id = row['bookId'] ?? row['id'];
      final title = publicationLabel(row['title']);
      if (id is! String || !_bookId.hasMatch(id) || title.isEmpty) continue;
      final page = huxiangHome.resolve('/book/$id');
      books[id] = PublicationEdition(
        id: publicationId('$huxiangPublicationSource\n$id'),
        title: title,
        author: publicationLabel(row['author']),
        page: page,
        cover: publicationCoverUrl(
          page,
          row['coverUrl'],
          (uri) =>
              uri.origin == huxiangHome.origin &&
              _coverPath.hasMatch(uri.path) &&
              !uri.hasQuery,
        ),
      );
    }
    return (
      books: books.values.toList(),
      hasNext: total > _pageSize && rows.length == _pageSize,
    );
  }
  throw const PublicationFailure(PublicationProblem.invalid);
}
