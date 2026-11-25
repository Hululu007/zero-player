import 'dart:convert';

import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';

const haodooPublicationSource = 'haodoo-public-catalogue';
const _host = 'haodoo.org';
const _pageSize = 20;
final _productSlug = RegExp(r'^[0-9]{1,16}(?:-[0-9]{1,4})?$');
final haodooCatalogueEndpoint = Uri.https(_host, '/', {
  'rest_route': '/wc/store/v1/products',
});

final class HaodooCatalogue implements PublicationCatalogue {
  const HaodooCatalogue(this.http);
  final PublicationHttp http;

  @override
  Future<void> check(CancellationToken token) async {
    await _page('', 1, token);
  }

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
  }) async {
    final found = <String, PublicationEdition>{};
    for (var page = 1; page <= maxPages; page++) {
      final ({List<PublicationEdition> books, int count}) result;
      try {
        result = await _page(query, page, token);
      } on Exception catch (error) {
        token.check();
        if (found.isEmpty || !isPublicationNetworkFailure(error)) rethrow;
        break;
      }
      for (final book in result.books) {
        if ((filter?.matches(book) ?? true) && allowed(book.title)) {
          found.putIfAbsent(book.id, () => book);
        }
      }
      if (result.count < _pageSize || found.length >= 40) break;
    }
    return found.values.toList();
  }

  Future<({List<PublicationEdition> books, int count})> _page(
    String query,
    int page,
    CancellationToken token,
  ) async {
    final address = haodooCatalogueEndpoint.replace(
      queryParameters: {
        ...haodooCatalogueEndpoint.queryParameters,
        'per_page': '$_pageSize',
        'page': '$page',
        '_fields': 'id,name,permalink,images',
        if (query.isNotEmpty) 'search': query,
      },
    );
    final body = await http.text(
      address,
      token,
      maxBytes: 512 << 10,
      deadline: publicationCatalogueDeadline,
      scope: (target) {
        if (target != address) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
    );
    token.check();
    return parseHaodooCatalogue(body);
  }
}

({List<PublicationEdition> books, int count}) parseHaodooCatalogue(
  String body,
) {
  final data = jsonDecode(body);
  if (data is! List || data.length > _pageSize) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <PublicationEdition>[];
  for (final row in data.whereType<Map>()) {
    final name = publicationLabel(row['name']);
    final title = publicationLabel(html.parseFragment(name).text);
    final id = row['id'];
    final page = _productPage(row['permalink']);
    if (title.isEmpty || id is! int || id < 1 || page == null) continue;
    final images = row['images'];
    final image = images is List ? images.whereType<Map>().firstOrNull : null;
    final categories = row['categories'];
    final summary = publicationLabel(
      row['short_description'] ?? row['description'],
      max: 5000,
    );
    books.add(
      PublicationEdition(
        id: publicationId('$haodooPublicationSource\n$id'),
        title: title,
        description: publicationLabel(
          html.parseFragment(summary).text,
          max: 1200,
        ),
        tags: [
          if (categories is List)
            for (final category in categories.whereType<Map>().take(4))
              if (publicationLabel(category['name']) case final label
                  when label.isNotEmpty)
                label,
        ],
        cover: publicationCoverUrl(
          page,
          image?['thumbnail'] ?? image?['src'],
          (uri) =>
              (uri.host == _host &&
                  uri.path.startsWith('/wp-content/uploads/')) ||
              (const {
                    'i0.wp.com',
                    'i1.wp.com',
                    'i2.wp.com',
                  }.contains(uri.host) &&
                  uri.path.startsWith('/$_host/wp-content/uploads/')),
        ),
        page: page,
      ),
    );
  }
  if (data.isNotEmpty && books.isEmpty) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  return (books: books, count: data.length);
}

Uri? _productPage(Object? raw) {
  if (raw is! String || raw.length > 256) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.port != 443 ||
      uri.host != _host ||
      uri.userInfo.isNotEmpty ||
      uri.path != '/' ||
      uri.hasFragment) {
    return null;
  }
  final query = uri.queryParametersAll;
  final slug = query['product']?.singleOrNull;
  return query.length == 1 && slug != null && _productSlug.hasMatch(slug)
      ? uri
      : null;
}
