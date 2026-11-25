part of 'book_store.dart';

extension BookStoreOffline on BookStore {
  Future<void> saveText(Book book, BookChapter chapter, String text) async {
    await saveTexts(book, {chapter: text});
  }

  Future<void> saveTexts(Book book, Map<BookChapter, String> contents) async {
    await vault.ensureLoaded();
    await db.atomic(
      () async {
        await _saveTexts(book, contents);
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }

  Future<void> _saveTexts(Book book, Map<BookChapter, String> contents) async {
    final data = {
      for (final entry in contents.entries)
        _textKey(book, entry.key): jsonEncode(entry.value),
    };
    final private = await isPrivateBook(book.id);
    if (private) {
      if (!vault.unlocked) throw const VaultLockedException();
      for (final entry in contents.entries) {
        await vault.write(_textKey(book, entry.key), entry.value);
      }
      await _requirePrivateCapacity();
      return;
    }
    await db.atomic(() async {
      final used = await _offlineTextBytes();
      final current = await db.rows(
        'SELECT key,length(CAST(value AS BLOB)) AS bytes FROM app_meta WHERE key GLOB ?',
        ['books_text:${book.id}:*'],
      );
      final replaced = current
          .where((row) => data.containsKey(row['key']))
          .fold<int>(0, (sum, row) => sum + (row['bytes'] as int));
      final bytes = data.values.fold<int>(
        0,
        (sum, value) => sum + utf8.encode(value).length,
      );
      if (used - replaced + bytes > BookResourceLimits.offlineTextBytes) {
        throw const FormatException('离线正文空间已满');
      }
      for (final entry in data.entries) {
        await db.customStatement(
          'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
          [entry.key, entry.value],
        );
      }
    }, tables: {'app_meta'});
  }

  Future<List<Map>> annotations(Book book) async {
    if (await isPrivateBook(book.id)) {
      if (!vault.unlocked) return [];
      final raw = await vault.readStrict('books_notes:${book.id}');
      return raw is List ? raw.whereType<Map>().toList() : [];
    }
    final raw = await read('books_notes:${book.id}');
    return raw is List ? raw.whereType<Map>().toList() : [];
  }

  Future<void> addAnnotation(Book book, Map<String, Object?> entry) async {
    await vault.ensureLoaded();
    await db.atomic(
      () async {
        final private = vault.isPrivate(book.id);
        final entries = await annotations(book);
        if (entries.length >= 1000) {
          throw const FormatException('每本书最多保存 1000 条记录');
        }
        final next = [entry, ...entries];
        if (private) {
          await vault.write('books_notes:${book.id}', next);
        } else {
          await write('books_notes:${book.id}', next);
        }
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }

  Future<void> deleteAnnotation(Book book, String id) async {
    await vault.ensureLoaded();
    await db.atomic(
      () async {
        final private = vault.isPrivate(book.id);
        final entries = await annotations(book);
        final next = entries.where((e) => e['id'] != id).toList();
        if (private) {
          await vault.write('books_notes:${book.id}', next);
        } else {
          await write('books_notes:${book.id}', next);
        }
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }

  Future<void> removeLocal(Book book) async {
    final private = await isPrivateBook(book.id);
    await db.atomic(
      () async {
        await _deleteBookKeys(book, includeOffline: true, includeNotes: true);
        if (private) await vault.removeBook(book.id);
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }

  Future<Set<String>> savedText(Book book) async {
    if (await isPrivateBook(book.id)) {
      if (!vault.unlocked) return {};
      final prefix = '${BookVault.dataPrefix}books_text:${book.id}:';
      final rows = await db.rows('SELECT key FROM app_meta WHERE key GLOB ?', [
        '$prefix*',
      ]);
      return {
        for (final row in rows) (row['key'] as String).substring(prefix.length),
        ...await provenChapters('text', book),
      };
    }
    final prefix = 'books_text:${book.id}:';
    final rows = await db.rows('SELECT key FROM app_meta WHERE key GLOB ?', [
      '$prefix*',
    ]);
    return {
      for (final row in rows) (row['key'] as String).substring(prefix.length),
      ...await provenChapters('text', book),
    };
  }

  Future<void> deleteText(Book book, BookChapter chapter) async {
    await vault.ensureLoaded();
    await db.atomic(() async {
      await _clearRebuiltCatalog(book);
      final text = _textKey(book, chapter);
      final pointer = _provenPointer('text', book, chapter);
      final records = 'books_proven_text_record:${book.id}:${chapter.id}:';
      if (vault.isPrivate(book.id)) {
        await vault.delete(text);
        await vault.delete(pointer);
        await vault.deletePrefix(records);
      } else {
        await db.write(
          'DELETE FROM app_meta WHERE key=? OR key=? OR key GLOB ?',
          [text, pointer, '$records*'],
        );
      }
    }, tables: {'app_meta'});
  }

  Future<void> clearOffline(Book book) async {
    await vault.ensureLoaded();
    await db.atomic(() async {
      final private = vault.isPrivate(book.id);
      await _clearRebuiltCatalog(book);
      for (final prefix in [
        'books_text:${book.id}:',
        'books_proven_text_current:${book.id}:',
        'books_proven_text_record:${book.id}:',
        'books_proven_audio_current:${book.id}:',
        'books_proven_audio_record:${book.id}:',
        'books_image_offline:${book.id}:',
        'books_image_data:${book.id}:',
      ]) {
        if (private) {
          await vault.deletePrefix(prefix);
        } else {
          await db.write('DELETE FROM app_meta WHERE key GLOB ?', ['$prefix*']);
        }
      }
    }, tables: {'app_meta'});
  }
}
