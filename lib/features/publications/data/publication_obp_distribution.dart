import 'dart:io';

import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_http.dart';

const _host = 'unglue.it';
const _files = 'files.unglue.it';
const _publisher = 'Open Book Publishers';
final _popular = Uri.https(_host, '/bypub/popular/$_publisher');
final _workPath = RegExp(r'^/work/([1-9][0-9]{0,9})/$');
final _workId = RegExp(r'^[1-9][0-9]{0,9}$');
final _downloadPath = RegExp(r'^/download_ebook/[1-9][0-9]{0,9}/$');
final _asset = RegExp(r'^/ebf/[a-f0-9]{32}\.(pdf|epub)$');
const _licenses = {
  'CC0',
  'CC BY',
  'CC BY-SA',
  'CC BY-ND',
  'CC BY-NC',
  'CC BY-NC-SA',
  'CC BY-NC-ND',
};

typedef ObpHostedCopy = ({Uri link, PublicationFormat format, String license});

final class ObpDistribution {
  ObpDistribution(this.http);
  final PublicationHttp http;
  ({Map<String, String> titles, DateTime expires})? _recent;

  Future<Map<String, String>> titles(CancellationToken token) async {
    token.check();
    http.authorize(_popular);
    final recent = _recent;
    if (recent != null && recent.expires.isAfter(DateTime.now())) {
      return recent.titles;
    }
    final titles = parseObpDistributionIndex(await _read(_popular, token));
    final second = _popular.replace(queryParameters: {'works_unglued': '2'});
    try {
      for (final entry in parseObpDistributionIndex(
        await _read(second, token),
      ).entries) {
        _addTitle(titles, entry.key, entry.value);
      }
    } on Exception catch (error) {
      token.check();
      if (!isPublicationNetworkFailure(error)) rethrow;
      return titles;
    }
    _recent = (
      titles: titles,
      expires: DateTime.now().add(const Duration(minutes: 15)),
    );
    return titles;
  }

  Future<List<ObpHostedCopy>> copies(
    PublicationEdition book,
    String work,
    CancellationToken token,
  ) async {
    if (!_workId.hasMatch(work)) return const [];
    final page = Uri.https(_host, '/work/$work/');
    if (!confirmsObpDistributionEdition(await _read(page, token), page, book)) {
      return const [];
    }
    final downloads = page.resolve('download/');
    return parseObpHostedCopies(await _read(downloads, token), page);
  }

  Future<PublicationDownload> resolve(
    ObpHostedCopy copy,
    CancellationToken token,
  ) => withPublicationRequestDeadline(token, publicationCatalogueDeadline, (
    request,
  ) async {
    final response = await http.open(
      copy.link,
      request,
      scope: (uri) => _requireSameAddress(uri, copy.link),
      redirect: false,
    );
    final target = Uri.tryParse(
      response.response.headers.value(HttpHeaders.locationHeader) ?? '',
    );
    final status = response.response.statusCode;
    await discardPublicationResponse(response);
    if (status != HttpStatus.found) throw publicationHttpFailure(response);
    if (target == null ||
        !_plainHttps(target, _files) ||
        !_asset.hasMatch(target.path) ||
        !target.path.endsWith('.${copy.format.name}')) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    http.authorize(target);
    return PublicationDownload(
      target,
      scope: (uri) => _requireSameAddress(uri, target),
    );
  });

  Future<String> _read(Uri uri, CancellationToken token) => http.text(
    uri,
    token,
    maxBytes: 384 << 10,
    deadline: publicationCatalogueDeadline,
    scope: (target) => _requireSameAddress(target, uri),
  );
}

String obpDistributionTitle(String title) => publicationLabel(title)
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{M}\p{N}]+', unicode: true), ' ')
    .trim();

Map<String, String> parseObpDistributionIndex(String body) {
  final document = html.parse(body);
  final publisher = document.querySelector('.special-user-name a');
  if (publisher?.text.trim() != _publisher ||
      Uri.tryParse(publisher?.attributes['href'] ?? '')?.host !=
          'www.openbookpublishers.com') {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final titles = <String, String>{};
  for (final link in document.querySelectorAll('.white_text p > a[href]')) {
    final id = _workPath.firstMatch(link.attributes['href']!)?.group(1);
    final title = obpDistributionTitle(link.text);
    if (id != null && title.isNotEmpty) _addTitle(titles, title, id);
  }
  return titles;
}

void _addTitle(Map<String, String> titles, String title, String id) {
  final previous = titles[title];
  titles[title] = previous == null || previous == id ? id : '';
}

bool confirmsObpDistributionEdition(
  String body,
  Uri work,
  PublicationEdition book,
) {
  if (book.page == null || book.isbn.isEmpty) return false;
  final document = html.parse(body);
  if (document
          .querySelector('meta[property="og:url"]')
          ?.attributes['content'] !=
      work.toString()) {
    return false;
  }
  final doi = book.page!.path.replaceFirst('/books/', '').toLowerCase();
  final hasDoi = document.querySelectorAll('a[href]').any((link) {
    final address = Uri.tryParse(link.attributes['href']!);
    return address != null &&
        _plainHttps(address, 'doi.org') &&
        address.path.toLowerCase() == '/$doi' &&
        link.text.trim().toLowerCase() == doi;
  });
  return hasDoi &&
      document.querySelectorAll('.editions .metadata').any((edition) {
        final publisher = edition.querySelector('a[href="/pid/all/4639"]');
        return publisher?.text.trim() == _publisher &&
            normalizedIsbn(
                  edition.querySelector('[itemprop="isbn"]')?.text ?? '',
                ) ==
                book.isbn;
      });
}

List<ObpHostedCopy> parseObpHostedCopies(String body, Uri work) {
  final document = html.parse(body);
  if (document.querySelector('h2 a')?.attributes['href'] != work.path) {
    return const [];
  }
  final copies = <ObpHostedCopy>[];
  for (final link in document.querySelectorAll('.ebook_download a[href]')) {
    final path = link.attributes['href']!;
    if (!_downloadPath.hasMatch(path)) continue;
    final icon = link.querySelector('img');
    final format = switch (icon?.attributes['alt']) {
      'pdf at Unglue.it' => PublicationFormat.pdf,
      'epub at Unglue.it' => PublicationFormat.epub,
      _ => null,
    };
    final badge = link.previousElementSibling;
    final license = badge?.querySelector('img')?.attributes['alt'];
    if (format != null &&
        badge?.attributes['href'] == path &&
        license != null &&
        _licenses.contains(license)) {
      copies.add((
        link: Uri.https(_host, path),
        format: format,
        license: license,
      ));
    }
  }
  return copies;
}

bool _plainHttps(Uri address, String host) =>
    address.scheme == 'https' &&
    address.host == host &&
    address.port == 443 &&
    address.userInfo.isEmpty &&
    !address.hasQuery &&
    !address.hasFragment;

void _requireSameAddress(Uri actual, Uri expected) {
  if (actual != expected) {
    throw const PublicationFailure(PublicationProblem.unsupported);
  }
}
