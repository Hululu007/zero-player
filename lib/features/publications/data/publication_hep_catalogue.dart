import 'dart:convert';

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';

const hepPublicationSource = 'panda-hep';
final hepHome = Uri.https('ebook.hep.com.cn', '/index.html');
final hepEndpoint = hepHome.resolve('/dev-api/webApi/book/searchBookList');
final _bookId = RegExp(r'^[1-9][0-9]{0,19}$');
final _coverPath = RegExp(
  r'^/files/upload/[a-f0-9]{3}/[a-f0-9]{32}\.(?:jpe?g|png|webp)$',
);
const _types = {'53': '/detail', '54': '/soundBook', '55': '/courseBook'};
const _pageSize = 20;

bool isHepCover(Uri uri) =>
    uri.scheme == 'https' &&
    uri.port == 443 &&
    uri.userInfo.isEmpty &&
    uri.host == 'hep-xueke-res.oss-cn-beijing.aliyuncs.com' &&
    _coverPath.hasMatch(uri.path) &&
    !uri.hasQuery &&
    !uri.hasFragment;

final class HepCatalogue implements ProgressivePublicationCatalogue {
  const HepCatalogue(this.http);

  final PublicationHttp http;

  PublicListingCatalogue get _listing => PublicListingCatalogue(
    http,
    address: (query, page) => hepEndpoint.replace(
      queryParameters: {
        'Title': query,
        'pageNum': '$page',
        'pageSize': '$_pageSize',
        'IsSample': '0',
      },
    ),
    parse: parseHepCatalogue,
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
  }) {
    if (filter?.field == PublicationSearchField.isbn) {
      return Future.value(const []);
    }
    return _listing.search(
      query,
      token,
      maxPages: maxPages,
      allowed: allowed,
      filter: filter,
      onProgress: onProgress,
    );
  }
}

PublicationListingPage parseHepCatalogue(String body) {
  final data = jsonDecode(body);
  if (data case {
    'code': 200,
    'total': final int total,
    'rows': final List rows,
  }) {
    final books = <String, PublicationEdition>{};
    for (final row in rows) {
      if (row case {
        'Id': final String id,
        'Title': final String name,
        'ObjectType': final String type,
        'IsDeleted': '0',
        'IsOnShelf': '1',
      } when _bookId.hasMatch(id)) {
        final route = _types[type];
        final title = publicationLabel(name);
        if (route == null || title.isEmpty) continue;
        final page = hepHome.replace(fragment: '$route?id=$id');
        books[id] = PublicationEdition(
          id: publicationId('$hepPublicationSource\n$id'),
          title: title,
          author: publicationLabel(row['Author']),
          isbn: normalizedIsbn(publicationLabel(row['Isbn'])),
          publisher: publicationLabel(row['Publisher']),
          page: page,
          cover: publicationCoverUrl(page, row['CoverUrl'], isHepCover),
        );
      }
    }
    return (
      books: books.values.toList(),
      hasNext: total > _pageSize && rows.length == _pageSize,
    );
  }
  throw const PublicationFailure(PublicationProblem.invalid);
}
