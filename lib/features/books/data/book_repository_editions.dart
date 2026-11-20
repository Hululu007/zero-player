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
    Duration? timeLimit,
    void Function()? onTimeLimit,
    int? maxSources,
    void Function(VerifiedBookEdition)? onVerified,
  }) async {
    final entries = <String, BookSourceEntry>{};
    final editions = <BookEdition>[];
    var expired = false;
    Future<void> scan(CancellationToken active) async {
      await ensureSourceRiskLoaded();
      active.check();
      final hasAuthor = bookIdentity(book.author).isNotEmpty;
      if ((!hasAuthor && !includeCurrent) || !bookAllowed(book)) return;
      final available = await sources(book.kind, enabledOnly: true);
      active.check();
      final candidates = available
          .where(
            (e) =>
                sourceEntryAllowed(e) &&
                (includeCurrent && e.source.id == book.sourceId ||
                    hasAuthor &&
                        e.source.id != book.sourceId &&
                        e.source.hasSearch),
          )
          .toList();
      final prioritized = timeLimit == null
          ? candidates
          : _prioritize(
              candidates,
              includeCurrent ? book.sourceId : null,
              false,
            );
      final scheduled = maxSources == null
          ? prioritized
          : prioritized.take(maxSources);
      for (final entry in scheduled) {
        entries[entry.source.id] = entry;
      }
      await _scanEditionEntries(
        book,
        entries.values.toList(),
        editions,
        active,
        refresh,
        eligible: candidates.length,
        onProgress: onProgress,
        onVerified: onVerified,
        onSourceTimeLimit: timeLimit == null ? null : () => expired = true,
      );
    }

    token.check();
    if (timeLimit == null) {
      await scan(token);
    } else {
      final active = CancellationToken();
      final stopped = Completer<void>();
      void stop() {
        if (stopped.isCompleted) return;
        stopped.complete();
        active.cancel();
      }

      final unlink = token.listen(stop);
      final timer = Timer(timeLimit, () {
        expired = true;
        stop();
      });
      try {
        await Future.any([scan(active), stopped.future]);
      } on RequestCancelled {
        if (!active.isCancelled) rethrow;
      } finally {
        timer.cancel();
        unlink();
      }
    }
    token.check();
    if (expired) onTimeLimit?.call();
    if (!bookAllowed(book)) return [];
    return [
      for (final edition in editions)
        if (entries[edition.book.sourceId] case final entry?
            when bookAllowed(edition.book) && _currentSearchEntry(entry))
          edition,
    ];
  }

  Future<void> _scanEditionEntries(
    Book book,
    List<BookSourceEntry> entries,
    List<BookEdition> editions,
    CancellationToken token,
    bool refresh, {
    required int eligible,
    void Function(BookEditionUpdate)? onProgress,
    void Function(VerifiedBookEdition)? onVerified,
    void Function()? onSourceTimeLimit,
  }) async {
    var cursor = 0, completed = 0;
    void publish(BookSourceEntry? source, BookEdition? edition, bool failed) {
      token.check();
      onProgress?.call((
        source: source,
        edition: edition,
        completed: completed,
        total: entries.length,
        eligible: eligible,
        failed: failed,
      ));
    }

    publish(null, null, false);
    Future<void> worker() async {
      while (cursor < entries.length) {
        token.check();
        final entry = entries[cursor++];
        final result = await _inspectEditionEntry(
          book,
          entry,
          token,
          refresh,
          onVerified: (edition) {
            editions.add(edition);
            if (onVerified == null) return;
            final fingerprint = bookDownloadSourceFingerprint(entry.source);
            onVerified((
              edition: edition,
              isCurrent: () {
                if (!bookAllowed(book) ||
                    !bookAllowed(edition.book) ||
                    !_currentSearchEntry(entry)) {
                  return false;
                }
                final current = _sourceAccess.entry(entry.source.id)!.source;
                return identical(current, entry.source) ||
                    bookDownloadSourceFingerprint(current) == fingerprint;
              },
            ));
          },
          onTimeLimit: onSourceTimeLimit,
        );
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
        completed++;
        publish(entry, best, failed);
      }
    }

    await Future.wait(
      List.generate(
        math.min(onSourceTimeLimit == null ? 4 : 8, entries.length),
        (_) => worker(),
      ),
    );
  }

  Future<({List<BookEdition> editions, bool failed})> _inspectEditionEntry(
    Book book,
    BookSourceEntry entry,
    CancellationToken parent,
    bool refresh, {
    required void Function(BookEdition) onVerified,
    void Function()? onTimeLimit,
  }) async {
    final token = CancellationToken();
    final unlink = parent.listen(token.cancel);
    final timer = onTimeLimit == null
        ? null
        : Timer(const Duration(seconds: 25), () {
            onTimeLimit();
            token.cancel();
          });
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
          final catalog = await chapters(
            candidate,
            token,
            refresh: refresh,
            persistCatalog: onTimeLimit == null,
          );
          token.check();
          if (_currentSearchEntry(entry) &&
              bookAllowed(candidate) &&
              catalog.isNotEmpty) {
            final edition = (book: candidate, chapters: catalog);
            editions.add(edition);
            onVerified(edition);
          }
        } on Exception {
          token.check();
          failed = true;
        }
      }
    } on Exception {
      parent.check();
      failed = true;
    } finally {
      timer?.cancel();
      unlink();
    }
    return (editions: editions, failed: failed);
  }
}
