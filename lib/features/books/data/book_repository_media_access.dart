part of 'books_repository.dart';

extension _BookRepositoryMediaAccess on BooksRepository {
  Future<List<Uri>> _guardedChapterImages(
    Book book,
    BookChapter chapter,
    CancellationToken token, {
    void Function(Uri, Document)? onImageResponse,
  }) async {
    await ensureSourceRiskLoaded();
    if (policy.supervision.enabled) throw const ContentBlocked();
    requireBook(book, chapter);
    final offline = await store.offlineImageAddresses(book, chapter);
    if (offline != null && offline.isNotEmpty) {
      await _authorizeOfflineImages(book, offline, token, chapter);
      return offline;
    }
    final source = await _active(book);
    return _withBookRequestGuard(
      source,
      book,
      token,
      (active, guard) => _fetchChapterImages(
        source,
        book,
        chapter,
        active,
        requestGuard: guard,
        onImageResponse: onImageResponse,
      ),
    );
  }

  Future<List<Uri>> _fetchChapterImages(
    BookSource source,
    Book book,
    BookChapter chapter,
    CancellationToken token, {
    BookRequestGuard? requestGuard,
    void Function(Uri, Document)? onImageResponse,
  }) async {
    requireBook(book, chapter);
    final images = await client.chapterImages(
      source,
      chapter,
      token,
      book: book,
      requestGuard: requestGuard,
      onImageResponse: onImageResponse,
    );
    token.check();
    requireBook(book, chapter);
    if (policy.supervision.enabled ||
        !sourceAllowed(source) ||
        !bookAllowed(book) ||
        await _blocked(book.sourceId)) {
      throw const ContentBlocked();
    }
    token.check();
    return images;
  }

  Future<List<int>> _guardedChapterImageBytes(
    Book book,
    Uri image,
    CancellationToken token, {
    BookChapter? chapter,
    int maxBytes = BookResourceLimits.imageBytes,
    bool fresh = false,
    Document? imageResponse,
  }) async {
    maxBytes = maxBytes.clamp(1, BookResourceLimits.imageBytes);
    await ensureSourceRiskLoaded();
    if (policy.supervision.enabled || !bookAllowed(book)) {
      throw const ContentBlocked();
    }
    if (chapter != null) requireBook(book, chapter);
    final current =
        _sourceAccess.entry(book.sourceId)?.source ??
        _verifiedSources[book.sourceId];
    if (current != null && _restrictedBookTarget(current, image, null)) {
      throw const ContentBlocked();
    }
    if (!fresh && chapter != null) {
      final offline = await _readOfflineChapterImage(
        book,
        chapter,
        image,
        token,
        maxBytes,
      );
      if (offline != null) return offline;
    }
    final source = await _active(book);
    final uri = source.requestTarget(image, media: true);
    if (imageResponse != null && imageResponse.uri != uri) {
      throw const FormatException('章节图片地址不一致');
    }
    return _withBookRequestGuard(source, book, token, (active, guard) async {
      void validate() {
        active.check();
        if (policy.supervision.enabled) throw const ContentBlocked();
        if (chapter != null) requireBook(book, chapter);
        guard?.call(uri, null);
      }

      Future<void> verifyAccess() async {
        validate();
        if (!sourceAllowed(source) ||
            !bookAllowed(book) ||
            await _blocked(book.sourceId)) {
          throw const ContentBlocked();
        }
        validate();
      }

      validate();
      final chapterRequest =
          chapter != null && image == chapter.uri && source.legado != null;
      final cached = fresh || chapterRequest || imageResponse != null
          ? null
          : await store.readingImage(book, uri);
      final document = cached == null
          ? imageResponse ??
                await client.fetchChapterImage(
                  source,
                  uri,
                  active,
                  chapter: chapter,
                  maxBytes: maxBytes,
                  requestGuard: guard,
                )
          : null;
      await verifyAccess();
      if (document != null &&
          document.contentType?.toLowerCase().startsWith('image/') != true) {
        throw const FormatException('章节图片地址未返回图片');
      }
      final bytes = cached == null
          ? readableBookImageBytes(uri, document!.bytes)
          : readableBookImageBytes(uri, cached);
      if (bytes.length > maxBytes) {
        throw const FormatException('章节图片超过大小限制');
      }
      await validateReadableBookImage(uri, bytes);
      validate();
      if (document != null && !fresh && !chapterRequest) {
        try {
          await store.cacheReadingImage(book, uri, bytes, validate: validate);
        } on Exception {
          // Reading continues if the optional image cache is unavailable.
        }
      }
      await verifyAccess();
      return bytes;
    });
  }

  Future<List<int>?> _readOfflineChapterImage(
    Book book,
    BookChapter chapter,
    Uri image,
    CancellationToken token,
    int maxBytes,
  ) async {
    final offlineBytes = await store.offlineImageBytes(book, chapter, image);
    if (offlineBytes == null) return null;
    await _authorizeOfflineImages(book, [image], token, chapter);
    try {
      if (offlineBytes.length > maxBytes) {
        throw const FormatException('章节图片超过大小限制');
      }
      await validateReadableBookImage(image, offlineBytes);
      await _authorizeOfflineImages(book, [image], token, chapter);
      return readableBookImageBytes(image, offlineBytes);
    } on FormatException {
      // Preserve damaged offline bytes until a complete replacement commits.
    }
    return null;
  }

  Future<Map<Uri, List<int>>> _offlineComicForExport(
    Book book,
    BookChapter chapter,
    CancellationToken token,
  ) async {
    final images = await store.offlineImages(book, chapter);
    if (images == null || images.isEmpty) {
      throw FormatException('离线章节损坏或缺少图片：${chapter.title}');
    }
    await _authorizeOfflineImages(book, images.keys, token, chapter);
    var bytes = 0;
    for (final address in images.keys) {
      token.check();
      final payload = images[address]!;
      bytes += payload.length;
      try {
        if (payload.length > BookResourceLimits.imageBytes ||
            bytes > BookResourceLimits.chapterImageBytes) {
          throw const FormatException('章节图片超过大小限制');
        }
        await validateReadableBookImage(address, payload);
      } on FormatException {
        throw FormatException('离线章节含有无法读取的图片：${chapter.title}');
      }
      images[address] = readableBookImageBytes(address, payload);
    }
    await _authorizeOfflineImages(book, images.keys, token, chapter);
    return images;
  }

  Future<void> _authorizeOfflineImages(
    Book book,
    Iterable<Uri> images,
    CancellationToken token,
    BookChapter? chapter,
  ) async {
    token.check();
    if (chapter != null) requireBook(book, chapter);
    if (policy.supervision.enabled ||
        !bookAllowed(book) ||
        await _blocked(book.sourceId)) {
      throw const ContentBlocked();
    }
    final latest =
        _sourceAccess.entry(book.sourceId)?.source ??
        _verifiedSources[book.sourceId];
    if (latest != null &&
        images.any((image) => _restrictedBookTarget(latest, image, null))) {
      throw const ContentBlocked();
    }
    token.check();
    if (chapter != null) requireBook(book, chapter);
    if (policy.supervision.enabled || !bookAllowed(book)) {
      throw const ContentBlocked();
    }
  }
}
