import 'dart:convert';

import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';

const gujiguanPublicationSource = 'panda-gujiguan';
final gujiguanHome = Uri.https('www.gujiguan.com', '/');
final gujiguanEndpoint = gujiguanHome.resolve('prod-api/jiansuo/normalsearch');

final class GujiguanCatalogue implements ProgressivePublicationCatalogue {
  const GujiguanCatalogue(this.http);

  final PublicationHttp http;

  PublicListingCatalogue get _listing => PublicListingCatalogue(
    http,
    address: (_, _) => gujiguanEndpoint,
    referer: gujiguanHome,
    requestForm: (query, page) => {
      'searchType': '1',
      'matchType': '0',
      'gjz': query,
      'secondgjz': '',
      'page': '$page',
      'pagesize': '10',
    },
    parse: parseGujiguanCatalogue,
  );

  @override
  Future<void> check(CancellationToken token) async {
    final rows = await _listing.search(
      '红楼梦',
      token,
      maxPages: 1,
      allowed: (_) => true,
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
    Future<void> Function(List<PublicationEdition>)? onProgress,
  }) {
    if (query.isEmpty || filter?.field == PublicationSearchField.isbn) {
      return Future.value(const []);
    }
    return _listing.search(
      query,
      token,
      maxPages: maxPages,
      allowed: allowed,
      filter: filter,
      onProgress: onProgress,
    );
  }
}

PublicationListingPage parseGujiguanCatalogue(String body) {
  final data = jsonDecode(body);
  if (data case {
    'code': 200,
    'data': {
      'rows': final List rows,
      'page': final int page,
      'pageCount': final int pages,
    },
  }) {
    final books = <int, PublicationEdition>{};
    for (final row in rows) {
      if (row case {
        'Book_Code': final int id,
        'Book_Name': final String name,
      } when id > 0 && id <= 999999999) {
        final title = _label(name);
        if (title.isEmpty) continue;
        final route = Uri(
          path: '/search',
          queryParameters: {'select1': '1', 'select2': '1', 'keyword': title},
        );
        final details = [
          row['Book_Vol'],
          row['Book_Version'],
          row['Book_Year'],
        ];
        books[id] = PublicationEdition(
          id: publicationId('$gujiguanPublicationSource\n$id'),
          title: title,
          author: _label(row['Book_Duty']),
          edition: publicationLabel(
            details.map(_label).where((entry) => entry.isNotEmpty).join(' · '),
          ),
          publisher: _label(row['Book_Author']),
          page: gujiguanHome.replace(fragment: route.toString()),
        );
      }
    }
    return (books: books.values.toList(), hasNext: page < pages);
  }
  throw const PublicationFailure(PublicationProblem.invalid);
}

String _label(Object? value) => publicationLabel(
  value is String && (value.contains('<') || value.contains('&'))
      ? html.parseFragment(value).text
      : value,
);
