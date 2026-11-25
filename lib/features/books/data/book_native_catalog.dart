part of 'book_client.dart';

extension _NativeBookCatalog on BookClient {
  Future<List<BookChapter>> _nativeChapters(
    BookSource source,
    Book book,
    CancellationToken token,
    BookRequestGuard? requestGuard,
  ) async {
    final chapters = <Uri, BookChapter>{};
    final scheduled = <Uri>{};
    final pages = <Uri>[];

    void schedule(Uri address) {
      if (!scheduled.add(address)) return;
      if (pages.length >= bookChapterPageLimit + 1) {
        throw const FormatException('目录分页超过安全上限，未完整加载');
      }
      pages.add(address);
    }

    schedule(book.uri);
    var cursor = 0;
    while (cursor < pages.length) {
      // Use the original order even when requests finish out of order.
      final batch = pages.skip(cursor).take(2).toList();
      final responses = await Future.wait([
        for (final address in batch)
          fetch(
            source,
            address,
            token,
            maxBytes: bookChapterCatalogPageBytes,
            requestGuard: requestGuard,
          ),
      ]);
      for (final response in responses) {
        token.check();
        final document = parseBookHtml(response.text, keepNavigation: true);
        final toc = cursor++ == 0
            ? bookField(document, source.rules['toc'] ?? '')
            : '';
        if (toc.isNotEmpty) {
          final target = source.resolve(response.uri, toc);
          if (!scheduled.contains(target)) {
            schedule(target);
            continue;
          }
        }
        _collectNativeChapters(source, response.uri, document, chapters);
        final indexSelector = source.rules['tocPageLinks'];
        for (final item
            in indexSelector == null
                ? const <dom.Element>[]
                : bookElements(document, indexSelector)) {
          final link = item.attributes['href'] ?? item.attributes['value'];
          if (link != null && link.trim().isNotEmpty) {
            schedule(source.resolve(response.uri, link));
          }
        }
        final next = bookField(document, source.rules['nextToc'] ?? '');
        if (next.isNotEmpty) schedule(source.resolve(response.uri, next));
      }
    }
    return chapters.values.toList();
  }

  void _collectNativeChapters(
    BookSource source,
    Uri base,
    dom.Document document,
    Map<Uri, BookChapter> chapters,
  ) {
    final rows = bookElements(
      document,
      source.rules['chapters']!,
      limit: bookChapterCatalogLimit + 1,
    );
    if (rows.length > bookChapterCatalogLimit) {
      throw const FormatException('单页目录超过 $bookChapterCatalogLimit 项，未完整加载');
    }
    for (final row in rows) {
      final title = bookLabel(bookField(row, source.rules['chapterTitle']!));
      final link = bookField(row, source.rules['chapterUrl']!);
      if (title.isEmpty || link.isEmpty) continue;
      final Uri uri;
      try {
        final image =
            source.kind == BookKind.comic &&
            isBookImageAddress(base.resolve(link));
        uri = source.resolve(base, link, media: source.directAudio || image);
      } on FormatException {
        continue;
      }
      if (chapters.containsKey(uri)) continue;
      if (chapters.length == bookChapterCatalogLimit) {
        throw const FormatException('目录超过 $bookChapterCatalogLimit 章，未完整加载');
      }
      chapters[uri] = BookChapter(title, uri);
    }
  }
}
