import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';

const standardEbooksPublicationSource = 'standard-ebooks-public';
const _host = 'standardebooks.org';
const _atom = 'http://www.w3.org/2005/Atom';
const _license = '美国公版 · Standard Ebooks 制作部分为 CC0 1.0';
const _cc0 = 'https://creativecommons.org/publicdomain/zero/1.0/';
final standardEbooksCatalogueEndpoint = Uri.https(
  _host,
  '/feeds/atom/new-releases',
);
final standardEbooksCataloguePage = Uri.https(_host, '/ebooks');
final _pagePath = RegExp(r'^/ebooks(?:/[a-z0-9]+(?:-[a-z0-9]+)*){2,4}$');

final class StandardEbooksCatalogue
    implements DownloadablePublicationCatalogue {
  const StandardEbooksCatalogue(this.http);
  final PublicationHttp http;

  @override
  Future<void> check(CancellationToken token) async {
    await _latest(token);
  }

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
  }) async {
    if (query.isEmpty) {
      return [
        for (final book in await _latest(token))
          if (allowed('${book.title} ${book.author}')) book,
      ];
    }
    const pageSize = 12;
    final found = <String, PublicationEdition>{};
    for (var page = 1; page <= maxPages; page++) {
      final uri = standardEbooksCataloguePage.replace(
        queryParameters: {
          'query': query,
          'per-page': '$pageSize',
          'page': '$page',
        },
      );
      final List<PublicationEdition> rows;
      try {
        rows = parseStandardEbooksSearch(await _read(uri, token));
      } on Exception catch (error) {
        token.check();
        if (page == 1 || !isPublicationNetworkFailure(error)) rethrow;
        break;
      }
      for (final book in rows) {
        if ((filter?.matches(book) ?? true) &&
            allowed('${book.title} ${book.author}')) {
          found.putIfAbsent(book.id, () => book);
        }
      }
      if (rows.length < pageSize || found.length >= pageSize) break;
    }
    return Future.wait(
      found.values.take(pageSize).map((book) async {
        try {
          final link = parseStandardEbooksDetails(
            await _read(book.page!, token),
            book.page!,
          );
          return link == null
              ? book
              : book.withCandidates([_candidate(book.page!, link)]);
        } on RequestCancelled {
          rethrow;
        } on Exception {
          token.check();
          return book;
        }
      }),
    );
  }

  @override
  Future<PublicationDownload> download(
    AcquisitionCandidate candidate,
    CancellationToken token,
  ) async {
    final page = _bookPage(candidate.page?.toString());
    if (page == null ||
        candidate.source != standardEbooksPublicationSource ||
        candidate.format != PublicationFormat.epub ||
        candidate.link != _compatibleEpub(page)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final link = parseStandardEbooksDetails(await _read(page, token), page);
    if (link == null || _candidate(page, link).id != candidate.id) {
      throw const PublicationFailure(PublicationProblem.missing);
    }
    final target = await _downloadAddress(link, token);
    return PublicationDownload(
      target,
      scope: (uri) => _requireAddress(uri, target),
    );
  }

  Future<Uri> _downloadAddress(Uri link, CancellationToken token) =>
      withPublicationRequestDeadline(token, publicationCatalogueDeadline, (
        request,
      ) async {
        void restrict(Uri uri) => _requireAddress(uri, link);
        final response = await http.open(link, request, scope: restrict);
        if (response.response.statusCode == 200 &&
            response.response.headers.contentType?.mimeType ==
                'application/epub+zip') {
          await discardPublicationResponse(response);
          return link;
        }
        final body = await http.readText(
          response,
          request,
          maxBytes: 128 << 10,
          scope: restrict,
        );
        final target = parseStandardEbooksDownloadPage(body, link);
        if (target == null) {
          throw const PublicationFailure(PublicationProblem.invalid);
        }
        return target;
      });

  Future<List<PublicationEdition>> _latest(CancellationToken token) async {
    return parseStandardEbooksFeed(
      await _read(standardEbooksCatalogueEndpoint, token),
    );
  }

  Future<String> _read(Uri uri, CancellationToken token) => http.text(
    uri,
    token,
    maxBytes: 512 << 10,
    deadline: publicationCatalogueDeadline,
    scope: (target) => _requireAddress(target, uri),
  );
}

List<PublicationEdition> parseStandardEbooksFeed(String body) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(body);
  } on XmlException {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final feed = document.childElements.singleOrNull;
  if (feed == null ||
      feed.localName != 'feed' ||
      feed.namespaceUri != _atom ||
      document.children.any((node) => node is XmlDoctype)) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <Uri, PublicationEdition>{};
  for (final row in feed.findElements('entry', namespaceUri: _atom)) {
    final page = _bookPage(_atomText(row, 'id'));
    final title = publicationLabel(_atomText(row, 'title'));
    if (page == null || title.isEmpty) continue;
    final rights = _atomText(row, 'rights') ?? '';
    final epub = _compatibleEpub(page);
    final published = epub.replace(queryParameters: {'source': 'feed'});
    final hasEpub =
        rights.startsWith('Public domain in the United States.') &&
        rights.contains('Creative Commons CC0 1.0') &&
        row
            .findElements('link', namespaceUri: _atom)
            .any(
              (link) =>
                  link.getAttribute('rel') == 'enclosure' &&
                  link.getAttribute('type') == 'application/epub+zip' &&
                  link.getAttribute('href') == published.toString(),
            );
    final author = row
        .findElements('author', namespaceUri: _atom)
        .map((person) => publicationLabel(_atomText(person, 'name')))
        .where((name) => name.isNotEmpty)
        .join('、');
    books.putIfAbsent(
      page,
      () => _book(
        page,
        title,
        author,
        candidates: [if (hasEpub) _candidate(page, epub)],
      ),
    );
  }
  if (books.isEmpty) throw const PublicationFailure(PublicationProblem.invalid);
  return books.values.toList();
}

List<PublicationEdition> parseStandardEbooksSearch(String body) {
  final document = html.parse(body);
  final list = document.querySelector('ol.ebooks-list');
  if (list == null) {
    if (document.querySelector('main.ebooks .no-results') != null) {
      return const [];
    }
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <Uri, PublicationEdition>{};
  for (final row in list.children) {
    final anchor = row.querySelector('p a[property="schema:url"]');
    final page = _bookPage(row.attributes['about']);
    final title = publicationLabel(anchor?.text);
    if (page == null ||
        title.isEmpty ||
        _bookPage(anchor?.attributes['href']) != page) {
      continue;
    }
    books.putIfAbsent(
      page,
      () => _book(
        page,
        title,
        publicationLabel(row.querySelector('p.author')?.text),
        cover: publicationCoverUrl(
          page,
          row.querySelector('picture img')?.attributes['src'],
          (uri) =>
              uri.host == _host &&
              uri.path.startsWith('/images/covers/') &&
              uri.path.endsWith('.jpg'),
        ),
      ),
    );
  }
  return books.values.toList();
}

Uri? parseStandardEbooksDetails(String body, Uri page) {
  final article = html.parse(body).querySelector('article.ebook');
  final offer = article?.querySelector('section#read-free');
  if (_bookPage(article?.attributes['about']) != page ||
      offer
              ?.querySelector('meta[property="schema:license"]')
              ?.attributes['content'] !=
          _cc0) {
    return null;
  }
  final epub = _compatibleEpub(page);
  final link = offer?.querySelector('#download a.epub')?.attributes['href'];
  if (link == null || page.resolve(link) != epub) return null;
  return epub;
}

Uri? parseStandardEbooksDownloadPage(String body, Uri file) {
  // The public download page uses an immediate, same-file HTML refresh.
  final refresh = html
      .parse(body)
      .querySelector('head meta[http-equiv="refresh"]')
      ?.attributes['content'];
  if (refresh == null || refresh.length > 600) return null;
  final target = RegExp(
    r'^0\s*;\s*url=(.+)$',
    caseSensitive: false,
  ).firstMatch(refresh.trim())?.group(1);
  final uri = target == null ? null : file.resolve(target.trim());
  final expected = file.replace(queryParameters: {'source': 'download'});
  return uri == expected ? uri : null;
}

String? _atomText(XmlElement row, String name) =>
    row.getElement(name, namespaceUri: _atom)?.innerText;

Uri? _bookPage(String? raw) {
  if (raw == null || raw.length > 400) return null;
  final reference = Uri.tryParse(raw);
  if (reference == null) return null;
  final page = standardEbooksCataloguePage.resolveUri(reference);
  return page.scheme == 'https' &&
          page.host == _host &&
          page.port == 443 &&
          page.userInfo.isEmpty &&
          !page.hasQuery &&
          !page.hasFragment &&
          _pagePath.hasMatch(page.path)
      ? page
      : null;
}

Uri _compatibleEpub(Uri page) => page.replace(
  path: '${page.path}/downloads/${page.pathSegments.skip(1).join('_')}.epub',
);

AcquisitionCandidate _candidate(Uri page, Uri file) => AcquisitionCandidate(
  source: standardEbooksPublicationSource,
  page: page,
  link: file,
  format: PublicationFormat.epub,
);

PublicationEdition _book(
  Uri page,
  String title,
  String author, {
  Uri? cover,
  List<AcquisitionCandidate> candidates = const [],
}) => PublicationEdition(
  id: publicationId('$standardEbooksPublicationSource\n${page.path}'),
  title: title,
  author: author,
  license: _license,
  publisher: 'Standard Ebooks',
  cover: cover,
  page: page,
  candidates: candidates,
);

void _requireAddress(Uri actual, Uri expected) {
  if (actual != expected) {
    throw const PublicationFailure(PublicationProblem.unsupported);
  }
}
