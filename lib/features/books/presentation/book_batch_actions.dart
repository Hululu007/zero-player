import 'package:flutter/material.dart';

import '../data/book_download_coordinator.dart';
import '../data/book_store.dart';
import '../data/books_repository.dart';
import '../domain/book.dart';
import '../domain/book_download_plan.dart';

Widget bookBatchBar<T>({
  required bool active,
  required bool busy,
  required int selected,
  required bool hasEntries,
  required VoidCallback onToggle,
  required VoidCallback onSelectAll,
  required ValueChanged<T> onAction,
  required List<PopupMenuEntry<T>> actions,
}) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: 12),
  child: Align(
    alignment: Alignment.centerRight,
    child: Wrap(
      spacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (active) Text('已选 $selected 项'),
        if (active)
          TextButton(
            onPressed: busy || !hasEntries ? null : onSelectAll,
            child: const Text('全选当前结果'),
          ),
        if (active)
          PopupMenuButton<T>(
            tooltip: '批量操作',
            enabled: selected > 0 && !busy,
            onSelected: onAction,
            itemBuilder: (_) => actions,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text('批量操作'),
            ),
          ),
        TextButton.icon(
          onPressed: busy || !active && !hasEntries ? null : onToggle,
          icon: Icon(active ? Icons.close : Icons.checklist),
          label: Text(active ? '退出多选' : '多选'),
        ),
      ],
    ),
  ),
);

Future<bool> retryBookDownload(
  BooksRepository books,
  BookDownloadCoordinator manager,
  BookShelfEntry entry,
) async {
  final book = entry.book;
  if (!books.bookAllowed(book) ||
      manager.active(book) != null ||
      entry.chapters.isEmpty) {
    return false;
  }
  var plan = BookDownloadPlan.fromJson(
    await books.store.readBookValue(book, 'books_download:${book.id}'),
  );
  final keepPlan = plan != null;
  if (plan == null) {
    final failure = await books.store.readBookValue(
      book,
      'books_download_failures:${book.id}',
    );
    final failed = [
      if (failure is Map)
        for (final chapter in entry.chapters)
          if (failure.containsKey(chapter.id) &&
              books.policy.textAllowed(chapter.title))
            chapter.id,
    ];
    if (failed.isEmpty) return false;
    plan = BookDownloadPlan(
      1,
      entry.chapters.length,
      book.kind != BookKind.comic,
      chapterIds: failed,
    );
  }
  if (!books.bookAllowed(book) || manager.active(book) != null) return false;
  manager.start(book, entry.chapters, plan, keepPlan: keepPlan);
  return true;
}
