import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';

const pennPublicationSource = 'upenn-online-books';
const _host = 'onlinebooks.library.upenn.edu';
final pennCataloguePage = Uri.https(_host, '/search.html');
final pennCatalogueEndpoint = Uri.https(_host, '/webbin/book/search');
final _recent = Uri.https(_host, '/new.html');
const _recordPath = '/webbin/book/lookupid';
final _identifier = RegExp(r'^[a-z0-9]{1,30}$');
final _by = RegExp(
  r'(?:^|,)\s*(?:also\s+)?by\s+(.+?)(?=,\s*(?:ed\.|illust\.|trans\.|contrib\.)|\s+\(|$)',
  caseSensitive: false,
);
final _role = RegExp(r',\s*(?:ed|illust|trans|contrib)\.\s*:$');

final class PennCatalogue implements PublicationCatalogue {
  const PennCatalogue(this.http);
  final PublicationHttp http;

  @override
  Future<void> check(CancellationToken token) async {
    final document = html.parse(await _read(pennCataloguePage, token));
    if (document.querySelector('form input[name="author"]') == null ||
        document.querySelector('form input[name="title"]') == null) {
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
    final addresses = query.isEmpty
        ? [_recent]
        : [
            if (field != PublicationSearchField.author)
              pennCatalogueEndpoint.replace(
                queryParameters: {'title': query, 'tmode': 'words', 'c': 'x'},
              ),
            if (field != PublicationSearchField.title)
              pennCatalogueEndpoint.replace(
                queryParameters: {
                  'author': query,
                  'amode': 'words',
                  'showtitles': '1',
                  'c': 'x',
                },
              ),
          ];
    final failures = <Exception>[];
    final results = await Future.wait(
      addresses.map((address) async {
        try {
          return parsePennCatalogue(await _read(address, token));
        } on Exception catch (error) {
          token.check();
          if (error is PublicationFailure &&
              error.problem == PublicationProblem.blocked) {
            rethrow;
          }
          failures.add(error);
          return const <PublicationEdition>[];
        }
      }),
    );
    if (failures.length == addresses.length) throw failures.first;
    final seen = <String>{};
    return results
        .expand((books) => books)
        .where(
          (book) =>
              (filter?.matches(book) ?? true) &&
              allowed('${book.title} ${book.author}') &&
              seen.add(book.id),
        )
        .take(20 * maxPages.clamp(1, 5))
        .toList();
  }

  Future<String> _read(Uri address, CancellationToken token) => http.text(
    address,
    token,
    maxBytes: 1 << 20,
    allowGzip: true,
    deadline: publicationCatalogueDeadline,
    scope: (target) {
      if (target != address) {
        throw const PublicationFailure(PublicationProblem.unsupported);
      }
    },
  );
}

List<PublicationEdition> parsePennCatalogue(String body) {
  final document = html.parse(body);
  final entries = <Uri, PublicationEdition>{};
  for (final row in document.querySelectorAll('li')) {
    final info = row.children.firstOrNull;
    if (info?.localName != 'a' || info?.querySelector('img.info') == null) {
      continue;
    }
    final page = _record(info!.attributes['href']);
    final block = row.children
        .skip(1)
        .where(
          (item) =>
              item.localName == 'cite' ||
              (item.localName == 'a' && item.querySelector('cite') != null),
        )
        .firstOrNull;
    final title = publicationLabel(
      block?.localName == 'cite'
          ? block?.text
          : block?.querySelector('cite')?.text,
    );
    if (page == null || title.isEmpty) continue;
    entries.putIfAbsent(
      page,
      () => PublicationEdition(
        id: publicationId('$pennPublicationSource\n$page'),
        title: title,
        author: _authors(row, info, block!),
        page: page,
      ),
    );
  }
  if (entries.isEmpty &&
      (!((document.querySelector('title')?.text ?? '').contains(
            'The Online Books Page',
          )) ||
          !document
              .querySelectorAll('p strong')
              .any((item) => item.text == 'No items were found.'))) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  return entries.values.toList();
}

String _authors(dom.Element row, dom.Element info, dom.Element title) {
  final before = row.nodes
      .skipWhile((node) => node != info)
      .skip(1)
      .takeWhile((node) => node != title)
      .whereType<dom.Text>()
      .map((node) => node.text)
      .join()
      .trim();
  final after = row.nodes
      .skipWhile((node) => node != title)
      .skip(1)
      .takeWhile((node) => node is! dom.Element || node.localName != 'ul')
      .whereType<dom.Text>()
      .map((node) => node.text)
      .join();
  return publicationLabel(
    {
      if (before.endsWith(':') && !_role.hasMatch(before))
        before.substring(0, before.length - 1).trim(),
      if (_by.firstMatch(after)?.group(1)?.trim() case final String author)
        author,
    }.join('、'),
  );
}

Uri? _record(String? raw) {
  if (raw == null || raw.length > 200) return null;
  final relative = Uri.tryParse(raw);
  if (relative == null) return null;
  final uri = pennCatalogueEndpoint.resolveUri(relative);
  final id = uri.queryParameters['key'];
  return uri.origin == pennCatalogueEndpoint.origin &&
          uri.userInfo.isEmpty &&
          !uri.hasFragment &&
          const {_recordPath, '/webbin/book//lookupid'}.contains(uri.path) &&
          uri.queryParametersAll.length == 1 &&
          uri.queryParametersAll['key']?.length == 1 &&
          id != null &&
          _identifier.hasMatch(id)
      ? uri.replace(path: _recordPath)
      : null;
}
