import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';

const tadokuSource = 'tadoku-free';
final tadokuCatalogueEndpoint = Uri.https(
  'tadoku.org',
  '/japanese/free-books/',
);
const _license = 'CC BY-NC-ND 4.0';
final _licenseUri = Uri.https('creativecommons.org', '/licenses/by-nc-nd/4.0/');
final _bookPath = RegExp(r'^/japanese/book/([1-9][0-9]{0,9})/$');
final _uploadDirectory = RegExp(
  r'^/japanese/wp-content/uploads/(?:[0-9]{4}/[0-9]{2}/)?$',
);
final _pdfFile = RegExp(
  r'^[^/\\\x00-\x1f\x7f]{1,240}\.pdf$',
  caseSensitive: false,
);

typedef TadokuListing = ({
  Uri page,
  String title,
  String level,
  String keywords,
});

final class TadokuCatalogue implements DownloadablePublicationCatalogue {
  const TadokuCatalogue(this.http);

  final PublicationHttp http;

  @override
  Future<void> check(CancellationToken token) async {
    await _list(token);
  }

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
  }) async {
    final terms = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty);
    final matches = (await _list(token))
        .where((entry) {
          if (!allowed(entry.title)) return false;
          if (filter?.field == PublicationSearchField.title) {
            return filter!.matchesFields(title: entry.title);
          }
          if (terms.every(entry.title.toLowerCase().contains)) return true;
          final keywords = _text(
            html.parseFragment(entry.keywords),
            max: 4096,
          ).toLowerCase();
          return terms.every(keywords.contains);
        })
        .take(6 * maxPages.clamp(1, 3))
        .toList();
    final result = <PublicationEdition>[];
    for (var index = 0; index < matches.length; index += 3) {
      token.check();
      final editions = await Future.wait(
        matches
            .skip(index)
            .take(3)
            .map((entry) => _detail(entry.page, token, level: entry.level)),
      );
      result.addAll(
        editions.whereType<PublicationEdition>().where(
          (edition) =>
              (filter?.matches(edition) ?? true) &&
              allowed('${edition.title} ${edition.author}'),
        ),
      );
    }
    return result;
  }

  @override
  Future<PublicationDownload> download(
    AcquisitionCandidate candidate,
    CancellationToken token,
  ) async {
    final page = candidate.page;
    final id = page == null ? null : _bookId(page);
    if (page == null ||
        id == null ||
        id != candidate.fileId ||
        candidate.source != tadokuSource ||
        candidate.format != PublicationFormat.pdf ||
        !_isTadokuPdf(candidate.link)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final edition = await _detail(page, token);
    if (edition?.candidates.single.link != candidate.link) {
      throw const PublicationFailure(PublicationProblem.missing);
    }
    return PublicationDownload(
      candidate.link,
      scope: (uri) => _restrict(uri, candidate.link),
    );
  }

  Future<List<TadokuListing>> _list(CancellationToken token) async {
    final entries = parseTadokuListing(
      await http.text(
        tadokuCatalogueEndpoint,
        token,
        scope: (uri) => _restrict(uri, tadokuCatalogueEndpoint),
      ),
    );
    if (entries.isEmpty) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    return entries;
  }

  Future<PublicationEdition?> _detail(
    Uri page,
    CancellationToken token, {
    String level = '',
  }) async {
    try {
      return parseTadokuBook(
        await http.text(
          page,
          token,
          maxBytes: 1 << 20,
          scope: (uri) => _restrict(uri, page),
        ),
        page,
        level: level,
      );
    } on PublicationFailure catch (error) {
      if (error.problem == PublicationProblem.missing) return null;
      rethrow;
    }
  }
}

List<TadokuListing> parseTadokuListing(String input) {
  final document = html.parse(input);
  final entries = <Uri, TadokuListing>{};
  for (final card in document.querySelectorAll(
    '#freebooks-results .freebooks-book-item',
  )) {
    final anchor = card.querySelector('.bl-title a[href]');
    final page = _href(tadokuCatalogueEndpoint, anchor);
    final title = _text(anchor);
    if (page == null || _bookId(page) == null || title.isEmpty) continue;
    entries.putIfAbsent(
      page,
      () => (
        page: page,
        title: title,
        level: card.attributes['data-level'] ?? '',
        keywords: card.attributes['data-keywords'] ?? '',
      ),
    );
  }
  return entries.values.toList();
}

PublicationEdition? parseTadokuBook(
  String input,
  Uri page, {
  String level = '',
}) {
  final id = _bookId(page);
  if (id == null) return null;
  final document = html.parse(input);
  if (_href(page, document.querySelector('link[rel="canonical"]')) != page) {
    return null;
  }
  final book = document.querySelector('article#post-$id.type-book');
  if (book == null ||
      !book
          .querySelectorAll('.bd-note a[href]')
          .any((anchor) => _href(page, anchor) == _licenseUri)) {
    return null;
  }
  final title = _text(book.querySelector('.bd-title h1'));
  final pdfs = <Uri>{};
  for (final anchor in book.querySelectorAll(
    '.bd-lookinside-pdf a[href][download]',
  )) {
    final target = _href(page, anchor);
    final label = _text(anchor).replaceAll(RegExp(r'\s+'), '');
    if (target != null &&
        label.startsWith('PDF(電子本)') &&
        _isTadokuPdf(target)) {
      pdfs.add(target);
    }
  }
  if (title.isEmpty || pdfs.length != 1) return null;
  final author = book
      .querySelectorAll('.bd-author li')
      .map(_text)
      .where((value) => value.isNotEmpty)
      .take(4)
      .join(' / ');
  return PublicationEdition(
    id: publicationId('tadoku:$id'),
    title: title,
    author: publicationLabel(author),
    language: '日本語',
    edition: switch (level) {
      'l-start' => 'Level Start',
      'l0' ||
      'l1' ||
      'l2' ||
      'l3' ||
      'l4' ||
      'l5' => 'Level ${level.substring(1)}',
      _ => '',
    },
    license: _license,
    page: page,
    candidates: [
      AcquisitionCandidate(
        source: tadokuSource,
        link: pdfs.single,
        page: page,
        format: PublicationFormat.pdf,
        fileId: id,
      ),
    ],
  );
}

String _text(Node? node, {int max = 160}) {
  if (node == null) return '';
  final copy = node.clone(true);
  if (copy is Element) {
    for (final ruby in copy.querySelectorAll('rt, rp')) {
      ruby.remove();
    }
  } else if (copy is DocumentFragment) {
    for (final ruby in copy.querySelectorAll('rt, rp')) {
      ruby.remove();
    }
  }
  return publicationLabel(copy.text, max: max);
}

Uri? _href(Uri base, Element? element) {
  final raw = element?.attributes['href'];
  final uri = raw == null ? null : Uri.tryParse(raw.trim());
  return uri == null ? null : base.resolveUri(uri);
}

bool _isTadokuUrl(Uri uri) =>
    uri.scheme == 'https' &&
    uri.port == 443 &&
    uri.userInfo.isEmpty &&
    uri.host == 'tadoku.org' &&
    !uri.hasQuery &&
    !uri.hasFragment;

String? _bookId(Uri uri) =>
    _isTadokuUrl(uri) ? _bookPath.firstMatch(uri.path)?.group(1) : null;

bool _isTadokuPdf(Uri uri) {
  if (!_isTadokuUrl(uri) || uri.pathSegments.isEmpty) return false;
  final directory = uri.path.substring(0, uri.path.lastIndexOf('/') + 1);
  return _uploadDirectory.hasMatch(directory) &&
      _pdfFile.hasMatch(uri.pathSegments.last);
}

void _restrict(Uri uri, Uri expected) {
  if (uri != expected) {
    throw const PublicationFailure(PublicationProblem.unsupported);
  }
}
