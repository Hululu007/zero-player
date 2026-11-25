import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart' show rootBundle;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';

const zglibrarySource = 'panda-zglibrary';
const kindleComicsSource = 'panda-kindle-comics';
final zglibraryHome = Uri.https('www.zglibrary.com', '/book/0');
final kindleComicsHome = Uri.https('kindle.smgzd.com', '/');
final _id = RegExp(r'^[1-9][0-9]{0,11}$');
final _coverPath = RegExp(r'^/[a-f0-9]{32}\.(?:jpe?g|png|webp)$');
final _comicsPath = RegExp(r'^bbs-([1-9][0-9]{0,11})-1-[1-9][0-9]{0,4}\.html$');

PublicationCatalogue zglibraryCatalogue(PublicationHttp http) =>
    _BookIndexCatalogue(http, zglibraryHome, zglibrarySource);

PublicationCatalogue kindleComicsCatalogue(PublicationHttp http) =>
    _BookIndexCatalogue(http, kindleComicsHome, kindleComicsSource);

final class _BookIndexCatalogue implements PublicationCatalogue {
  _BookIndexCatalogue(this.http, this.home, this.source);

  final PublicationHttp http;
  final Uri home;
  final String source;
  Future<List<PublicationEdition>>? _index;

  Future<List<PublicationEdition>> _books(CancellationToken token) async {
    token.check();
    http.authorize(home);
    final books = await (_index ??= _load());
    token.check();
    return books;
  }

  Future<List<PublicationEdition>> _load() async {
    final data = await rootBundle.load('assets/catalogs/books/$source.json.gz');
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final id = source;
    return Isolate.run(
      () => parsePandaBookIndex(utf8.decode(gzip.decode(bytes)), id),
    );
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
    final field = filter?.field;
    if (field == PublicationSearchField.isbn ||
        (source == kindleComicsSource &&
            field == PublicationSearchField.author)) {
      return const [];
    }
    final books = await _books(token);
    return searchPublicationIndex(
      books,
      query,
      token,
      limit: (maxPages * 20).clamp(20, 60),
      allowed: allowed,
      filter: filter,
    );
  }
}

List<PublicationEdition> parsePandaBookIndex(String body, String source) {
  final rows = jsonDecode(body);
  final library = source == zglibrarySource;
  if (rows is! List ||
      rows.length > 25000 ||
      (!library && source != kindleComicsSource)) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <String, PublicationEdition>{};
  for (final row in rows) {
    if (row case {
      'id': final String id,
      'title': final String name,
    } when _id.hasMatch(id)) {
      final title = publicationLabel(name);
      if (title.isEmpty) continue;
      final rawPage = row['page'];
      final Uri page;
      if (library) {
        page = zglibraryHome.resolve('/detail/$id');
      } else {
        if (rawPage is! String || _comicsPath.firstMatch(rawPage)?[1] != id) {
          continue;
        }
        page = kindleComicsHome.resolve(rawPage);
      }
      books[id] = PublicationEdition(
        id: publicationId('$source\n$id'),
        title: title,
        author: library ? publicationLabel(row['author']) : '',
        page: page,
        cover: library
            ? publicationCoverUrl(
                page,
                row['cover'],
                (uri) =>
                    uri.host == 'gbcloud-book.oss.zglibrary.com' &&
                    _coverPath.hasMatch(uri.path) &&
                    !uri.hasQuery,
              )
            : null,
      );
    }
  }
  return books.values.toList();
}
