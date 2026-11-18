part of 'books_repository.dart';

/// Each worker searches and checks a channel independently so a slow search
/// cannot hold back already verified catalogues from other channels.
extension _BookRepositoryEditions on BooksRepository {
  Future<List<BookEdition>> _inspectEditions(
    Book book,
    CancellationToken token, {
    required bool refresh,
    required bool includeCurrent,
    void Function(BookEditionUpdate)? onProgress,
  }) async {
    await ensureSourceRiskLoaded();
    token.check();
    if (bookIdentity(book.author).isEmpty || !bookAllowed(book)) return [];
    final entries = (await sources(book.kind, enabledOnly: true))
        .where(
          (e) =>
              sourceEntryAllowed(e) &&
              (includeCurrent && e.source.id == book.sourceId ||
                  e.source.id != book.sourceId && e.source.hasSearch),
        )
        .toList();
    token.check();
    final editions = <BookEdition>[];
    var cursor = 0, completed = 0;
    void publish(BookSourceEntry? source, BookEdition? edition, bool failed) {
      token.check();
      onProgress?.call((
        source: source,
        edition: edition,
        completed: completed,
        total: entries.length,
        failed: failed,
      ));
    }

    publish(null, null, false);
    Future<void> worker() async {
      while (cursor < entries.length) {
        token.check();
        final entry = entries[cursor++];
        final result = await _inspectEditionEntry(book, entry, token, refresh);
        BookEdition? best;
        for (final edition in result.editions) {
          if (best == null || edition.chapters.length > best.chapters.length) {
            best = edition;
          }
        }
        var failed = result.failed;
        token.check();
        if (!_currentSearchEntry(entry) || !bookAllowed(book)) {
          best = null;
          failed = true;
        }
        if (best != null) editions.addAll(result.editions);
        completed++;
        publish(entry, best, failed);
      }
    }

    await Future.wait(
      List.generate(math.min(4, entries.length), (_) => worker()),
    );
    token.check();
    return editions
        .where(
          (e) =>
              bookAllowed(e.book) &&
              entries.any(
                (entry) =>
                    entry.source.id == e.book.sourceId &&
                    _currentSearchEntry(entry),
              ),
        )
        .toList();
  }

  Future<({List<BookEdition> editions, bool failed})> _inspectEditionEntry(
    Book book,
    BookSourceEntry entry,
    CancellationToken token,
    bool refresh,
  ) async {
    final title = bookIdentity(book.title), author = bookIdentity(book.author);
    final editions = <BookEdition>[];
    var failed = false;
    try {
      final current = entry.source.id == book.sourceId;
      final found = current
          ? (books: [book], failed: 0)
          : await find(
              book.kind,
              book.title,
              token,
              sourceId: entry.source.id,
              availableSources: [entry],
              field: BookSearchField.title,
            );
      failed = found.failed > 0;
      for (final candidate in found.books) {
        token.check();
        if (bookIdentity(candidate.title) != title ||
            bookIdentity(candidate.author) != author) {
          continue;
        }
        try {
          final catalog = await chapters(candidate, token, refresh: refresh);
          token.check();
          if (_currentSearchEntry(entry) &&
              bookAllowed(candidate) &&
              catalog.isNotEmpty) {
            editions.add((book: candidate, chapters: catalog));
          }
        } on Exception {
          token.check();
          failed = true;
        }
      }
    } on Exception {
      token.check();
      failed = true;
    }
    return (editions: editions, failed: failed);
  }
}
