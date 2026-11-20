part of 'books_repository.dart';

extension _BookRepositoryBuiltinCatalog on BooksRepository {
  Future<void> _seedCatalog() async {
    final catalog = await AoaoStarBookCatalog.load();
    if (closing) return;
    // A filtered import skips restricted rows. Revisit the same snapshot when
    // the user later changes the filter, or those rows would be lost forever.
    final filterAdult = policy.filterAdult;
    final revision =
        '${catalog.revision}:adult-${filterAdult ? 'filtered' : 'all'}:2';
    if (await store.read('books_catalog_revision') == revision) return;
    final sources = (await catalog.read()).sources;
    if (closing) return;
    await importSources(
      sources,
      fromCatalog: true,
      catalogRevision: revision,
      catalogAdultFilter: filterAdult,
    );
  }

  Future<List<BookSource>> _loadBuiltins() async {
    final data =
        jsonDecode(
              await rootBundle.loadString(
                'assets/catalogs/books/verified.json',
              ),
            )
            as List;
    final builtins = data
        .cast<Map>()
        .map((s) => BookSource.fromJson(s, builtin: true))
        .toList();
    builtins.addAll(
      await loadReviewedBookDomains(
        store,
        riskStore,
        migratePreferences:
            !policy.supervision.enabled && !policy.supervision.corrupted,
      ),
    );
    _verifiedSources.addEntries(
      builtins.map((source) => MapEntry(source.id, source)),
    );
    return builtins;
  }
}
