import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';

const tinynewsPublicationSource = 'panda-tinynews';
final tinynewsHome = Uri.https('book.tinynews.org', '/');
final _bookPath = RegExp(r'^/books/(?:db_)?([1-9][0-9]{0,11})$');
final _coverPath = RegExp(
  r'^/[a-f0-9]{32,128}/[a-zA-Z0-9_-]+\.(?:jpg|png|webp)$',
);

final class TinynewsCatalogue implements PublicationCatalogue {
  const TinynewsCatalogue(this.http);

  final PublicationHttp http;

  PublicListingCatalogue get _listing => PublicListingCatalogue(
    http,
    address: (query, page) => query.isEmpty
        ? tinynewsHome
        : tinynewsHome.replace(
            pathSegments: ['search', query, if (page > 1) 'page=$page'],
          ),
    parse: parseTinynewsListing,
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
  }) async {
    if (filter?.field == PublicationSearchField.isbn) return const [];
    final titleOnly = filter?.field == PublicationSearchField.title;
    final results = await _listing.search(
      query,
      token,
      maxPages: maxPages,
      allowed: allowed,
      filter: titleOnly ? filter : null,
    );
    if (query.isEmpty) return results;

    // The site's search links include placeholders which return to the
    // homepage. Check the canonical entry before offering it to the user.
    final authorOnly = filter?.field == PublicationSearchField.author;
    final homepage = authorOnly
        ? await _listing.search('', token, maxPages: 1, allowed: allowed)
        : const <PublicationEdition>[];
    final hits = {
      for (final row in results.take(authorOnly ? 8 : 12)) row.id: row,
      for (final row in homepage.take(4)) row.id: row,
    }.values.toList();
    final confirmed = <PublicationEdition>[];
    for (var offset = 0; offset < hits.length; offset += 4) {
      final batch = await Future.wait(
        hits.skip(offset).take(4).map((row) => _confirm(row, token)),
      );
      for (final book in batch.nonNulls) {
        if (filter?.matches(book) != false &&
            allowed('${book.title} ${book.author}')) {
          confirmed.add(book);
        }
      }
    }
    return confirmed;
  }

  Future<PublicationEdition?> _confirm(
    PublicationEdition row,
    CancellationToken token,
  ) async {
    final page = row.page;
    if (page == null) return null;
    try {
      final body = await publicListingText(
        http,
        page,
        token,
        deadline: const Duration(seconds: 5),
      );
      return confirmTinynewsBook(row, body);
    } on Exception catch (error) {
      token.check();
      if (error is PublicationFailure &&
          error.problem == PublicationProblem.blocked) {
        rethrow;
      }
      return null;
    }
  }
}

PublicationListingPage parseTinynewsListing(String body) {
  final document = html.parse(body);
  if (document.querySelector('input#ibox') == null) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <String, PublicationEdition>{};
  for (final card in document.querySelectorAll('div.card')) {
    final anchor = card.querySelector('.card-body a[href]');
    final image = card.querySelector('img[data-src]');
    final title = publicationLabel(
      card.querySelector('.card-title')?.text ?? image?.attributes['alt'],
    );
    final link = publicListingLink(
      tinynewsHome,
      anchor?.attributes['href'] ??
          card.querySelector('a[href]')?.attributes['href'],
      _bookPath,
    );
    final number = link == null ? null : _bookPath.firstMatch(link.path)?[1];
    if (number == null || title.isEmpty) continue;
    final page = tinynewsHome.resolve('books/$number');
    books[number] = PublicationEdition(
      id: publicationId('$tinynewsPublicationSource\n$number'),
      title: title,
      cover: publicationCoverUrl(
        tinynewsHome,
        image?.attributes['data-src'],
        (uri) =>
            uri.host == 'doubookpic.tinynews.org' &&
            !uri.hasQuery &&
            _coverPath.hasMatch(uri.path),
      ),
      page: page,
    );
  }
  return (
    books: books.values.toList(),
    hasNext: document.querySelector('.page-link[id="2"]') != null,
  );
}

PublicationEdition? confirmTinynewsBook(PublicationEdition row, String body) {
  final document = html.parse(body);
  final canonical = publicListingLink(
    tinynewsHome,
    document.querySelector('link[rel=canonical]')?.attributes['href'],
    _bookPath,
  );
  final heading = document.querySelector('.col-md-8 h1');
  if (canonical == null ||
      canonical != row.page ||
      !publicationLabel(heading?.text).startsWith(row.title)) {
    return null;
  }
  final author = document
      .querySelectorAll('.col-md-8 > div > span[style*="EBEEF3"]')
      .where((entry) => entry.children.isEmpty)
      .map((entry) => publicationLabel(entry.text))
      .firstWhere((value) => value.isNotEmpty, orElse: () => '');
  return PublicationEdition(
    id: row.id,
    title: row.title,
    author: author,
    cover: row.cover,
    page: canonical,
  );
}
