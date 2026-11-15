part of 'books_repository.dart';

extension _BookRepositoryMediaAccess on BooksRepository {
  Future<List<Uri>> _guardedChapterImages(
    Book book,
    BookChapter chapter,
    CancellationToken token,
  ) async {
    await ensureSourceRiskLoaded();
    if (policy.supervision.enabled) throw const ContentBlocked();
    requireBook(book, chapter);
    final offline = await store.offlineImageAddresses(book, chapter);
    if (offline != null) {
      token.check();
      requireBook(book, chapter);
      if (policy.supervision.enabled ||
          !bookAllowed(book) ||
          await _blocked(book.sourceId)) {
        throw const ContentBlocked();
      }
      final current =
          _riskSourceEntries[book.sourceId]?.source ??
          _verifiedSources[book.sourceId];
      if (current != null &&
          offline.any((uri) => _restrictedBookTarget(current, uri, null))) {
        throw const ContentBlocked();
      }
      token.check();
      requireBook(book, chapter);
      if (policy.supervision.enabled) throw const ContentBlocked();
      return offline;
    }
    final source = await _active(book);
    return _withBookRequestGuard(source, book, token, (active, guard) async {
      requireBook(book, chapter);
      final images = await client.chapterImages(
        source,
        chapter,
        active,
        book: book,
        requestGuard: guard,
      );
      active.check();
      requireBook(book, chapter);
      if (policy.supervision.enabled ||
          !sourceAllowed(source) ||
          !bookAllowed(book) ||
          await _blocked(book.sourceId)) {
        throw const ContentBlocked();
      }
      active.check();
      return images;
    });
  }

  Future<List<int>> _guardedChapterImageBytes(
    Book book,
    Uri image,
    CancellationToken token, {
    BookChapter? chapter,
  }) async {
    await ensureSourceRiskLoaded();
    if (policy.supervision.enabled || !bookAllowed(book)) {
      throw const ContentBlocked();
    }
    if (chapter != null) requireBook(book, chapter);
    final current =
        _riskSourceEntries[book.sourceId]?.source ??
        _verifiedSources[book.sourceId];
    if (current != null && _restrictedBookTarget(current, image, null)) {
      throw const ContentBlocked();
    }
    final offlineBytes = chapter == null
        ? null
        : await store.offlineImageBytes(book, chapter, image);
    if (offlineBytes != null) {
      token.check();
      if (chapter != null) requireBook(book, chapter);
      if (policy.supervision.enabled ||
          !bookAllowed(book) ||
          await _blocked(book.sourceId)) {
        throw const ContentBlocked();
      }
      final latest =
          _riskSourceEntries[book.sourceId]?.source ??
          _verifiedSources[book.sourceId];
      if (latest != null && _restrictedBookTarget(latest, image, null)) {
        throw const ContentBlocked();
      }
      token.check();
      if (chapter != null) requireBook(book, chapter);
      if (policy.supervision.enabled || !bookAllowed(book)) {
        throw const ContentBlocked();
      }
      return readableBookImageBytes(image, offlineBytes);
    }
    final source = await _active(book);
    final uri = source.requestTarget(image, media: true);
    return _withBookRequestGuard(source, book, token, (active, guard) async {
      void validate() {
        active.check();
        if (policy.supervision.enabled) throw const ContentBlocked();
        if (chapter != null) requireBook(book, chapter);
        guard?.call(uri, null);
      }

      validate();
      final cached = await store.readingImage(book, uri);
      final document = cached == null
          ? await client.fetch(
              source,
              uri,
              active,
              media: true,
              maxBytes: 4 * 1024 * 1024,
              requestGuard: guard,
            )
          : null;
      validate();
      if (policy.supervision.enabled ||
          !sourceAllowed(source) ||
          !bookAllowed(book) ||
          await _blocked(book.sourceId)) {
        throw const ContentBlocked();
      }
      if (document != null &&
          document.contentType?.toLowerCase().startsWith('image/') != true) {
        throw const FormatException('章节图片地址未返回图片');
      }
      final bytes = cached == null
          ? readableBookImageBytes(uri, document!.bytes)
          : readableBookImageBytes(uri, cached);
      if (document != null) {
        try {
          await store.cacheReadingImage(book, uri, bytes, validate: validate);
        } on Exception {
          // Reading continues if the optional image cache is unavailable.
        }
      }
      validate();
      if (policy.supervision.enabled ||
          !sourceAllowed(source) ||
          !bookAllowed(book) ||
          await _blocked(book.sourceId)) {
        throw const ContentBlocked();
      }
      return bytes;
    });
  }
}
