part of 'books_repository.dart';

extension _BookRepositoryRequestPolicy on BooksRepository {
  String? _catalogReparseRevision(Book book, BookShelfEntry? saved) {
    const current = 'yingsx-page-index-v1';
    final entry = _sourceAccess.entry(book.sourceId);
    if (saved == null ||
        saved.catalogRevision == current ||
        entry == null ||
        !entry.enabled ||
        !entry.source.builtin ||
        entry.source.endpoint.host != 'wap.yingsx.com' ||
        !entry.source.rules.containsKey('tocPageLinks')) {
      return null;
    }
    return current;
  }

  Future<void> _guardedAudioDownload(
    BookSource source,
    Book target,
    BookChapter targetChapter,
    Book origin,
    BookChapter originChapter,
    BookDownloadEvidence evidence,
    CancellationToken token,
    void Function() authorize,
    Future<void> Function() validate,
  ) => _withBookRequestGuard(source, origin, token, (active, guard) async {
    void requireCurrent() {
      active.check();
      authorize();
    }

    Future<void> validateCurrent() async {
      requireCurrent();
      await validate();
      requireCurrent();
    }

    await audioFiles.download(
      source,
      target,
      originChapter,
      active,
      requireCurrent,
      targetChapter: targetChapter,
      originBook: origin,
      evidence: evidence,
      requestGuard: guard,
      publish: (directory) => store.saveProvenAudio(
        target,
        targetChapter,
        directory,
        evidence,
        validateCurrent,
      ),
    );
    requireCurrent();
  }, invalidationIsBlocked: true);

  Future<Book> _guardedBookDetails(
    BookSource source,
    Book book,
    CancellationToken token,
    BookPolicyObservation observation,
  ) {
    final revision = _discoveryRevision;
    final fingerprint = bookSourceCheckFingerprint(source);
    return _withBookRequestGuard(source, book, token, (active, guard) async {
      void authorizeObservation() {
        active.check();
        observation.check();
        final current = _sourceAccess.entry(source.id);
        if (_evidenceClosing ||
            _evidenceMutations != 0 ||
            !sourceRisksReady ||
            revision != _discoveryRevision ||
            current == null ||
            !current.enabled ||
            !sourceEntryAllowed(current) ||
            bookSourceCheckFingerprint(current.source) != fingerprint) {
          throw const RequestCancelled();
        }
      }

      final result = await client.details(
        source,
        book,
        active,
        requestGuard: guard,
      );
      authorizeObservation();
      await _bookPolicy.rememberMetadata(
        book,
        result,
        bookAllowed: bookAllowed,
        authorize: authorizeObservation,
        afterCommit: afterBookPolicyCommitForTesting,
      );
      authorizeObservation();
      if (!_bookPolicy.metadataAllowed(result)) {
        throw const ContentBlocked();
      }
      if (!sourceAllowed(source) ||
          !bookAllowed(result) ||
          await _blocked(book.sourceId)) {
        throw const ContentBlocked();
      }
      authorizeObservation();
      return result;
    });
  }

  Future<List<BookChapter>> _guardedBookChapters(
    BookSource source,
    Book book,
    CancellationToken token,
  ) => _withBookRequestGuard(source, book, token, (active, guard) async {
    final chapters =
        (await client.chapters(source, book, active, requestGuard: guard))
            .where(
              (chapter) =>
                  policy.textAllowed(chapter.title) &&
                  _chapterTargetAllowed(book, chapter),
            )
            .toList();
    active.check();
    if (!sourceAllowed(source) ||
        !bookAllowed(book) ||
        await _blocked(book.sourceId)) {
      throw const ContentBlocked();
    }
    active.check();
    return chapters;
  });

  Iterable<LegadoCategory> _restrictedCategories(BookSource source) => [
    ...?source.legado?.categories,
    ...source.discoveryCategories,
  ].where((category) => !bookCategoryAllowed(policy, category));

  bool _restrictedBookTarget(BookSource source, Uri uri, String? reference) =>
      policy.filterAdult &&
      bookDiscoveryStaticTargetDenied(
        source,
        uri,
        reference,
        _restrictedCategories(source),
      );

  bool _chapterTargetAllowed(Book book, BookChapter chapter) {
    final source =
        _sourceAccess.entry(book.sourceId)?.source ??
        _verifiedSources[book.sourceId];
    return source == null ||
        !_restrictedBookTarget(source, chapter.uri, chapter.request);
  }

  Future<T> _withBookRequestGuard<T>(
    BookSource source,
    Book book,
    CancellationToken cancellation,
    Future<T> Function(CancellationToken token, BookRequestGuard? guard)
    action, {
    bool allowDisabled = false,
    bool invalidationIsBlocked = false,
  }) async {
    if (source.format != BookFormat.html && source.kind != BookKind.comic) {
      return action(cancellation, null);
    }
    final lease = _DiscoveryLease(
      this,
      source,
      cancellation,
      allowDisabled: allowDisabled,
    );
    void check() {
      lease.check();
      if (!bookAllowed(book)) throw const ContentBlocked();
    }

    void requestGuard(Uri uri, String? reference) {
      check();
      if (_restrictedBookTarget(source, uri, reference)) {
        throw const ContentBlocked('该地址属于受限分类');
      }
    }

    try {
      check();
      final result = await action(lease.token, requestGuard);
      check();
      return result;
    } catch (_) {
      // Explicit caller cancellation remains cancellation. For downloads a
      // revoked source/policy lease must stop fallback as a content block.
      cancellation.check();
      if (_evidenceClosing) throw const RequestCancelled();
      try {
        check();
      } on RequestCancelled {
        if (invalidationIsBlocked) {
          throw const ContentBlocked('内容策略或来源已变化');
        }
        rethrow;
      }
      rethrow;
    } finally {
      lease.dispose();
    }
  }
}
