import 'dart:convert';

import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_catalogue_shares.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';
import 'publication_share_provider.dart';

const booklnPublicationSource = 'panda-bookln';
final booklnHome = Uri.https('xue.bookln.cn', '/');
final booklnEndpoint = booklnHome.resolve('books/searchBooks');
final _booklnDetails = booklnHome.resolve('books/bookDetails');
final _booklnIdSign = RegExp(r'^[a-f0-9]{6,16}$');
final _booklnImageHost = RegExp(r'^(?:qrcodecdn|cdn[0-9]{1,2})\.bookln\.cn$');

final class BooklnCatalogue implements ProgressivePublicationCatalogue {
  const BooklnCatalogue(this.http);

  final PublicationHttp http;

  @override
  Future<void> check(CancellationToken token) async {
    final body = await publicListingText(http, booklnHome, token);
    if (html.parse(body).querySelector('script[src^="/dist/shared-"]') ==
        null) {
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
    return PublicListingCatalogue(
      http,
      address: (query, page) => booklnEndpoint.replace(
        queryParameters: {
          'search': query,
          'pageSize': '8',
          'currentPage': '$page',
        },
      ),
      parse: parseBooklnCatalogue,
    ).search(
      query,
      token,
      maxPages: maxPages,
      allowed: allowed,
      filter: filter,
      onProgress: onProgress,
    );
  }
}

PublicationListingPage parseBooklnCatalogue(String body) {
  final response = jsonDecode(body);
  final data = switch (response) {
    {'success': true, 'data': final String nested} => jsonDecode(nested),
    {'success': true, 'data': final Map nested} => nested,
    _ => null,
  };
  if (data case {
    'pageData': final List rows,
    'currentPage': final int pageNumber,
    'totalPages': final int totalPages,
  } when pageNumber > 0 && totalPages >= 0) {
    final books = <Uri, PublicationEdition>{};
    for (final row in rows) {
      if (row case {
        'id': final int id,
        'idSign': final String idSign,
        'name': final String name,
      } when id > 0 && _booklnIdSign.hasMatch(idSign)) {
        final title = publicationLabel(name);
        if (title.isEmpty) continue;
        final page = _booklnDetails.replace(
          queryParameters: {'id': '$id', 'idSign': idSign},
        );
        final author = publicationLabel(row['author']);
        books[page] = PublicationEdition(
          id: publicationId('$booklnPublicationSource\n$page'),
          title: title,
          author: const {'暂无', '未知', '1', '-'}.contains(author) ? '' : author,
          publisher: publicationLabel(row['publisher']),
          page: page,
          cover: publicationCoverUrl(
            page,
            row['thumbnails'],
            (url) => _booklnImageHost.hasMatch(url.host),
          ),
          language: 'zh',
        );
      }
    }
    return (books: books.values.toList(), hasNext: pageNumber < totalPages);
  }
  throw const PublicationFailure(PublicationProblem.invalid);
}

const shuzhouPublicationSource = 'panda-shuzhou';
final shuzhouHome = Uri.https('www.shuzhou.cc', '/');
final shuzhouEndpoint = Uri.https('api.shuzhou.cc', '/api/bookSearch');
final _shuzhouTitle = RegExp(r'^《([^》]{1,180})》([^\s/]{1,35})?/');
final _shuzhouBareTitle = RegExp(r'^《([^》]{1,180})》');
final _shuzhouCtFolder = RegExp(r'^/d/[0-9]{1,20}-[0-9]{1,20}-[a-f0-9]{4,16}$');
final _shuzhouOldCtFile = RegExp(r'^/fs/[0-9]{1,20}-[0-9]{1,20}$');
final _shuzhouFolderCode = RegExp(r'^p=([A-Za-z0-9]{2,16})$');

PublicListingCatalogue shuzhouCatalogue(PublicationHttp http) =>
    PublicListingCatalogue(
      http,
      address: (query, _) =>
          shuzhouEndpoint.replace(queryParameters: {'q': query}),
      parse: parseShuzhouCatalogue,
      maxBytes: 256 << 10,
    );

PublicationListingPage parseShuzhouCatalogue(String body) {
  final rows = jsonDecode(body);
  if (rows is! List) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <String, PublicationEdition>{};
  for (final row in rows) {
    if (row case {
      'url': final String raw,
      'title': final String label,
    } when raw.length <= 512) {
      final resource = _shuzhouShare(raw);
      final titleText = publicationLabel(html.parseFragment(label).text);
      if (resource == null || titleText.isEmpty) continue;
      final heading = _shuzhouTitle.firstMatch(titleText);
      final title =
          heading?[1] ??
          _shuzhouBareTitle.firstMatch(titleText)?[1] ??
          titleText;
      final author = heading?[2]?.trim() ?? '';
      final id = publicationId(
        '$shuzhouPublicationSource\n$title\n${resource.link}',
      );
      books[id] = PublicationEdition(
        id: id,
        title: title,
        author: author.replaceFirst(RegExp(r'著$'), ''),
        description: titleText,
        resources: [resource],
      );
    }
  }
  return (books: books.values.toList(), hasNext: false);
}

PublicationResource? _shuzhouShare(String raw) {
  for (final provider in const [
    PublicationShareProvider.ctfile,
    PublicationShareProvider.baidu,
    PublicationShareProvider.xunlei,
  ]) {
    final resource = publishedCatalogueShare(
      shuzhouPublicationSource,
      raw,
      provider: provider,
    );
    if (resource != null) return resource;
  }
  final url = Uri.tryParse(raw);
  if (url == null ||
      url.scheme != 'https' ||
      url.port != 443 ||
      url.userInfo.isNotEmpty ||
      url.hasFragment) {
    return null;
  }
  if (url.host == 'fast8com.pipipan.com' &&
      _shuzhouOldCtFile.hasMatch(url.path) &&
      !url.hasQuery) {
    return PublicationResource(
      source: shuzhouPublicationSource,
      link: Uri.https('fast8com.ctfile.com', url.path),
      label: '城通网盘',
    );
  }
  if (_shuzhouFolderCode.firstMatch(url.query) case final code?
      when url.host == 'url81.ctfile.com' &&
          _shuzhouCtFolder.hasMatch(url.path)) {
    return PublicationResource(
      source: shuzhouPublicationSource,
      link: url,
      label: '城通网盘',
      code: code[1],
    );
  }
  return null;
}
