import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';
import 'publication_search_text.dart';

const cdstmPublicationSource = 'panda-cdstm';
final cdstmCataloguePage = Uri.https('www.cdstm.cn', '/subjects/jzrm/kpydh/');
const _fileHosts = {
  'cdstm-resources-bucket.oss.cn-north-4.inspurcloudoss.com',
  'cdn.resources.cdstm.cn',
};
final _series = RegExp(
  r'^/subjects/jzrm/kpydh/(?:bkjgdhj|ysjkx|dmzgnkxj|qnkxjqtkx)/index\.html$',
);
final _pdf = RegExp(r'^/h5/jzrm/[a-zA-Z0-9_-]{1,140}\.pdf$');

final class CdstmCatalogue implements DownloadablePublicationCatalogue {
  CdstmCatalogue(this.http);

  final PublicationHttp http;
  Future<List<PublicationEdition>>? _index;

  @override
  Future<void> check(CancellationToken token) async {
    await _books(token);
  }

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
  }) async {
    final books = await _books(token);
    final matcher =
        filter ??
        (query.isEmpty
            ? null
            : PublicationFieldSearch(
                PublicationSearchField.all,
                query,
                hanFold: await publicationHanFold(),
              ));
    token.check();
    return books
        .where(
          (book) =>
              book.matches(query, filter: matcher) &&
              allowed('${book.title} ${book.author}'),
        )
        .take(20 * maxPages.clamp(1, 5))
        .toList();
  }

  @override
  Future<PublicationDownload> download(
    AcquisitionCandidate candidate,
    CancellationToken token,
  ) async {
    if (candidate.source != cdstmPublicationSource ||
        candidate.format != PublicationFormat.pdf ||
        !_isPdf(candidate.link)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final books = await _books(token);
    if (!books
        .expand((book) => book.candidates)
        .any(
          (file) => file.link == candidate.link && file.page == candidate.page,
        )) {
      throw const PublicationFailure(PublicationProblem.missing);
    }
    return PublicationDownload(
      candidate.link,
      scope: (target) {
        if (target != candidate.link) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
    );
  }

  Future<List<PublicationEdition>> _books(CancellationToken token) async {
    token.check();
    http.authorize(cdstmCataloguePage);
    final books = await (_index ??= _load());
    token.check();
    return books;
  }

  Future<List<PublicationEdition>> _load() async {
    final rows = jsonDecode(
      await rootBundle.loadString('assets/catalogs/books/panda-cdstm.json'),
    );
    if (rows is! List || rows.isEmpty || rows.length > 3000) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    final books = rows.whereType<Map>().map(_edition).nonNulls.toList();
    if (books.isEmpty) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    return books;
  }
}

PublicationEdition? _edition(Map row) {
  final title = publicationLabel(row['title']);
  final raw = row['page'];
  final page = publicListingLink(
    cdstmCataloguePage,
    raw is String ? raw : null,
    _series,
  );
  if (page == null || title.isEmpty) return null;
  final isbn = normalizedIsbn(publicationLabel(row['isbn']));
  final pdf = Uri.tryParse(publicationLabel(row['pdf'], max: 500));
  return PublicationEdition(
    id: publicationId('$cdstmPublicationSource\n$page\n$isbn\n$title'),
    title: title,
    author: publicationLabel(row['author']),
    isbn: isbn,
    language: 'zh',
    cover: publicationCoverUrl(
      page,
      row['cover'],
      (uri) =>
          uri.host == page.host &&
          uri.path.startsWith('/zgszkjg/subjects/jzrm/'),
    ),
    page: page,
    candidates: [
      if (pdf != null && _isPdf(pdf))
        AcquisitionCandidate(
          source: cdstmPublicationSource,
          link: pdf,
          page: page,
          format: PublicationFormat.pdf,
        ),
    ],
  );
}

bool _isPdf(Uri uri) =>
    uri.scheme == 'https' &&
    _fileHosts.contains(uri.host) &&
    uri.port == 443 &&
    uri.userInfo.isEmpty &&
    !uri.hasFragment &&
    !uri.hasQuery &&
    _pdf.hasMatch(uri.path);
