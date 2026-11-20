part of 'book_store.dart';

extension BookStoreShelfActions on BookStore {
  /// Removes the shelf record but can retain downloads and notes.
  Future<void> removeFromShelf(Book book, {required bool clearOffline}) =>
      _deleteBookRecord(book, offline: clearOffline, notes: false);

  /// Full delete of the visible record; downloads are optional.
  Future<void> deleteBook(Book book, {required bool clearOffline}) =>
      _deleteBookRecord(book, offline: clearOffline, notes: true);

  Future<void> _deleteBookRecord(
    Book book, {
    required bool offline,
    required bool notes,
  }) async {
    await vault.ensureLoaded();
    await db.atomic(
      () async {
        final private = vault.isPrivate(book.id);
        if (private && !vault.unlocked) throw const VaultLockedException();
        final retained = await entry(book);
        await writeBookValue(
          book,
          'books_detached:${book.id}',
          !offline && retained != null
              ? {
                  'book': book.toJson(),
                  'chapters': retained.chapters.map((c) => c.toJson()).toList(),
                }
              : null,
        );
        await BookShelfLists(
          this,
          book.kind,
          private: private,
        ).removeBook(book.id);
        await _deleteBookKeys(
          book,
          includeOffline: offline,
          includeNotes: notes,
        );
        if (private && offline && notes) await vault.removeBook(book.id);
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }

  Future<void> _deleteBookKeys(
    Book book, {
    required bool includeOffline,
    required bool includeNotes,
  }) async {
    final private = await isPrivateBook(book.id);
    if (private) {
      await vault.delete('books_shelf:${book.id}');
      await vault.delete('rich_position_${book.id}');
      if (includeNotes) await vault.delete('books_notes:${book.id}');
      if (includeOffline) await vault.delete('publication_${book.id}');
      if (includeOffline) {
        for (final prefix in [
          'books_text:${book.id}:',
          'books_latest_origin:${book.id}:',
          'books_image_offline:${book.id}:',
          'books_image_data:${book.id}:',
          'books_proven_text_current:${book.id}:',
          'books_proven_text_record:${book.id}:',
          'books_proven_audio_current:${book.id}:',
          'books_proven_audio_record:${book.id}:',
        ]) {
          await vault.deletePrefix(prefix);
        }
      }
    } else {
      for (final key in [
        'books_shelf:${book.id}',
        'rich_position_${book.id}',
        if (includeOffline) 'publication_${book.id}',
        if (includeNotes) 'books_notes:${book.id}',
      ]) {
        await db.write('DELETE FROM app_meta WHERE key=?', [key]);
      }
      if (includeOffline) {
        for (final pattern in [
          'books_text:${book.id}:*',
          'books_latest_origin:${book.id}:*',
          'books_proven_text_current:${book.id}:*',
          'books_proven_text_record:${book.id}:*',
          'books_proven_audio_current:${book.id}:*',
          'books_proven_audio_record:${book.id}:*',
        ]) {
          await db.write('DELETE FROM app_meta WHERE key GLOB ?', [pattern]);
        }
      }
    }
    if (includeOffline) {
      for (final key in [
        'books_download:${book.id}',
        'books_download_failures:${book.id}',
        'books_download_blocked:${book.id}',
      ]) {
        if (private) {
          await vault.delete(key);
        } else {
          await db.write('DELETE FROM app_meta WHERE key=?', [key]);
        }
      }
    }
    if (includeOffline) {
      for (final pattern in [
        'books_read_cache:${book.id}:*',
        'books_image_cache:${book.id}:*',
        'books_mixed_cache:${book.id}:*',
        'books_image_offline:${book.id}:*',
        'books_image_data:${book.id}:*',
      ]) {
        await db.write('DELETE FROM app_meta WHERE key GLOB ?', [pattern]);
      }
    }
  }

  Future<List<BookShelfEntry>> detachedShelf({bool private = false}) async {
    await vault.ensureLoaded();
    if (private && !vault.unlocked) return [];
    final prefix = '${private ? BookVault.dataPrefix : ''}books_detached:';
    final rows = await db.rows('SELECT key FROM app_meta WHERE key GLOB ?', [
      '$prefix*',
    ]);
    final result = <BookShelfEntry>[];
    for (final row in rows) {
      final storedKey = row['key'] as String;
      final id = storedKey.substring(prefix.length);
      if (vault.isPrivate(id) != private) continue;
      final key = 'books_detached:$id';
      final raw = private ? await vault.readStrict(key) : await read(key);
      if (raw is Map) result.add(_entry(raw));
    }
    return result;
  }

  /// Repair records that the initial private-shelf implementation left in
  /// plaintext. Preserve an existing authenticated encrypted value on conflict.
  Future<void> _repairVaultPlaintext() async {
    final session = vault.captureSession();
    await db.atomic(
      () async {
        db.beforeCommit(() => vault.checkSession(session));
        for (final id in vault.ids) {
          for (final key in await _bookScopedKeys(id)) {
            final encrypted = await vault.readStrict(key);
            if (encrypted == null) {
              final plain = await read(key);
              if (plain != null) await vault.write(key, plain);
            }
            await db.write('DELETE FROM app_meta WHERE key=?', [key]);
          }
          for (final prefix in [
            'books_read_cache:',
            'books_mixed_cache:',
            'books_image_cache:',
          ]) {
            await db.write('DELETE FROM app_meta WHERE key GLOB ?', [
              '$prefix$id:*',
            ]);
          }
          await _moveCleanupRules(id, toPrivate: true);
        }
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }

  Future<void> saveDownloadTarget(
    Book book, {
    required bool private,
    List<BookChapter>? chapters,
    String? listId,
  }) async {
    await vault.ensureLoaded();
    await db.atomic(
      () async {
        if (private) {
          final session = vault.captureSession();
          db.beforeCommit(() => vault.checkSession(session));
          await moveToVault(book);
        } else if (vault.isPrivate(book.id)) {
          await moveOutOfVault(book);
        }
        await saveBook(
          book,
          chapters: chapters,
          favorite: true,
          preserveCatalog: true,
        );
        if (listId != null) {
          await BookShelfLists(
            this,
            book.kind,
            private: private,
          ).addToList(book, listId);
        }
        if (private) await _requirePrivateCapacity();
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }

  /// Moves every book-scoped record into the encrypted space.
  Future<void> moveToVault(Book book) async {
    await vault.ensureLoaded();
    if (!vault.unlocked) throw const VaultLockedException();
    final session = vault.captureSession();
    await db.atomic(
      () async {
        vault.checkSession(session);
        if (vault.isPrivate(book.id)) return;
        db.beforeCommit(() => vault.checkSession(session));
        for (final key in await _bookScopedKeys(book.id)) {
          final raw = await read(key);
          if (raw == null) continue;
          await vault.write(key, raw);
          await db.write('DELETE FROM app_meta WHERE key=?', [key]);
        }
        // Plaintext reading caches are re-fetchable and must not outlive the
        // move into the encrypted space.
        for (final pattern in [
          'books_read_cache:${book.id}:*',
          'books_mixed_cache:${book.id}:*',
          'books_image_cache:${book.id}:*',
        ]) {
          await db.write('DELETE FROM app_meta WHERE key GLOB ?', [pattern]);
        }
        await BookShelfLists(
          this,
          book.kind,
          private: false,
        ).removeBook(book.id);
        await _moveCleanupRules(book.id, toPrivate: true);
        await vault.addBook(book.id);
        await _requirePrivateCapacity();
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }

  /// Decrypts and restores every record to the public shelf.
  Future<void> moveOutOfVault(Book book) async {
    await vault.ensureLoaded();
    if (!vault.unlocked) throw const VaultLockedException();
    final session = vault.captureSession();
    await db.atomic(
      () async {
        vault.checkSession(session);
        if (!vault.isPrivate(book.id)) return;
        db.beforeCommit(() => vault.checkSession(session));
        final keys = await _vaultBookKeys(book.id);
        for (final key in keys) {
          final raw = await vault.readStrict(key);
          if (raw != null) {
            await write(key, raw);
          }
          await vault.delete(key);
        }
        await BookShelfLists(
          this,
          book.kind,
          private: true,
        ).removeBook(book.id);
        await _moveCleanupRules(book.id, toPrivate: false);
        await vault.removeBook(book.id);
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }

  Future<void> _moveCleanupRules(String id, {required bool toPrivate}) async {
    const publicKey = 'books_reading_cleanup:v1';
    const privateKey = 'books_reading_cleanup:private:v1';
    final plain = await read(publicKey);
    final encrypted = await vault.readStrict(privateKey);
    if (plain != null && plain is! List ||
        encrypted != null && encrypted is! List) {
      throw const FormatException('阅读净化规则损坏，迁移已取消');
    }
    final publicRules = (plain as List? ?? const []).cast<Map>();
    final privateRules = (encrypted as List? ?? const []).cast<Map>();
    final source = toPrivate ? publicRules : privateRules;
    final moved = source.where((rule) => rule['bookId'] == id).toList();
    if (moved.isEmpty) return;
    await write(
      publicKey,
      toPrivate
          ? publicRules.where((rule) => rule['bookId'] != id).toList()
          : [...publicRules, ...moved],
    );
    await vault.write(
      privateKey,
      toPrivate
          ? [...privateRules, ...moved]
          : privateRules.where((rule) => rule['bookId'] != id).toList(),
    );
  }

  Future<List<String>> _bookScopedKeys(String id) => _scopedKeys(id);

  Future<List<String>> _vaultBookKeys(String id) =>
      _scopedKeys(id, encrypted: true);

  Future<List<String>> _scopedKeys(String id, {bool encrypted = false}) async {
    final prefix = encrypted ? BookVault.dataPrefix : '';
    final patterns = [
      'books_shelf:$id',
      'books_notes:$id',
      'rich_position_$id',
      'publication_$id',
      'books_detached:$id',
      'books_download:$id',
      'books_download_failures:$id',
      'books_download_blocked:$id',
      'books_text:$id:*',
      'books_latest_origin:$id:*',
      'books_image_offline:$id:*',
      'books_image_data:$id:*',
      'books_proven_text_current:$id:*',
      'books_proven_text_record:$id:*',
      'books_proven_audio_current:$id:*',
      'books_proven_audio_record:$id:*',
    ];
    final rows = await db.rows(
      'SELECT key FROM app_meta WHERE '
      '${List.filled(patterns.length, 'key GLOB ?').join(' OR ')}',
      [for (final pattern in patterns) '$prefix$pattern'],
    );
    return [
      for (final row in rows) (row['key'] as String).substring(prefix.length),
    ];
  }
}
