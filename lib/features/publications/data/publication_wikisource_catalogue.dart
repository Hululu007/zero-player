import 'dart:convert';

import 'package:xml/xml.dart';

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';

const wikisourcePublicationSource = 'wikisource-en-opds';
const _exportHost = 'ws-export.wmcloud.org';
const _wikiHost = 'en.wikisource.org';
const _atom = 'http://www.w3.org/2005/Atom';
const _issuedNamespace = 'http://purl.org/dc/terms/';
final _rights = RegExp(
  r'^https?://creativecommons\.org/licenses/by-sa/3\.0/?$',
);
final _unsafeTitle = RegExp(r'[\x00-\x1f\x7f\\]');
final wikisourceCatalogueEndpoint = Uri.https(
  _exportHost,
  '/opds/en/Ready_for_export.xml',
);
final wikisourceCataloguePage = Uri.https(
  _wikiHost,
  '/wiki/Category:Ready_for_export',
);

final class WikisourceCatalogue
    implements
        DownloadablePublicationCatalogue,
        ProgressivePublicationCatalogue {
  WikisourceCatalogue(this.http);

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
    Future<void> Function(List<PublicationEdition>)? onProgress,
  }) async {
    final limit = maxPages.clamp(1, 5) * 20;
    List<PublicationEdition> filterExports(List<PublicationEdition> books) =>
        books
            .where(
              (book) =>
                  book.matches(query, filter: filter) &&
                  allowed('${book.title} ${book.author}'),
            )
            .take(limit)
            .toList();
    if (query.isEmpty) return filterExports(await _load(token));

    final editions = <Uri, PublicationEdition>{};
    final failures = <Exception>[];
    List<PublicationEdition> matches() => [
      ...editions.values.where((book) => book.candidates.isNotEmpty),
      ...editions.values.where((book) => book.candidates.isEmpty),
    ].take(limit).toList();
    Future<void> add(Future<List<PublicationEdition>> request) async {
      try {
        final books = await request;
        token.check();
        for (final book in books) {
          if (filter?.matches(book) == false ||
              !allowed('${book.title} ${book.author}')) {
            continue;
          }
          final page = book.page!;
          if (book.candidates.isNotEmpty || !editions.containsKey(page)) {
            editions[page] = book;
          }
        }
        if (editions.isNotEmpty && onProgress != null) {
          await onProgress(matches());
        }
      } on Exception catch (error) {
        token.check();
        if (error is PublicationFailure &&
            error.problem == PublicationProblem.blocked) {
          rethrow;
        }
        failures.add(error);
      }
    }

    await Future.wait([
      add(_searchSite(query, limit, token)),
      add(_load(token).then(filterExports)),
    ]);
    if (editions.isEmpty && failures.isNotEmpty) throw failures.first;
    return matches();
  }

  Future<List<PublicationEdition>> _searchSite(
    String query,
    int limit,
    CancellationToken token,
  ) async {
    final address = Uri.https(_wikiHost, '/w/api.php', {
      'action': 'query',
      'list': 'search',
      'srsearch': query,
      'srnamespace': '0',
      'srlimit': '$limit',
      'srprop': '',
      'format': 'json',
    });
    final data = jsonDecode(
      await http.text(
        address,
        token,
        maxBytes: 128 << 10,
        deadline: const Duration(seconds: 10),
        scope: (uri) => _requireAddress(uri, address),
      ),
    );
    if (data case {
      'query': {'search': final List rows},
    } when rows.length <= limit) {
      return [
        for (final row in rows)
          if (row case {'ns': 0, 'title': final String raw})
            ?_searchEdition(raw),
      ];
    }
    throw const PublicationFailure(PublicationProblem.invalid);
  }

  @override
  Future<PublicationDownload> download(
    AcquisitionCandidate candidate,
    CancellationToken token,
  ) async {
    final page = candidate.page;
    final title = _pageTitle(page);
    if (candidate.source != wikisourcePublicationSource ||
        candidate.format != PublicationFormat.epub ||
        title == null ||
        !_epubFor(candidate.link, title)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final books = await _load(token, refresh: true);
    final current = books
        .where((book) => book.page == page)
        .firstOrNull
        ?.candidates
        .single;
    if (current == null || current.id != candidate.id) {
      throw const PublicationFailure(PublicationProblem.missing);
    }
    return PublicationDownload(
      current.link,
      scope: (uri) => _requireAddress(uri, current.link),
    );
  }

  Future<List<PublicationEdition>> _load(
    CancellationToken token, {
    bool refresh = false,
  }) async {
    token.check();
    http.authorize(wikisourceCatalogueEndpoint);
    final recent = _recent;
    if (!refresh && recent != null && recent.expires.isAfter(DateTime.now())) {
      return recent.books;
    }
    final body = await http.text(
      wikisourceCatalogueEndpoint,
      token,
      maxBytes: 4 << 20,
      deadline: publicationCatalogueDeadline,
      scope: (uri) => _requireAddress(uri, wikisourceCatalogueEndpoint),
    );
    token.check();
    final books = parseWikisourceCatalogue(body);
    // The publisher regenerates the feed daily. Download always checks it live.
    _recent = (
      books: books,
      expires: DateTime.now().add(const Duration(minutes: 5)),
    );
    return books;
  }
}

PublicationEdition? _searchEdition(String raw) {
  final title = publicationLabel(raw);
  if (title.isEmpty ||
      title == '.' ||
      title == '..' ||
      _unsafeTitle.hasMatch(raw) ||
      raw.contains('#')) {
    return null;
  }
  final page = Uri(
    scheme: 'https',
    host: _wikiHost,
    pathSegments: ['wiki', ...title.replaceAll(' ', '_').split('/')],
  );
  final pageTitle = _pageTitle(page);
  if (pageTitle == null) return null;
  return PublicationEdition(
    id: publicationId('$wikisourcePublicationSource\n$pageTitle'),
    title: title,
    language: 'en',
    page: page,
  );
}

List<PublicationEdition> parseWikisourceCatalogue(String body) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(body);
  } on XmlException {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  if (document.children.any((node) => node is XmlDoctype)) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final root = document.childElements.singleOrNull;
  if (root == null || root.localName != 'feed' || root.namespaceUri != _atom) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <Uri, PublicationEdition>{};
  for (final entry in root.findElements('entry', namespaceUri: _atom)) {
    final book = _edition(entry);
    if (book != null) books.putIfAbsent(book.page!, () => book);
  }
  if (books.isEmpty) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  return books.values.toList();
}

PublicationEdition? _edition(XmlElement entry) {
  final page = _uri(entry.getElement('id', namespaceUri: _atom)?.innerText);
  final pageTitle = _pageTitle(page);
  final title = publicationLabel(
    entry.getElement('title', namespaceUri: _atom)?.innerText,
  );
  final rights = entry.getElement('rights', namespaceUri: _atom)?.innerText;
  if (page == null ||
      pageTitle == null ||
      title.isEmpty ||
      rights == null ||
      !_rights.hasMatch(rights)) {
    return null;
  }
  for (final link in entry.findElements('link', namespaceUri: _atom)) {
    final target = _uri(link.getAttribute('href'));
    if (link.getAttribute('rel') != 'http://opds-spec.org/acquisition' ||
        link.getAttribute('type') != 'application/epub+zip' ||
        target == null ||
        !_epubFor(target, pageTitle)) {
      continue;
    }
    final author = entry
        .findElements('author', namespaceUri: _atom)
        .take(12)
        .map(
          (item) => publicationLabel(
            item.getElement('name', namespaceUri: _atom)?.innerText,
          ),
        )
        .where((name) => name.isNotEmpty)
        .join('、');
    return PublicationEdition(
      id: publicationId('$wikisourcePublicationSource\n$pageTitle'),
      title: title,
      author: publicationLabel(author),
      language: 'en',
      edition: publicationLabel(
        entry.getElement('issued', namespaceUri: _issuedNamespace)?.innerText,
      ),
      license: 'CC BY-SA 3.0 · Wikisource OPDS',
      page: page,
      candidates: [
        AcquisitionCandidate(
          source: wikisourcePublicationSource,
          link: target,
          format: PublicationFormat.epub,
          page: page,
        ),
      ],
    );
  }
  return null;
}

Uri? _uri(String? raw) =>
    raw == null || raw.length > 2048 ? null : Uri.tryParse(raw.trim());

bool _host(Uri uri, String host) =>
    uri.scheme == 'https' &&
    uri.host == host &&
    uri.port == 443 &&
    uri.userInfo.isEmpty &&
    !uri.hasFragment;

String? _pageTitle(Uri? uri) {
  if (uri == null || !_host(uri, _wikiHost) || uri.hasQuery) return null;
  final segments = uri.pathSegments;
  if (segments.length < 2 || segments.first != 'wiki') return null;
  final title = segments.skip(1).join('/');
  if (_unsafeTitle.hasMatch(title) ||
      title.split('/').any(const {'', '.', '..'}.contains)) {
    return null;
  }
  return title;
}

bool _epubFor(Uri uri, String title) {
  if (!_host(uri, _exportHost) || uri.path != '/') return false;
  final query = uri.queryParametersAll;
  return query.length == 3 &&
      query['lang']?.singleOrNull == 'en' &&
      query['format']?.singleOrNull == 'epub' &&
      query['page']?.singleOrNull == title;
}

void _requireAddress(Uri uri, Uri expected) {
  if (uri != expected) {
    throw const PublicationFailure(PublicationProblem.unsupported);
  }
}
