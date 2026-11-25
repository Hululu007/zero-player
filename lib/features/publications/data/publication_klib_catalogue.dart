import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';
import 'publication_panda_book_sites.dart';

final class KlibRankingCatalogue implements PublicationCatalogue {
  KlibRankingCatalogue(this.http);
  final PublicationHttp http;
  Future<List<PublicationEdition>>? _snapshot;

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
    return books
        .where(
          (book) =>
              book.matches(query, filter: filter) &&
              allowed('${book.title} ${book.author}'),
        )
        .take(20 * maxPages.clamp(1, 5))
        .toList();
  }

  Future<List<PublicationEdition>> _books(CancellationToken token) async {
    token.check();
    http.authorize(klibRankingPage);
    final books = await (_snapshot ??= _load());
    token.check();
    return books;
  }

  Future<List<PublicationEdition>> _load() async {
    final raw = await rootBundle.loadString(
      'assets/catalogs/books/panda-klib-ranking.json',
    );
    final rows = jsonDecode(raw);
    if (rows is! List || rows.isEmpty || rows.length > 200) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    return [
      for (final row in rows)
        PublicationEdition.fromJson(row as Map<String, dynamic>),
    ];
  }
}
