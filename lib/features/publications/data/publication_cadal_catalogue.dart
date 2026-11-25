import 'dart:convert';

import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';

const cadalPublicationSource = 'panda-cadal';
final cadalHome = Uri.https('cadal.edu.cn', '/index/home');
final cadalEndpoint = cadalHome.resolve('/cadalinfo/search');
final _permissionEndpoint = cadalHome.resolve('/index/checkLockdown');
final _bookAction = RegExp(r"^bookCardPageGo\('([0-9]{8})','card'\)$");
final _groupAction = RegExp(
  r"^changeAggregation\('hj([0-9]{8})','([^']{1,24})'\)$",
);
final _coverFile = RegExp(r'^\d{2}/\d{6}/[a-zA-Z0-9_/-]+\.jpg$');
final _coverSignature = RegExp(r'^[a-f0-9]{32}$');
const _bookGroups = {'古籍', '民国图书', '当代图书', '外文图书', '地方志', '满铁'};

final class CadalCatalogue implements ProgressivePublicationCatalogue {
  const CadalCatalogue(this.http);

  final PublicationHttp http;

  PublicListingCatalogue _listing(PublicationSearchField? field, bool browse) =>
      PublicListingCatalogue(
        http,
        address: (_, _) => cadalEndpoint,
        referer: cadalHome,
        maxBytes: 1024 << 10,
        requestForm: browse
            ? null
            : (query, page) => {
                'searchContent': query,
                'searchType': switch (field) {
                  PublicationSearchField.title => 'title',
                  PublicationSearchField.author => 'creator',
                  _ => 'sw',
                },
                'oneOrSecond': 'first',
                'currentPage': '$page',
              },
        parse: parseCadalCatalogue,
      );

  Future<void> _authorizeSearch(CancellationToken token) async {
    final body = await publicListingText(
      http,
      _permissionEndpoint,
      token,
      maxBytes: 4 << 10,
      referer: cadalHome,
      form: const {'prefixKey': 'cadal_clock_search_user_'},
    );
    final response = jsonDecode(body);
    if (response case {'msg': 10000 || '10000'}) return;
    throw const PublicationFailure(PublicationProblem.challenge);
  }

  @override
  Future<void> check(CancellationToken token) async {
    await _authorizeSearch(token);
    await _listing(null, true).check(token);
  }

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
    await _authorizeSearch(token);
    return _listing(filter?.field, query.isEmpty).search(
      query,
      token,
      maxPages: query.isEmpty ? 1 : maxPages,
      allowed: allowed,
      filter: filter,
      onProgress: onProgress,
    );
  }
}

PublicationListingPage parseCadalCatalogue(String body) {
  final document = html.parse(body);
  final list = document.querySelector('.resultList ul.results-list');
  if (list == null) throw const PublicationFailure(PublicationProblem.invalid);
  final books = <String, PublicationEdition>{};
  for (final row in list.children.where((entry) => entry.localName == 'li')) {
    final anchor = row.querySelector('dl dt a.title');
    final title = publicationLabel(anchor?.text);
    final action = anchor?.attributes['onclick'] ?? '';
    final group = _groupAction.firstMatch(action);
    final id =
        _bookAction.firstMatch(action)?[1] ??
        (group != null && _bookGroups.contains(group[2]) ? group[1] : null);
    if (id == null || title.isEmpty) continue;
    final credits = <String, String>{};
    for (final detail in row.querySelectorAll('dl > dd')) {
      final text = publicationLabel(detail.text);
      final colon = text.indexOf('：');
      if (colon > 0 && colon <= 6) {
        credits[text.substring(0, colon)] = text.substring(colon + 1).trim();
      }
    }
    final page = cadalHome
        .resolve('/cardpage/bookCardPage')
        .replace(queryParameters: {'ssno': id});
    books[id] = PublicationEdition(
      id: publicationId('$cadalPublicationSource\n$id'),
      title: title,
      author: credits['作者'] ?? '',
      publisher: credits['出版社'] ?? '',
      edition: group == null ? '' : '代表馆藏',
      page: page,
      cover: publicationCoverUrl(
        page,
        row.querySelector('.imgBox img[src]')?.attributes['src'],
        _cadalCover,
      ),
    );
  }
  final current = int.tryParse(
    document.querySelector('.pagination a.active')?.text.trim() ?? '',
  );
  final last = document
      .querySelector('.pagination a#lastPage')
      ?.attributes['href'];
  final lastPage = int.tryParse(
    Uri.tryParse(last ?? '')?.queryParameters['currentPage'] ?? '',
  );
  return (
    books: books.values.toList(),
    hasNext: current != null && lastPage != null && current < lastPage,
  );
}

bool _cadalCover(Uri uri) {
  if (uri.origin != cadalHome.origin || uri.path != '/cx/png/image/cover') {
    return false;
  }
  final query = uri.queryParametersAll;
  return query.keys.every(const {'p', 'ds', 'isbn', 'a'}.contains) &&
      query.values.every((items) => items.length == 1) &&
      _coverFile.hasMatch(uri.queryParameters['p'] ?? '') &&
      _coverSignature.hasMatch(uri.queryParameters['a'] ?? '');
}
