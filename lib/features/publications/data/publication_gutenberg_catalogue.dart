import 'package:flutter/services.dart' show rootBundle;
import 'package:xml/xml.dart';

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_gutenberg_index.dart';
import 'publication_http.dart';
import 'publication_search_text.dart';

const gutenbergPublicationSource = 'project-gutenberg-mirror';
const _site = 'www.gutenberg.org';
const _mirror = 'gutenberg.pglaf.org';
const _rdf = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#';
const _pg = 'http://www.gutenberg.org/2009/pgterms/';
const _dc = 'http://purl.org/dc/terms/';
const _rights = 'Public domain in the USA.';
final _idPath = RegExp(r'^/ebooks/([1-9][0-9]{0,6})$');
final _word = RegExp(r'[\p{L}\p{M}\p{N}]+', unicode: true);
final gutenbergCataloguePage = Uri.https(_site, '/ebooks/');
final gutenbergCatalogueEndpoint = Uri.https(
  _mirror,
  '/cache/epub/feeds/today.rss',
);

final class GutenbergCatalogue
    implements
        DownloadablePublicationCatalogue,
        ProgressivePublicationCatalogue {
  GutenbergCatalogue(this.http);
  final PublicationHttp http;
  Future<List<GutenbergBook>>? _index;

  @override
  Future<void> check(CancellationToken token) async {
    await _discover(token);
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
    final List<GutenbergBook> books;
    if (query.isEmpty) {
      books = await _discover(token);
    } else {
      books = await _findBooks(query, token, allowed, filter);
    }
    final visible = books
        .where((book) => allowed('${book.title} ${book.author}'))
        .take(query.isEmpty ? 12 : 8)
        .toList();
    final partial = {for (final book in visible) book.id: _edition(book)};
    if (partial.isNotEmpty) await onProgress?.call(partial.values.toList());
    final results = await Future.wait([
      for (final book in visible)
        _resolveEdition(book, token).then((edition) async {
          if (edition != null && edition.hasDownload) {
            partial[book.id] = edition;
            await onProgress?.call(partial.values.toList());
          }
          return edition;
        }),
    ]);
    token.check();
    return results.nonNulls
        .where((book) => allowed('${book.title} ${book.author}'))
        .toList();
  }

  Future<List<GutenbergBook>> _findBooks(
    String query,
    CancellationToken token,
    bool Function(String) allowed,
    PublicationFieldSearch? filter,
  ) async {
    if (filter?.field == PublicationSearchField.isbn) return const [];
    final folding = publicationHanText.hasMatch(query)
        ? await publicationHanFold()
        : const <int, int>{};
    String normalize(String text) {
      final lower = text.toLowerCase();
      return folding.isEmpty || !publicationHanText.hasMatch(lower)
          ? lower
          : String.fromCharCodes(
              lower.runes.map((rune) => folding[rune] ?? rune),
            );
    }

    final needle = normalize(query);
    final words = _word
        .allMatches(needle)
        .take(12)
        .map((word) => word[0]!)
        .toList();
    if (words.isEmpty) return const [];
    final index = await (_index ??= _loadIndex());
    token.check();
    final exact = <GutenbergBook>[];
    final related = <GutenbergBook>[];
    for (final (position, book) in index.indexed) {
      if (position != 0 && position % 512 == 0) {
        await Future<void>.delayed(Duration.zero);
        token.check();
      }
      if (folding.isNotEmpty &&
          !publicationHanText.hasMatch('${book.title}${book.author}')) {
        continue;
      }
      final matches =
          filter?.matchesFields(title: book.title, author: book.author) ??
          words.every(normalize('${book.title} ${book.author}').contains);
      if (!matches || !allowed('${book.title} ${book.author}')) {
        continue;
      }
      final primary = filter?.field == PublicationSearchField.author
          ? book.author
          : book.title;
      if (normalize(primary) == needle) {
        exact.add(book);
        if (exact.length >= 8) break;
      } else if (related.length < 8) {
        related.add(book);
      }
    }
    return [...exact, ...related];
  }

  Future<PublicationEdition?> _resolveEdition(
    GutenbergBook book,
    CancellationToken token,
  ) async {
    try {
      final licensed = await _record(book.id, token);
      return licensed == null ? null : _edition(licensed, canDownload: true);
    } on Exception catch (error) {
      token.check();
      if (error is PublicationFailure &&
          const {
            PublicationProblem.missing,
            PublicationProblem.invalid,
          }.contains(error.problem)) {
        return _edition(book);
      }
      if (!isPublicationNetworkFailure(error)) rethrow;
      return _edition(book);
    }
  }

  @override
  Future<PublicationDownload> download(
    AcquisitionCandidate candidate,
    CancellationToken token,
  ) async {
    final id = _bookId(candidate.page?.toString());
    if (id == null ||
        candidate.source != gutenbergPublicationSource ||
        candidate.format != PublicationFormat.epub ||
        candidate.link != _asset(id)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    if (await _record(id, token) == null) {
      throw const PublicationFailure(PublicationProblem.missing);
    }
    final target = _asset(id);
    return PublicationDownload(
      target,
      scope: (uri) => _requireAddress(uri, target),
    );
  }

  Future<List<GutenbergBook>> _discover(CancellationToken token) async {
    final raw = await _text(gutenbergCatalogueEndpoint, token);
    final channel = _parseXml(
      raw,
    ).childElements.singleOrNull?.getElement('channel');
    if (channel == null) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    return [
      for (final item in channel.findElements('item'))
        if (_bookId(item.getElement('link')?.innerText) case final id?)
          (
            id: id,
            title: publicationLabel(item.getElement('title')?.innerText),
            author: '',
            language: '',
          ),
    ];
  }

  Future<List<GutenbergBook>> _loadIndex() async {
    final data = await rootBundle.load(gutenbergIndexAsset);
    return decodeGutenbergIndex(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }

  Future<GutenbergBook?> _record(int id, CancellationToken token) async {
    final uri = Uri.https(_mirror, '/cache/epub/$id/pg$id.rdf');
    return parseGutenbergRecord(await _text(uri, token), id);
  }

  Future<String> _text(Uri address, CancellationToken token) => http.text(
    address,
    token,
    maxBytes: 256 << 10,
    deadline: publicationCatalogueDeadline,
    scope: (uri) => _requireAddress(uri, address),
  );
}

GutenbergBook? parseGutenbergRecord(String body, int id) {
  final root = _parseXml(body).childElements.singleOrNull;
  if (root?.namespaceUri != _rdf || root?.localName != 'RDF') {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final ebook = root?.getElement('ebook', namespaceUri: _pg);
  if (ebook == null ||
      ebook.getAttribute('about', namespaceUri: _rdf) != 'ebooks/$id' ||
      ebook.getElement('rights', namespaceUri: _dc)?.innerText.trim() !=
          _rights ||
      ebook.getElement('publisher', namespaceUri: _dc)?.innerText.trim() !=
          'Project Gutenberg' ||
      _rdfValue(ebook.getElement('type', namespaceUri: _dc)) != 'Text') {
    return null;
  }
  final epub = Uri.https(_site, '/ebooks/$id.epub.images').toString();
  final formats = ebook.findElements('hasFormat', namespaceUri: _dc);
  if (!formats.any((entry) {
    final file = entry.getElement('file', namespaceUri: _pg);
    return file?.getAttribute('about', namespaceUri: _rdf) == epub &&
        file
                ?.getElement('isFormatOf', namespaceUri: _dc)
                ?.getAttribute('resource', namespaceUri: _rdf) ==
            'ebooks/$id' &&
        _rdfValue(file?.getElement('format', namespaceUri: _dc)) ==
            'application/epub+zip';
  })) {
    return null;
  }
  final title = publicationLabel(
    ebook.getElement('title', namespaceUri: _dc)?.innerText,
  );
  if (title.isEmpty) return null;
  final authors = ebook
      .findElements('creator', namespaceUri: _dc)
      .take(12)
      .map(
        (creator) => creator
            .getElement('agent', namespaceUri: _pg)
            ?.getElement('name', namespaceUri: _pg)
            ?.innerText,
      )
      .nonNulls
      .join('、');
  final languages = ebook
      .findElements('language', namespaceUri: _dc)
      .take(12)
      .map(_rdfValue)
      .where((code) => code.isNotEmpty)
      .join('、');
  return (
    id: id,
    title: title,
    author: publicationLabel(authors),
    language: publicationLabel(languages),
  );
}

String _rdfValue(XmlElement? element) =>
    element
        ?.getElement('Description', namespaceUri: _rdf)
        ?.getElement('value', namespaceUri: _rdf)
        ?.innerText
        .trim() ??
    '';

XmlDocument _parseXml(String body) {
  try {
    final document = XmlDocument.parse(body);
    if (!document.children.any((node) => node is XmlDoctype)) return document;
  } on XmlException {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  throw const PublicationFailure(PublicationProblem.invalid);
}

int? _bookId(String? raw) {
  if (raw == null || raw.length > 160) return null;
  final uri = Uri.tryParse(raw.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != _site ||
      uri.port != 443 ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  return int.tryParse(_idPath.firstMatch(uri.path)?.group(1) ?? '');
}

Uri _asset(int id) => Uri.https(_mirror, '/cache/epub/$id/pg$id-images.epub');

PublicationEdition _edition(GutenbergBook book, {bool canDownload = false}) {
  final page = Uri.https(_site, '/ebooks/${book.id}');
  return PublicationEdition(
    id: publicationId('$gutenbergPublicationSource\n${book.id}'),
    title: book.title,
    author: book.author,
    language: book.language,
    page: page,
    edition: 'Project Gutenberg #${book.id}',
    license: canDownload ? '美国公版 · Project Gutenberg' : '',
    candidates: [
      if (canDownload)
        AcquisitionCandidate(
          source: gutenbergPublicationSource,
          format: PublicationFormat.epub,
          page: page,
          link: _asset(book.id),
        ),
    ],
  );
}

void _requireAddress(Uri uri, Uri expected) {
  if (uri != expected) {
    throw const PublicationFailure(PublicationProblem.unsupported);
  }
}
