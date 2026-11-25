import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_catalogue_shares.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';
import 'publication_share_provider.dart';

const jb51PublicationSource = 'panda-jb51';
final jb51Home = Uri.https('www.jb51.net', '/books/');
final _bookPath = RegExp(r'^/books/[1-9][0-9]{0,10}\.html$');
final _bookId = RegExp(r'^[1-9][0-9]{0,10}$');

final class Jb51Catalogue
    implements ResourcePublicationCatalogue, SharedPublicationCatalogue {
  Jb51Catalogue(this.http);

  final PublicationHttp http;
  Future<List<PublicationEdition>>? _index;

  Future<List<PublicationEdition>> _books(CancellationToken token) async {
    token.check();
    http.authorize(jb51Home);
    final books = await (_index ??= _load());
    token.check();
    return books;
  }

  Future<List<PublicationEdition>> _load() async {
    final data = await rootBundle.load(
      'assets/catalogs/books/panda-jb51.json.gz',
    );
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    return Isolate.run(() => parseJb51Index(utf8.decode(gzip.decode(bytes))));
  }

  @override
  Future<void> check(CancellationToken token) async {
    if ((await _books(token)).isEmpty) {
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
    if (filter?.field == PublicationSearchField.isbn) return const [];
    final books = await _books(token);
    return books
        .where((book) {
          return book.matches(query, filter: filter) &&
              allowed('${book.title} ${book.author}');
        })
        .take((maxPages * 20).clamp(20, 60))
        .toList();
  }

  @override
  Future<List<PublicationResource>> loadResources(
    Uri page,
    CancellationToken token,
  ) async {
    if (publicListingLink(jb51Home, page.toString(), _bookPath) != page) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    return parseJb51Resources(page, await publicListingText(http, page, token));
  }

  @override
  void restrictShare(Uri? page, Uri link) {
    if (page == null ||
        publicListingLink(jb51Home, page.toString(), _bookPath) != page ||
        !supportsCatalogueShareDownload(jb51PublicationSource, link)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
  }
}

List<PublicationEdition> parseJb51Index(String body) {
  final json = jsonDecode(body);
  if (json is! List) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <String, PublicationEdition>{};
  for (final row in json) {
    if (row case {
      'id': final String id,
      'title': final String title,
    } when _bookId.hasMatch(id)) {
      final name = publicationLabel(title);
      if (name.isEmpty) continue;
      final page = jb51Home.resolve('$id.html');
      books[id] = PublicationEdition(
        id: publicationId('$jb51PublicationSource\n$id'),
        title: name,
        author: publicationLabel(row['author']),
        cover: publicationCoverUrl(
          page,
          row['cover'],
          (uri) =>
              uri.host == 'img.jbzj.com' &&
              !uri.hasQuery &&
              uri.path.startsWith('/do/uploads/'),
        ),
        page: page,
        resources: [
          PublicationResource.lookup(source: jb51PublicationSource, link: page),
        ],
      );
    }
  }
  return books.values.toList();
}

List<PublicationResource> parseJb51Resources(Uri page, String body) {
  final document = html.parse(body);
  final canonical = publicListingLink(
    jb51Home,
    document.querySelector('link[rel=canonical]')?.attributes['href'],
    _bookPath,
  );
  if (canonical != page) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final files = <Uri, PublicationResource>{};
  for (final anchor in document.querySelectorAll(
    '#download .ul_Address a[href]',
  )) {
    final href = anchor.attributes['href'];
    for (final provider in const [
      PublicationShareProvider.baidu,
      PublicationShareProvider.quark,
      PublicationShareProvider.xunlei,
      PublicationShareProvider.ctfile,
    ]) {
      final entry = publishedCatalogueShare(
        jb51PublicationSource,
        href,
        provider: provider,
        baiduDownloads: true,
      );
      if (entry != null) files[entry.link] = entry;
    }
  }
  return files.values.toList();
}
