part of 'books_repository.dart';

extension _ComicDownload on BooksRepository {
  Future<void> _downloadComic(
    Book book,
    BookChapter chapter,
    CancellationToken token,
  ) async {
    requireBook(book, chapter);
    final images = await chapterImages(book, chapter, token);
    if (images.isEmpty) throw const FormatException('章节没有可保存的图片');
    final content = <Uri, List<int>>{};
    for (final image in images) {
      token.check();
      content[image] = await chapterImageBytes(
        book,
        image,
        token,
        chapter: chapter,
      );
    }
    await store.saveOfflineImages(book, chapter, content, () async {
      token.check();
      await _enabledSource(book.kind, book.sourceId);
      token.check();
      if (policy.supervision.enabled ||
          !bookAllowed(book) ||
          await _blocked(book.sourceId)) {
        throw const ContentBlocked();
      }
      requireBook(book, chapter);
    });
  }
}
