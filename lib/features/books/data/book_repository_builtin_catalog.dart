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
    final assets = await Future.wait([
      rootBundle.loadString('assets/catalogs/books/verified.json'),
      rootBundle.loadString('assets/catalogs/books/website-sources.json'),
    ]);
    final builtins = [
      for (final asset in assets)
        for (final row in (jsonDecode(asset) as List).cast<Map>())
          BookSource.fromJson(row, builtin: true),
    ];
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
