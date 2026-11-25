import 'dart:convert';

import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';

const planetPublicationSource = 'planet-ebook-classics';
const _host = 'www.planetebook.com';
final planetCataloguePage = Uri.https(_host, '/authors/');
final planetCatalogueEndpoint = Uri.https(_host, '/wp-json/wp/v2/pages/12072', {
  '_fields': 'id,link,content',
});
final _slug = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');
const _extensions = {
  'epub': PublicationFormat.epub,
  'pdf': PublicationFormat.pdf,
  'mobi': PublicationFormat.mobi,
};

final class PlanetCatalogue implements DownloadablePublicationCatalogue {
  PlanetCatalogue(this.http);
  final PublicationHttp http;
  ({DateTime expires, List<PublicationEdition> books})? _recent;

  @override
  Future<void> check(CancellationToken token) async {
    await _books(token, refresh: true);
  }

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
  }) async {
    if (filter?.field == PublicationSearchField.isbn) return const [];
    final rows = (await _books(token))
        .where(
          (book) =>
              book.matches(query, filter: filter) &&
              allowed('${book.title} ${book.author}'),
        )
        .take(20 * maxPages.clamp(1, 5))
        .toList();
    if (query.isNotEmpty) {
      final exact = rows.indexWhere(
        (book) => book.title.toLowerCase() == query.toLowerCase(),
      );
      if (exact > 0) rows.insert(0, rows.removeAt(exact));
    }
    final enriched = await Future.wait(
      rows.take(6).map((book) async {
        try {
          return book.withCandidates(await _files(book.page!, token));
        } on Exception catch (error) {
          token.check();
          if (error is PublicationFailure &&
              error.problem == PublicationProblem.blocked) {
            rethrow;
          }
          return book;
        }
      }),
    );
    return [...enriched, ...rows.skip(enriched.length)];
  }

  @override
  Future<PublicationDownload> download(
    AcquisitionCandidate candidate,
    CancellationToken token,
  ) async {
    final page = candidate.page;
    if (candidate.source != planetPublicationSource ||
        page == null ||
        _bookPage(page.toString()) != page) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final links = await _files(page, token);
    if (!links.any((item) => item.id == candidate.id)) {
      throw const PublicationFailure(PublicationProblem.missing);
    }
    final link = candidate.link;
    return PublicationDownload(
      link,
      scope: (target) => _restrict(target, link),
    );
  }

  Future<List<PublicationEdition>> _books(
    CancellationToken token, {
    bool refresh = false,
  }) async {
    token.check();
    http.authorize(planetCatalogueEndpoint);
    final recent = _recent;
    if (!refresh && recent != null && recent.expires.isAfter(DateTime.now())) {
      return recent.books;
    }
    final books = parsePlanetCatalogue(
      await _json(planetCatalogueEndpoint, token),
    );
    _recent = (
      expires: DateTime.now().add(const Duration(minutes: 10)),
      books: books,
    );
    return books;
  }

  Future<List<AcquisitionCandidate>> _files(
    Uri page,
    CancellationToken token,
  ) async {
    final address = Uri.https(_host, '/wp-json/wp/v2/posts', {
      'slug': page.pathSegments.first,
      '_fields': 'id,link,content',
    });
    final payload = await _json(address, token);
    if (payload is! List || payload.length != 1) return const [];
    return parsePlanetDownloads(payload.single, page);
  }

  Future<Object?> _json(Uri address, CancellationToken token) async =>
      jsonDecode(
        await http.text(
          address,
          token,
          maxBytes: 320 << 10,
          allowGzip: true,
          deadline: const Duration(seconds: 9),
          scope: (target) => _restrict(target, address),
        ),
      );
}

List<PublicationEdition> parsePlanetCatalogue(Object? payload) {
  if (payload case {
    'id': 12072,
    'link': final String link,
    'content': {'rendered': final String body},
  } when Uri.tryParse(link) == planetCataloguePage) {
    final document = html.parseFragment(body);
    final entries = <Uri, PublicationEdition>{};
    var author = '';
    for (final row in document.querySelectorAll('h6.peauthor, p.pelistlinks')) {
      if (row.localName == 'h6') {
        author = publicationLabel(row.text);
        continue;
      }
      if (author.isEmpty) continue;
      for (final item in row.querySelectorAll('a[href]')) {
        final page = _bookPage(item.attributes['href']);
        final title = publicationLabel(item.text);
        if (page == null || title.isEmpty) continue;
        entries.putIfAbsent(
          page,
          () => PublicationEdition(
            id: publicationId('$planetPublicationSource\n$page'),
            title: title,
            author: author,
            publisher: 'Planet eBook',
            language: 'en',
            license: 'Planet eBook · 标注澳大利亚公版',
            page: page,
          ),
        );
      }
    }
    if (entries.isNotEmpty && entries.length <= 250) {
      return entries.values.toList();
    }
  }
  throw const PublicationFailure(PublicationProblem.invalid);
}

List<AcquisitionCandidate> parsePlanetDownloads(Object? payload, Uri page) {
  if (_bookPage(page.toString()) != page) return const [];
  if (payload case {
    'link': final String link,
    'content': {'rendered': final String body},
  } when Uri.tryParse(link) == page) {
    final slug = page.pathSegments.first;
    final files = {
      for (final MapEntry(key: extension, value: format) in _extensions.entries)
        Uri.https(_host, '/free-ebooks/$slug.$extension'): format,
    };
    final anchors = html
        .parseFragment(body)
        .querySelectorAll('a.buttonpe[href]');
    final candidates = <Uri, AcquisitionCandidate>{};
    for (final anchor in anchors) {
      final raw = anchor.attributes['href']!;
      if (raw.length > 200) continue;
      final reference = Uri.tryParse(raw);
      if (reference == null) continue;
      final address = page.resolveUri(reference);
      final format = files[address];
      if (format == null) continue;
      candidates[address] = AcquisitionCandidate(
        source: planetPublicationSource,
        link: address,
        format: format,
        page: page,
      );
    }
    return candidates.values.toList();
  }
  return const [];
}

Uri? _bookPage(String? raw) {
  if (raw == null || raw.length > 200) return null;
  final reference = Uri.tryParse(raw);
  if (reference == null) return null;
  final uri = planetCataloguePage.resolveUri(reference);
  final slug = uri.pathSegments.firstOrNull;
  return slug != null &&
          _slug.hasMatch(slug) &&
          uri == Uri.https(_host, '/$slug/')
      ? uri
      : null;
}

void _restrict(Uri target, Uri address) {
  if (target != address) {
    throw const PublicationFailure(PublicationProblem.unsupported);
  }
}
