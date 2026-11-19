part of 'books_repository.dart';

extension _ComicDownload on BooksRepository {
  Future<Set<String>> _reusableComicDownloads(
    Book book,
    Iterable<BookChapter> chapters,
    CancellationToken token,
  ) async {
    token.check();
    await ensureSourceRiskLoaded();
    await chapterPolicy.load();
    final private = await store.isPrivateBook(book.id);
    final session = private ? store.vault.captureSession() : null;
    void check() {
      token.check();
      if (session != null) store.vault.checkSession(session);
    }

    final result = <String>{};
    for (final chapter in chapters) {
      check();
      try {
        requireBook(book, chapter);
        final addresses = await store.offlineImageAddresses(book, chapter);
        check();
        if (addresses == null ||
            addresses.isEmpty ||
            addresses.length > BookResourceLimits.chapterImages ||
            addresses.toSet().length != addresses.length) {
          continue;
        }
        var used = 0;
        var complete = true;
        for (final image in addresses) {
          check();
          await _authorizeOfflineImage(book, image, token, chapter);
          final bytes = await store.offlineImageBytes(book, chapter, image);
          check();
          if (bytes == null ||
              bytes.isEmpty ||
              bytes.length > BookResourceLimits.imageBytes) {
            complete = false;
            break;
          }
          used += bytes.length;
          if (used > BookResourceLimits.chapterImageBytes) {
            complete = false;
            break;
          }
          await validateReadableBookImage(image, bytes);
          check();
          await _authorizeOfflineImage(book, image, token, chapter);
        }
        check();
        if (complete) result.add(chapter.id);
      } on RequestCancelled {
        rethrow;
      } on Exception {
        // Retain old data while a fresh download repairs this chapter.
        check();
      }
    }
    return result;
  }

  Future<void> _downloadComic(
    Book book,
    BookChapter chapter,
    CancellationToken token,
  ) async {
    requireBook(book, chapter);
    final source = await _active(book);
    await _withBookRequestGuard(source, book, token, (active, guard) async {
      final images = await chapterImages(book, chapter, active);
      if (images.isEmpty) throw const FormatException('章节没有可保存的图片');
      if (images.length > BookResourceLimits.chapterImages) {
        throw const FormatException('章节图片数量无效');
      }
      final content = <Uri, List<int>>{};
      var used = 0;
      for (final image in images) {
        active.check();
        guard?.call(image, null);
        final remaining = BookResourceLimits.chapterImageBytes - used;
        if (remaining <= 0) {
          throw const FormatException('单章图片超过离线空间限制');
        }
        final bytes = await chapterImageBytes(
          book,
          image,
          active,
          chapter: chapter,
          maxBytes: remaining.clamp(1, BookResourceLimits.imageBytes),
        );
        used += bytes.length;
        content[image] = bytes;
      }
      await store.saveOfflineImages(book, chapter, content, () async {
        active.check();
        await _enabledSource(book.kind, book.sourceId);
        active.check();
        for (final image in content.keys) {
          guard?.call(image, null);
        }
        if (policy.supervision.enabled ||
            !bookAllowed(book) ||
            await _blocked(book.sourceId)) {
          throw const ContentBlocked();
        }
        requireBook(book, chapter);
      });
      active.check();
    }, invalidationIsBlocked: true);
  }
}
