part of 'book_store.dart';

extension BookStoreImages on BookStore {
  String _imageCacheKey(Book book, Uri image) =>
      'books_image_cache:${book.id}:${base64UrlEncode(utf8.encode(image.toString()))}';

  Future<List<int>?> readingImage(Book book, Uri image) async {
    if (await isPrivateBook(book.id)) return null;
    final encoded = await read(_imageCacheKey(book, image));
    if (encoded is! String) return null;
    try {
      final bytes = base64Decode(encoded);
      await validateReadableBookImage(image, bytes);
      return bytes;
    } on FormatException {
      await db.customStatement('DELETE FROM app_meta WHERE key=?', [
        _imageCacheKey(book, image),
      ]);
      return null;
    }
  }

  Future<void> cacheReadingImage(
    Book book,
    Uri image,
    List<int> bytes, {
    void Function()? validate,
  }) async {
    if (await isPrivateBook(book.id)) return;
    if (bytes.length > BookResourceLimits.imageBytes) return;
    await validateReadableBookImage(image, bytes);
    await db.atomic(() async {
      if (vault.isPrivate(book.id)) return;
      validate?.call();
      await db.customStatement(
        'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
        [_imageCacheKey(book, image), jsonEncode(base64Encode(bytes))],
      );
      final rows = await db.rows(
        "SELECT key,length(CAST(value AS BLOB)) AS bytes FROM app_meta "
        "WHERE key GLOB 'books_image_cache:*' ORDER BY rowid DESC",
      );
      var used = 0;
      for (final row in rows) {
        used += row['bytes'] as int;
        if (used > BookResourceLimits.readingBytes) {
          await db.customStatement('DELETE FROM app_meta WHERE key=?', [
            row['key'],
          ]);
        }
      }
      validate?.call();
    }, tables: {'app_meta'});
  }

  String _offlineImageKey(Book book, BookChapter chapter) =>
      'books_image_offline:${book.id}:${chapter.id}';

  String _offlineImagePartPrefix(Book book, BookChapter chapter) =>
      'books_image_data:${book.id}:${chapter.id}:';

  Future<List<Uri>?> offlineImageAddresses(
    Book book,
    BookChapter chapter,
  ) async {
    final raw = await readBookValue(book, _offlineImageKey(book, chapter));
    if (raw is! List) return null;
    try {
      return raw.cast<String>().map(Uri.parse).toList();
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<List<int>?> offlineImageBytes(
    Book book,
    BookChapter chapter,
    Uri image,
  ) async {
    final addresses = await offlineImageAddresses(book, chapter);
    final index = addresses?.indexOf(image) ?? -1;
    if (index < 0) return null;
    final raw = await readBookValue(
      book,
      '${_offlineImagePartPrefix(book, chapter)}$index',
    );
    if (raw is! String) return null;
    try {
      return base64Decode(raw);
    } on FormatException {
      return null;
    }
  }

  Future<Map<Uri, List<int>>?> offlineImages(Book book, BookChapter chapter) =>
      db.atomic(() async {
        final addresses = await offlineImageAddresses(book, chapter);
        if (addresses == null ||
            addresses.length > BookResourceLimits.chapterImages ||
            addresses.length != addresses.toSet().length) {
          return null;
        }
        final images = <Uri, List<int>>{};
        for (var index = 0; index < addresses.length; index++) {
          final raw = await readBookValue(
            book,
            '${_offlineImagePartPrefix(book, chapter)}$index',
          );
          if (raw is! String) return null;
          try {
            images[addresses[index]] = base64Decode(raw);
          } on FormatException {
            return null;
          }
        }
        return images;
      });

  Future<void> saveOfflineImages(
    Book book,
    BookChapter chapter,
    Map<Uri, List<int>> images,
    Future<void> Function() validate,
  ) async {
    if (images.isEmpty || images.length > BookResourceLimits.chapterImages) {
      throw const FormatException('章节图片数量无效');
    }
    final rawBytes = images.values.fold<int>(
      0,
      (total, value) => total + value.length,
    );
    if (rawBytes > BookResourceLimits.chapterImageBytes ||
        images.values.any(
          (bytes) => bytes.length > BookResourceLimits.imageBytes,
        )) {
      throw const FormatException('单章图片超过离线空间限制');
    }
    for (final entry in images.entries) {
      await validate();
      await validateReadableBookImage(entry.key, entry.value);
    }
    // Account for base64 and JSON quotes without holding another chapter-sized
    // collection. Encode and release only one image at a time in the transaction.
    final bytes = images.values.fold<int>(
      0,
      (total, value) => total + ((value.length + 2) ~/ 3) * 4 + 2,
    );
    await vault.ensureLoaded();
    await db.atomic(() async {
      final key = _offlineImageKey(book, chapter);
      final prefix = _offlineImagePartPrefix(book, chapter);
      if (vault.isPrivate(book.id)) {
        await validate();
        await vault.deletePrefix(prefix);
        var index = 0;
        for (final image in images.values) {
          await vault.write('$prefix${index++}', base64Encode(image));
        }
        await vault.write(
          key,
          images.keys.map((uri) => uri.toString()).toList(),
        );
        final used =
            (await db.rows(
                  "SELECT COALESCE(SUM(length(CAST(value AS BLOB))),0) AS bytes "
                  "FROM app_meta WHERE key GLOB 'books_vault_data:*'",
                )).single['bytes']
                as int;
        if (used > BookResourceLimits.privateVaultBytes) {
          throw const FormatException('私密离线图片空间已满');
        }
        await validate();
        return;
      }
      final used =
          (await db.rows(
                "SELECT COALESCE(SUM(length(CAST(value AS BLOB))),0) AS bytes "
                "FROM app_meta WHERE key GLOB 'books_image_data:*' AND key NOT GLOB ?",
                ['$prefix*'],
              )).single['bytes']
              as int;
      if (used + bytes > BookResourceLimits.offlineImageBytes) {
        throw const FormatException('离线图片空间已满');
      }
      await validate();
      await db.customStatement('DELETE FROM app_meta WHERE key GLOB ?', [
        '$prefix*',
      ]);
      var index = 0;
      for (final image in images.values) {
        await db.customStatement(
          'INSERT INTO app_meta(key,value) VALUES(?,?)',
          ['$prefix${index++}', jsonEncode(base64Encode(image))],
        );
      }
      await validate();
      await db.customStatement(
        'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
        [key, jsonEncode(images.keys.map((uri) => uri.toString()).toList())],
      );
    }, tables: {'app_meta'});
  }

  Future<Set<String>> savedImages(Book book) async {
    final private = await isPrivateBook(book.id);
    if (private && !vault.unlocked) return {};
    final prefix =
        '${private ? BookVault.dataPrefix : ''}books_image_offline:${book.id}:';
    final rows = await db.rows('SELECT key FROM app_meta WHERE key GLOB ?', [
      '$prefix*',
    ]);
    return {
      for (final row in rows) (row['key'] as String).substring(prefix.length),
    };
  }

  Future<void> deleteImages(Book book, BookChapter chapter) =>
      db.atomic(() async {
        if (await isPrivateBook(book.id)) {
          await vault.delete(_offlineImageKey(book, chapter));
          await vault.deletePrefix(_offlineImagePartPrefix(book, chapter));
          return;
        }
        await db.customStatement('DELETE FROM app_meta WHERE key=?', [
          _offlineImageKey(book, chapter),
        ]);
        await db.customStatement('DELETE FROM app_meta WHERE key GLOB ?', [
          '${_offlineImagePartPrefix(book, chapter)}*',
        ]);
      }, tables: {'app_meta'});
}
