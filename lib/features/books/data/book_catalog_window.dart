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
  }) {
    final merged = {for (final chapter in old) chapter.id: chapter};
    if (last != null && !merged.containsKey(last.id)) merged[last.id] = last;
    for (final chapter in fresh) {
      merged[chapter.id] = chapter;
    }
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
  static const limit = 4000;
  late final List<BookChapter> chapters;
  late final int omitted;
}

final class BookCatalogCapacityExceeded implements Exception {
  const BookCatalogCapacityExceeded();
  @override
  String toString() => '目录容量不足：阅读位置和离线/待下载章节已达 4000 项，请先整理离线章节后刷新。';
}
