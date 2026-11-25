part of 'books_repository.dart';

extension _BookChapterDownload on BooksRepository {
  Future<void> _downloadChapter(
    Book book,
    BookChapter chapter,
    CancellationToken token, {
    List<BookEdition> alternatives = const [],
    List<(Book, BookChapter)> matchedAlternatives = const [],
    bool tryOriginal = true,
    BookDownloadSourceHealth? sourceHealth,
  }) async {
    await ensureSourceRiskLoaded();
    await chapterPolicy.load();
    if (book.kind == BookKind.comic) {
      if (sourceHealth?.unavailable(book.sourceId) case final unavailable?) {
        throw unavailable;
      }
      try {
        await _downloadComic(book, chapter, token);
        sourceHealth?.succeeded(book.sourceId);
        return;
      } on ContentBlocked {
        rethrow;
      } on Exception catch (error) {
        token.check();
        throw sourceHealth?.failed(book.sourceId, error) ?? error;
      }
    }
    requireBook(book, chapter);
    if (await _blocked(book.sourceId)) throw const ContentBlocked();
    final aggregated = await BookLatestAggregation(
      store,
      downloadGuard,
    ).origin(book, chapter);
    token.check();
    final candidates = [
      if (tryOriginal && aggregated == null) (book, chapter),
      if (tryOriginal && aggregated != null)
        (aggregated.origin, aggregated.originChapter),
      ...matchedAlternatives,
      for (final edition in alternatives)
        if (matchingChapter(edition.chapters, chapter) case final match?)
          (edition.book, match),
    ];
    Object? last;
    BookDownloadSourceUnavailable? refused;
    for (final (candidate, part) in candidates) {
      token.check();
      final sourceId = candidate.sourceId;
      if (sourceHealth?.unavailable(sourceId) case final unavailable?) {
        refused = unavailable;
        continue;
      }
      try {
        final evidence = await downloadGuard.capture(
          book,
          chapter,
          candidate,
          part,
        );
        final lease = downloadGuard.lease();
        final source = await _active(candidate);
        void authorize() {
          token.check();
          if (lease != downloadGuard.lease()) throw const ContentBlocked();
          requireBook(book, chapter);
          requireBook(candidate, part);
          requireDownloadEvidence(evidence);
        }

        Future<void> validate() async {
          authorize();
          await downloadGuard.validate(evidence, expected: lease);
          authorize();
        }

        await validate();
        if (book.kind == BookKind.text) {
          await _downloadTextChapter(
            source,
            book,
            chapter,
            candidate,
            part,
            evidence,
            token,
            validate,
          );
        } else {
          await _guardedAudioDownload(
            source,
            book,
            chapter,
            candidate,
            part,
            evidence,
            token,
            authorize,
            validate,
          );
        }
        sourceHealth?.succeeded(sourceId);
        return;
      } on ContentBlocked {
        rethrow;
      } on Exception catch (error) {
        token.check();
        refused = sourceHealth?.failed(sourceId, error) ?? refused;
        last = error;
      }
    }
    token.check();
    throw refused ?? last ?? const FormatException('没有可用章节');
  }

  Future<String> _readAggregatedText(
    Book book,
    BookChapter chapter,
    CancellationToken token,
  ) async {
    final routing = BookLatestAggregation(store, downloadGuard);
    await routing.origin(book, chapter);
    token.check();
    var saved = await offlineText(book, chapter, token);
    if (saved.body == null) {
      await _downloadChapter(book, chapter, token);
      saved = await offlineText(book, chapter, token);
    }
    token.check();
    return saved.body ?? (throw const FormatException('聚合章节尚未下载成功'));
  }

  Future<void> _downloadTextChapter(
    BookSource source,
    Book book,
    BookChapter chapter,
    Book candidate,
    BookChapter part,
    BookDownloadEvidence evidence,
    CancellationToken token,
    Future<void> Function() validate,
  ) async {
    await _withBookRequestGuard(source, candidate, token, (
      active,
      guard,
    ) async {
      // Legacy caches have no origin. Fetch fresh bytes so an old C→B
      // fallback cannot be relabelled as a verified B→A download.
      final freshChapter = BookChapter(
        part.title,
        part.uri,
        request: part.request,
      );
      List<BookChapterSegment>? mixed;
      final body = downloadText == null
          ? await client.text(
              source,
              freshChapter,
              active,
              book: candidate,
              onSegments: (segments) => mixed = segments,
              requestGuard: guard,
            )
          : await downloadText!(source, candidate, freshChapter, active);
      active.check();
      await validate();
      active.check();
      chapterPolicy.prepare(book, chapter, body);
      if (body.trim().isEmpty) throw const FormatException('章节正文为空');
      final segments =
          candidate.sourceId == book.sourceId &&
              mixed != null &&
              mixed!.whereType<BookTextSegment>().every(
                (part) => policy.textAllowed(part.text),
              ) &&
              jsonEncode([
                    for (final part in mixed!)
                      switch (part) {
                        BookTextSegment text => {'text': text.text},
                        BookImageSegment image => {
                          'image': image.address.toString(),
                        },
                      },
                  ]).length <=
                  512 * 1024
          ? mixed!
          : const <BookChapterSegment>[];
      await store.saveProvenText(book, chapter, body, evidence, () async {
        active.check();
        await validate();
        active.check();
        chapterPolicy.prepare(book, chapter, body);
        if (!segments.whereType<BookTextSegment>().every(
          (part) => policy.textAllowed(part.text),
        )) {
          throw const ContentBlocked();
        }
      }, segments: segments);
      active.check();
    }, invalidationIsBlocked: true);
  }
}
