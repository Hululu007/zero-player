part of 'book_store.dart';

extension BookStoreRebuiltCatalog on BookStore {
  Future<void> replaceRebuiltCatalog(
    Book book,
    List<BookChapter> catalog,
    List<String> rules,
    Map<String, List<Map<String, Object?>>> records, {
    required Iterable<String> originalIds,
    required void Function() validate,
  }) async {
    await vault.ensureLoaded();
    await db.atomic(
      () async {
        validate();
        db.beforeCommit(validate);
        final current = await entry(book) ?? await detachedEntry(book);
        final original = originalIds.toList();
        final saved = await savedText(book);
        if (current == null ||
            current.catalogOmitted != 0 ||
            current.chapters.length != original.length ||
            current.chapters.indexed.any(
              (row) =>
                  row.$2.id != original[row.$1] || !saved.contains(row.$2.id),
            )) {
          throw const FormatException('原目录或离线章节已变化，请重新重建');
        }
        await _clearRebuiltCatalog(book);
        final private = vault.isPrivate(book.id);
        for (final record in records.entries) {
          validate();
          final key = 'books_rebuilt_chapter:${book.id}:${record.key}';
          if (private) {
            await vault.write(key, record.value);
          } else {
            await db.customStatement(
              'INSERT INTO app_meta(key,value) VALUES(?,?)',
              [key, jsonEncode(record.value)],
            );
          }
        }
        await writeBookValue(book, 'books_rebuilt_catalog:${book.id}', {
          'catalog': [for (final chapter in catalog) chapter.toJson()],
          'rules': rules,
        });
        if (private) await _requirePrivateCapacity();
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }

  Future<void> _clearRebuiltCatalog(Book book) async {
    final catalog = 'books_rebuilt_catalog:${book.id}';
    final chapters = 'books_rebuilt_chapter:${book.id}:';
    if (vault.isPrivate(book.id)) {
      await vault.delete(catalog);
      await vault.deletePrefix(chapters);
    } else {
      await db.write('DELETE FROM app_meta WHERE key = ? OR key GLOB ?', [
        catalog,
        '$chapters*',
      ]);
    }
  }
}
