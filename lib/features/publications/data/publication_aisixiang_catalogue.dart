import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';

const aisixiangSource = 'panda-aisixiang';
final aisixiangHome = Uri.https('www.aisixiang.com', '/');
final aisixiangEndpoint = aisixiangHome.resolve('data/search');
final _articlePath = RegExp(r'^/data/[1-9][0-9]{0,9}\.html$');
final _bylineSeparator = RegExp(r'[：:]');
final _authorSeparator = RegExp(r'[\s、，,]+');

final class AisixiangCatalogue implements PublicationCatalogue {
  const AisixiangCatalogue(this.http);

  final PublicationHttp http;

  PublicListingCatalogue _listing(PublicationSearchField field) =>
      PublicListingCatalogue(
        http,
        address: (query, page) => aisixiangEndpoint.replace(
          queryParameters: {
            if (query.isNotEmpty) ...{
              'keywords': query,
              'searchfield': switch (field) {
                PublicationSearchField.title => 'title',
                PublicationSearchField.author => 'author',
                _ => 'keywords',
              },
            },
            if (page > 1) 'page': '$page',
          },
        ),
        parse: parseAisixiangCatalogue,
        allowEmptyBrowse: true,
      );

  @override
  Future<void> check(CancellationToken token) async {
    final rows = await _listing(PublicationSearchField.title).search(
      '红楼梦',
      token,
      maxPages: 1,
      allowed: (_) => true,
      filter: PublicationFieldSearch(PublicationSearchField.title, '红楼梦'),
    );
    if (rows.isEmpty) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
  }

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
  }) async {
    final field = filter?.field ?? PublicationSearchField.all;
    if (field == PublicationSearchField.isbn) return const [];
    final rows = await _listing(field).search(
      query,
      token,
      maxPages: maxPages,
      allowed: allowed,
      filter: field == PublicationSearchField.title ? filter : null,
    );
    if (query.isEmpty) return rows;

    final candidates = rows.take(16).toList();
    final found = <PublicationEdition>[];
    for (var start = 0; start < candidates.length; start += 4) {
      final batch = await Future.wait(
        candidates.skip(start).take(4).map((row) => _load(row, token)),
      );
      found.addAll(
        batch.nonNulls.where(
          (book) =>
              book.matches(query, filter: filter) &&
              allowed('${book.title} ${book.author}'),
        ),
      );
    }
    return found;
  }

  Future<PublicationEdition?> _load(
    PublicationEdition book,
    CancellationToken token,
  ) async {
    final page = book.page!;
    try {
      final body = await publicListingText(
        http,
        page,
        token,
        maxBytes: 1 << 20,
        deadline: const Duration(seconds: 5),
      );
      return confirmAisixiangArticle(book, body);
    } on Exception catch (error) {
      token.check();
      if (isPublicationNetworkFailure(error) ||
          (error is PublicationFailure &&
              const {
                PublicationProblem.missing,
                PublicationProblem.invalid,
              }.contains(error.problem))) {
        return null;
      }
      rethrow;
    }
  }
}

PublicationListingPage parseAisixiangCatalogue(String body) {
  final document = html.parse(body);
  final list = document.querySelector('.text_left .search_list');
  if (list == null) throw const PublicationFailure(PublicationProblem.invalid);
  final books = <Uri, PublicationEdition>{};
  for (final anchor in list.querySelectorAll('.article-title a[title][href]')) {
    final page = publicListingLink(
      aisixiangHome,
      anchor.attributes['href'],
      _articlePath,
    );
    final title = publicationLabel(anchor.text);
    if (page == null || title.isEmpty) continue;
    books[page] = PublicationEdition(
      id: publicationId('$aisixiangSource\n$page'),
      title: title,
      page: page,
    );
  }
  return (
    books: books.values.toList(),
    hasNext: list.querySelector('a.page-link[aria-label="Next"]') != null,
  );
}

PublicationEdition? confirmAisixiangArticle(
  PublicationEdition row,
  String body,
) {
  final document = html.parse(body);
  final article = document.querySelector('.text_left .show_text');
  if (article == null ||
      article.querySelector('.article-content') == null ||
      publicationLabel(article.querySelector('h3')?.text) != row.title) {
    return null;
  }
  final names = article
      .querySelectorAll('.about > div:first-child > div > strong')
      .map((entry) => publicationLabel(entry.text))
      .where((name) => name.isNotEmpty)
      .toList();
  final colon = row.title.indexOf(_bylineSeparator);
  final hasByline =
      colon > 0 &&
      names.isNotEmpty &&
      row.title.substring(0, colon).split(_authorSeparator).join() ==
          names.join();
  final title = hasByline ? row.title.substring(colon + 1).trim() : row.title;
  return PublicationEdition(
    id: row.id,
    title: title.isEmpty ? row.title : title,
    author: publicationLabel(names.join('、')),
    page: row.page,
  );
}
