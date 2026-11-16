part of 'books_repository.dart';

extension _BookRepositoryProbe on BooksRepository {
  Future<void> _probe(
    BookSource source,
    String query,
    CancellationToken cancellation,
  ) async {
    policy.supervision.require(SensitiveOperation.channels);
    await ensureSourceRiskLoaded();
    if (!sourceAllowed(source) || await _blocked(source.id)) {
      throw const ContentBlocked();
    }
    final lease = _DiscoveryLease(
      this,
      source,
      cancellation,
      allowDisabled: true,
    );
    final token = lease.token;
    Book? observedBook;
    try {
      lease.check();
      final watch = Stopwatch()..start();
      var status = '';
      var stage = '搜索';
      try {
        final books = await _booksWithDiscoveryPolicy(
          source,
          query,
          token,
          bookAddress: _bookAddress(query),
          allowDisabled: true,
        );
        final book = books.where(bookAllowed).firstOrNull;
        if (book == null) throw const FormatException('没有匹配作品，试试该源中已知的书名');
        final observation = _startBookObservation(book);
        observedBook = book;
        void authorizeObservation() {
          lease.check();
          _requireBookObservation(book, observation);
        }

        stage = '详情';
        final details = await _withBookRequestGuard(
          source,
          book,
          token,
          (active, guard) =>
              client.details(source, book, active, requestGuard: guard),
          allowDisabled: true,
        );
        authorizeObservation();
        await _rememberBookMetadata(book, details, authorizeObservation);
        authorizeObservation();
        if (!bookAllowed(details)) throw const ContentBlocked();
        stage = '目录';
        final chapters = await _withBookRequestGuard(
          source,
          details,
          token,
          (active, guard) =>
              client.chapters(source, details, active, requestGuard: guard),
          allowDisabled: true,
        );
        authorizeObservation();
        final chapter = chapters
            .where(
              (c) =>
                  policy.textAllowed(c.title) &&
                  _chapterTargetAllowed(details, c),
            )
            .firstOrNull;
        if (chapter == null) throw const FormatException('目录没有可用章节');
        stage = source.kind == BookKind.text
            ? '正文'
            : source.kind == BookKind.comic
            ? '图片'
            : '音频';
        await _probeChapter(source, book, details, chapter, token);
        authorizeObservation();
        status = '可用 · ${watch.elapsedMilliseconds} ms';
      } on RequestCancelled {
        rethrow;
      } on FormatException catch (error) {
        status = '$stage · ${error.message}';
      } on RemoteFailure catch (error) {
        status = '$stage · ${error.message}';
      } on Exception {
        status = '$stage · 检测失败';
      }
      lease.check();
      await _saveSource(source, {
        'health': status,
        'checkedAt': DateTime.now().millisecondsSinceEpoch,
      }, validate: lease.check);
      lease.check();
    } finally {
      if (observedBook != null) _finishBookObservation(observedBook);
      lease.dispose();
    }
  }

  Future<void> _probeChapter(
    BookSource source,
    Book book,
    Book details,
    BookChapter chapter,
    CancellationToken token,
  ) => _withBookRequestGuard(source, book, token, (active, guard) async {
    if (source.kind == BookKind.text) {
      final body = await client.text(
        source,
        chapter,
        active,
        book: book,
        requestGuard: guard,
      );
      if (body.trim().length < 40 || !policy.textAllowed(body)) {
        throw const FormatException('正文为空、过短或被内容策略拦截');
      }
    } else if (source.kind == BookKind.comic) {
      final images = await client.chapterImages(
        source,
        chapter,
        active,
        book: details,
        requestGuard: guard,
      );
      if (images.isEmpty) throw const FormatException('章节没有可阅读的图片');
      final sample = await client.fetch(
        source,
        images.first,
        active,
        media: true,
        maxBytes: 4 * 1024 * 1024,
        requestGuard: guard,
      );
      if (sample.contentType?.toLowerCase().startsWith('image/') != true) {
        throw const FormatException('章节图片地址未返回图片');
      }
      await validateReadableBookImage(images.first, sample.bytes);
    } else {
      final (uri, bytes) = await client.sampleAudio(
        source,
        chapter,
        active,
        book: book,
        requestGuard: guard,
      );
      audiobookExtension(bytes, isM4b: uri.path.toLowerCase().endsWith('.m4b'));
    }
    active.check();
  }, allowDisabled: true);
}
