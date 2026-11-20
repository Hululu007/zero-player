import '../domain/book.dart';

/// A bounded catalog retains resume/offline chapters and the newest feed tail.
/// Entries are emitted in merged order so neighboring chapter navigation stays
/// stable. The body cache and download records are never removed here.
final class BookCatalogWindow {
  BookCatalogWindow(
    List<BookChapter> old,
    List<BookChapter> fresh, {
    required Set<String> protectedIds,
    BookChapter? last,
    bool preserveOld = true,
  }) {
    final freshById = {for (final chapter in fresh) chapter.id: chapter};
    final before = <String, List<BookChapter>>{};
    var pending = <BookChapter>[];
    String? lastAnchor;
    for (final chapter in old) {
      if (freshById.containsKey(chapter.id)) {
        if (pending.isNotEmpty) {
          (before[chapter.id] ??= []).addAll(pending);
        }
        pending = [];
        lastAnchor = chapter.id;
      } else if (preserveOld ||
          protectedIds.contains(chapter.id) ||
          last?.id == chapter.id) {
        pending.add(chapter);
      }
    }
    final merged = {
      if (lastAnchor == null)
        for (final chapter in pending) chapter.id: chapter,
      for (final chapter in freshById.values) ...{
        for (final earlier in before[chapter.id] ?? const <BookChapter>[])
          earlier.id: earlier,
        chapter.id: chapter,
        if (chapter.id == lastAnchor)
          for (final later in pending) later.id: later,
      },
    };
    if (last != null) merged.putIfAbsent(last.id, () => last);
    final requiredIds = {
      ...protectedIds.where(merged.containsKey),
      if (last != null) last.id,
      if (fresh.isNotEmpty) fresh.last.id,
    };
    if (requiredIds.length > limit) {
      throw const BookCatalogCapacityExceeded();
    }
    final selected = {...requiredIds};
    for (final id in merged.keys.toList().reversed) {
      if (selected.length >= limit) break;
      selected.add(id);
    }
    chapters = merged.values.where((c) => selected.contains(c.id)).toList();
    omitted = merged.length - chapters.length;
  }
  static const limit = bookChapterCatalogLimit;
  late final List<BookChapter> chapters;
  late final int omitted;
}

final class BookCatalogCapacityExceeded implements Exception {
  const BookCatalogCapacityExceeded();
  @override
  String toString() =>
      '目录容量不足：阅读位置和离线/待下载章节已达 $bookChapterCatalogLimit 项，请先整理离线章节后刷新。';
}
