import 'dart:convert';

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_catalogue_shares.dart';
import 'publication_http.dart';
import 'publication_share_provider.dart';

const treasurePublicationSource = 'ebook-treasure-chest';
final treasureCataloguePage = Uri.https(
  'jbiaojerry.github.io',
  '/ebook-treasure-chest/',
);
final treasureCatalogueEndpoint = treasureCataloguePage.resolve(
  'all-books.json',
);
final _searchPage = treasureCataloguePage.replace(fragment: 'search-input');

final class TreasureCatalogue implements PublicationCatalogue {
  TreasureCatalogue(this.http);

  final PublicationHttp http;
  ({List<PublicationEdition> books, DateTime expires})? _recent;

  @override
  Future<void> check(CancellationToken token) async {
    await _load(token, refresh: true);
  }

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
  }) async {
    final books = await _load(token);
    return books
        .where(
          (book) =>
              book.matches(query, filter: filter) &&
              allowed('${book.title} ${book.author}'),
        )
        .take(maxPages * 20)
        .toList();
  }

  Future<List<PublicationEdition>> _load(
    CancellationToken token, {
    bool refresh = false,
  }) async {
    token.check();
    http.authorize(treasureCatalogueEndpoint);
    final recent = _recent;
    if (!refresh && recent != null && recent.expires.isAfter(DateTime.now())) {
      return recent.books;
    }
    final body = await http.text(
      treasureCatalogueEndpoint,
      token,
      maxBytes: 12 << 20,
      deadline: publicationCatalogueDeadline,
      allowGzip: true,
      scope: (target) {
        if (target != treasureCatalogueEndpoint) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
    );
    token.check();
    final books = parseTreasureCatalogue(body);
    _recent = (
      books: books,
      expires: DateTime.now().add(const Duration(minutes: 10)),
    );
    return books;
  }
}

List<PublicationEdition> parseTreasureCatalogue(String body) {
  final data = jsonDecode(body);
  if (data is! List || data.length > 40000) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <String, PublicationEdition>{};
  // The index provides the per-title share. Its HTML catalogue is the fallback.
  for (final row in data.whereType<Map>()) {
    final title = publicationLabel(row['title']);
    if (title.isEmpty) continue;
    final author = publicationLabel(row['author']);
    final category = publicationLabel(row['category']);
    final id = publicationId('$treasurePublicationSource\n$title\n$author');
    final resource = publishedCatalogueShare(
      treasurePublicationSource,
      row['link'] is String ? row['link'] as String : null,
      provider: PublicationShareProvider.ctfile,
    );
    if (books[id] case final previous?
        when previous.resources.isNotEmpty || resource == null) {
      continue;
    }
    books[id] = PublicationEdition(
      id: id,
      title: title,
      author: author,
      language: publicationLabel(row['language']),
      tags: [if (category.isNotEmpty) category],
      page: _searchPage,
      resources: [?resource],
    );
  }
  if (books.isEmpty) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  return books.values.toList();
}
