import 'dart:convert';

import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';

const modernHistoryPublicationSource = 'panda-modernhistory';
final modernHistoryHome = Uri.https('www.modernhistory.org.cn', '/');
final modernHistoryEndpoint = modernHistoryHome.resolve(
  'backend-prod/esBook/findByPage',
);
final _documentCode = RegExp(r'^[a-zA-Z0-9_-]{1,100}$');
const _pageSize = 12;
const _documentRoutes = {
  'ts': '/DocumentDetails_ts_da',
  'da': '/DocumentDetails_da',
  'bz': '/DocumentDetails_bz',
  'qk': '/DocumentDetails_qk',
};

final class ModernHistoryCatalogue implements ProgressivePublicationCatalogue {
  const ModernHistoryCatalogue(this.http);

  final PublicationHttp http;

  PublicListingCatalogue _listing(PublicationSearchField? field) =>
      PublicListingCatalogue(
        http,
        address: (_, _) => modernHistoryEndpoint,
        referer: modernHistoryHome,
        requestBody: (query, page) {
          final name = switch (field) {
            PublicationSearchField.author => 'responsible',
            PublicationSearchField.title => 'title',
            _ => '',
          };
          return {
            'currentPage': page,
            'pageSize': _pageSize,
            'docType': 'total',
            'keyword': name.isEmpty ? query : '',
            'firstFieldName': name,
            'firstFieldValue': name.isEmpty ? '' : query,
            'secondKeyword': '',
            'secondFieldName': '',
            'secondFieldValue': '',
            'startDate': '',
            'endDate': '',
            'orderByDownload': '',
            'orderByGmtCreate': '',
            'orderByPublishTime': '',
          };
        },
        parse: parseModernHistoryCatalogue,
        maxBytes: 2 << 20,
      );

  @override
  Future<void> check(CancellationToken token) => _listing(null).check(token);

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
    Future<void> Function(List<PublicationEdition>)? onProgress,
  }) {
    if (filter?.field == PublicationSearchField.isbn) {
      return Future.value(const []);
    }
    return _listing(filter?.field).search(
      query,
      token,
      maxPages: maxPages,
      allowed: allowed,
      filter: filter,
      onProgress: onProgress,
    );
  }
}

PublicationListingPage parseModernHistoryCatalogue(String body) {
  final response = jsonDecode(body);
  if (response case {
    'code': 200 || '200',
    'result': {'dataList': final List rows},
  }) {
    final books = <String, PublicationEdition>{};
    for (final row in rows) {
      if (row case {
        'fileCode': final String code,
        'docType': final String type,
      } when _documentCode.hasMatch(code)) {
        final route = _documentRoutes[type];
        final original = _label(row['originalTitle']);
        final title = original.isEmpty ? _label(row['title']) : original;
        if (route == null || title.isEmpty) continue;
        final names = row['firstResponsible'];
        final author = names is List
            ? names.map(_label).where((name) => name.isNotEmpty).join('、')
            : _label(names);
        final page = modernHistoryHome.replace(
          fragment: '$route?fileCode=$code',
        );
        books[code] = PublicationEdition(
          id: publicationId('$modernHistoryPublicationSource\n$code'),
          title: title,
          author: publicationLabel(author),
          publisher: _label(row['publishName']),
          page: page,
        );
      }
    }
    return (books: books.values.toList(), hasNext: rows.length >= _pageSize);
  }
  throw const PublicationFailure(PublicationProblem.invalid);
}

String _label(Object? value) {
  if (value is! String || value == '--') return '';
  return publicationLabel(
    value.contains('<') || value.contains('&')
        ? html.parseFragment(value).text
        : value,
  );
}
