import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_download_evidence.dart';
import 'package:zero_player/features/books/data/book_resource_limits.dart';
import 'package:zero_player/features/books/data/book_shelf_lists.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/data/book_vault.dart';
import 'package:zero_player/features/books/domain/book.dart';

late AppDatabase db;
late BookStore store;
final book = Book(
  'vault-source',
  BookKind.text,
  '私密测试书',
  '作者',
  Uri.parse('https://fixture.test/vault-book'),
);
final chapter = BookChapter('第一章', Uri.parse('https://fixture.test/1'));
const body = '只有解锁后才能读取的正文';

void main() {
  setUp(() {
    db = AppDatabase.memory();
    store = BookStore(db);
  });

  tearDown(() async {
    store.vault.dispose();
    await db.close();
  });

  _migrationTests();
  _legacyRepairTests();
  _removalTests();
  _encryptedRecordTests();
  _rollbackTests();
  _revocationTests();
  _downloadTargetTests();
}

void _downloadTargetTests() {
  _migrationQuotaTest();
  test(
    'failed private download target never leaves a public favorite',
    () async {
      await store.vault.create('secret-123');
      await store.write('books_reading_cleanup:v1', {'malformed': true});
      await expectLater(
        store.saveDownloadTarget(book, private: true, chapters: [chapter]),
        throwsFormatException,
      );
      expect(await store.shelf(), isEmpty);
      expect(await store.vaultShelf(), isEmpty);
      expect(await store.isPrivateBook(book.id), isFalse);
      await store.write('books_reading_cleanup:v1', []);
      await store.saveDownloadTarget(book, private: true, chapters: [chapter]);
      expect((await store.vaultShelf()).single.favorite, isTrue);
      expect(await store.read('books_shelf:${book.id}'), isNull);
    },
  );

  test(
    'missing private list rolls back migration and public membership',
    () async {
      await seed();
      await store.vault.create('secret-123');
      final lists = BookShelfLists(store, book.kind);
      await lists.save('公开书单', ShelfListKind.list);
      await lists.addToList(book, (await lists.load()).single.id);
      await expectLater(
        store.saveDownloadTarget(book, private: true, listId: 'missing'),
        throwsFormatException,
      );
      expect(await store.isPrivateBook(book.id), isFalse);
      expect((await lists.load()).single.books, {book.id});
      expect(await store.text(book, chapter), body);
      expect(await store.vaultShelf(), isEmpty);
    },
  );

  test('the same vault retries initialization after index repair', () async {
    await db.setMetadata(BookVault.indexKey, '{}', MetadataDomain.books);
    await expectLater(
      Future.wait([store.vault.ensureLoaded(), store.vault.ensureLoaded()]),
      throwsFormatException,
    );
    await db.setMetadata(
      BookVault.indexKey,
      jsonEncode([book.id]),
      MetadataDomain.books,
    );
    await store.vault.ensureLoaded();
    expect(store.vault.ids, {book.id});
  });
}

void _migrationQuotaTest() {
  test(
    'migration beyond the encrypted byte budget rolls back all writes',
    () async {
      await seed();
      await store.vault.create('secret-123');
      final lists = BookShelfLists(store, book.kind);
      await lists.save('公开书单', ShelfListKind.list);
      await lists.addToList(book, (await lists.load()).single.id);
      // Only SQLite's byte count matters; no password or real book is needed
      // to fill the remainder of the test vault.
      await db.customStatement(
        'INSERT INTO app_meta(key,value) VALUES(?,zeroblob(?))',
        [
          '${BookVault.dataPrefix}remaining-capacity-fixture',
          BookResourceLimits.privateVaultBytes - 8,
        ],
      );
      await expectLater(store.moveToVault(book), throwsFormatException);
      expect(await store.isPrivateBook(book.id), isFalse);
      expect((await store.shelf()).single.book.id, book.id);
      expect((await lists.load()).single.books, {book.id});
      expect(await store.text(book, chapter), body);
      expect(await rawRows('${BookVault.dataPrefix}books_shelf:*'), isEmpty);
    },
  );
}

Future<void> seed() async {
  await store.saveBook(book, chapters: [chapter]);
  await store.saveText(book, chapter, body);
  await store.addAnnotation(book, {'id': 'n1', 'text': '私密笔记'});
}

Future<Map<String, String>> rawRows(String pattern) async {
  final rows = await db.rows(
    'SELECT key,value FROM app_meta WHERE key GLOB ?',
    [pattern],
  );
  return {for (final row in rows) row['key'] as String: row['value'] as String};
}

void _migrationTests() {
  test('moving a book into the vault encrypts records and hides it', () async {
    await seed();
    await store.vault.create('secret-123');
    await store.moveToVault(book);

    expect(await store.shelf(), isEmpty);
    expect((await store.vaultShelf()).single.book.id, book.id);
    expect(await store.text(book, chapter), body);
    expect((await store.annotations(book)).single['text'], '私密笔记');
    expect(
      await store.readBookValue(book, 'books_download:${book.id}'),
      isNull,
    );

    final plainText = await rawRows('books_text:*');
    expect(plainText, isEmpty);
    final encrypted = await rawRows('books_vault_data:books_text:${book.id}:*');
    expect(encrypted, hasLength(1));
    expect(encrypted.values.single, isNot(contains(body)));
    expect(encrypted.values.single, isNot(contains('私密笔记')));
    expect(encrypted.keys.single, contains(book.id));

    store.vault.lock();
    expect(await store.vaultShelf(), isEmpty);
    expect(await store.text(book, chapter), isNull);
    expect(await store.entry(book), isNull);
    await expectLater(
      store.saveBook(book, favorite: true),
      throwsA(isA<VaultLockedException>()),
    );

    expect(await store.vault.unlock('secret-123'), isTrue);
    expect(await store.entry(book), isNotNull);
    await store.moveOutOfVault(book);
    expect((await store.shelf()).single.book.id, book.id);
    expect(await store.text(book, chapter), body);
    expect(await rawRows('books_vault_data:books_text:*'), isEmpty);
  });
  test(
    'writes after migration within one transaction use the pending private index',
    () async {
      await seed();
      await store.vault.create('secret-123');
      await db.atomic(() async {
        await store.moveToVault(book);
        await store.saveBook(book, favorite: true);
        await store.saveText(book, chapter, '事务内的新正文');
      });
      expect(await store.read('books_shelf:${book.id}'), isNull);
      expect(await store.read('books_text:${book.id}:${chapter.id}'), isNull);
      expect(await store.text(book, chapter), '事务内的新正文');
      expect((await store.entry(book))!.favorite, isTrue);
    },
  );
  test('wrong vault password does not unlock encrypted records', () async {
    await seed();
    await store.vault.create('secret-123');
    await store.moveToVault(book);
    store.vault.lock();

    expect(await store.vault.unlock('wrong-pass'), isFalse);
    expect(store.vault.unlocked, isFalse);
    expect(await store.text(book, chapter), isNull);
  });
  test('removing a book keeps downloads unless explicitly cleared', () async {
    await seed();
    await store.removeFromShelf(book, clearOffline: false);

    expect(await store.shelf(), isEmpty);
    expect(await store.savedText(book), {chapter.id});
    expect((await store.annotations(book)), isNotEmpty);

    await store.saveBook(book, chapters: [chapter]);
    await store.removeFromShelf(book, clearOffline: true);
    expect(await store.savedText(book), isEmpty);
    expect(await store.annotations(book), isNotEmpty);
  });
}

void _legacyRepairTests() {
  test(
    'unlock repairs plaintext records from existing private books',
    () async {
      await seed();
      await store.vault.create('secret-123');
      await store.moveToVault(book);
      final origin = 'books_latest_origin:${book.id}:${chapter.id}';
      final image = 'books_image_data:${book.id}:${chapter.id}:0';
      await store.write(origin, {'title': book.title});
      await store.write(image, 'old-private-image');
      await store.write(
        'books_text:${book.id}:${chapter.id}',
        'stale duplicate',
      );
      store.vault.lock();
      await store.vault.unlock('secret-123');
      expect(await store.read(origin), isNull);
      expect(await store.read(image), isNull);
      expect(await store.vault.readStrict(origin), {'title': book.title});
      expect(await store.vault.readStrict(image), 'old-private-image');
      expect(await store.text(book, chapter), body);
    },
  );
}

void _removalTests() {
  test('deleting a book can keep or clear offline files', () async {
    await seed();
    await store.deleteBook(book, clearOffline: false);
    expect(await store.shelf(), isEmpty);
    expect(await store.savedText(book), {chapter.id});
    expect(await store.annotations(book), isEmpty);

    await store.saveBook(book, chapters: [chapter]);
    await store.deleteBook(book, clearOffline: true);
    expect(await store.savedText(book), isEmpty);
  });
  test('encrypted offline provenance round-trips through the vault', () async {
    await store.saveBook(book, chapters: [chapter]);
    final evidence = BookDownloadEvidence(
      target: book,
      targetChapter: chapter,
      targetFingerprint: List.filled(64, 'a').join(),
      targetEpoch: 1,
      origin: book,
      originChapter: chapter,
      originFingerprint: List.filled(64, 'b').join(),
      originEpoch: 1,
    );
    await store.saveProvenText(book, chapter, body, evidence, () async {});
    expect((await store.provenText(book, chapter))!.body, body);

    await store.vault.create('secret-123');
    await store.moveToVault(book);
    expect((await store.provenText(book, chapter))!.body, body);
    expect(await store.savedText(book), {chapter.id});
    final raw = await rawRows('books_vault_data:books_proven_text_record:*');
    expect(raw, hasLength(1));
    expect(raw.values.single, isNot(contains(body)));

    store.vault.lock();
    expect(await store.provenText(book, chapter), isNull);
    expect(await store.savedText(book), isEmpty);
  });
  test('private shelf lists are encrypted and require an unlock', () async {
    await store.vault.create('secret-123');
    final lists = BookShelfLists(store, BookKind.text, private: true);
    await lists.save('夜读', ShelfListKind.list);
    expect((await lists.load()).single.name, '夜读');

    final raw = await rawRows('books_vault_data:books_shelf_lists:*');
    expect(raw.values.single, isNot(contains('夜读')));

    store.vault.lock();
    expect(await lists.load(), isEmpty);
    await expectLater(
      lists.save('另一本', ShelfListKind.list),
      throwsA(isA<FormatException>()),
    );
  });
  test(
    'corrupt ciphertext aborts migration without losing any records',
    () async {
      await seed();
      await store.vault.create('secret-123');
      await store.moveToVault(book);
      final key = '${BookVault.dataPrefix}books_text:${book.id}:${chapter.id}';
      await db.write('UPDATE app_meta SET value=? WHERE key=?', [
        'broken-cipher',
        key,
      ]);
      final before = await rawRows('${BookVault.dataPrefix}*');
      await expectLater(
        store.moveOutOfVault(book),
        throwsA(isA<FormatException>()),
      );
      expect(await rawRows('${BookVault.dataPrefix}*'), before);
      expect(store.vault.isPrivate(book.id), isTrue);
      expect(await store.shelf(), isEmpty);
    },
  );
}

void _encryptedRecordTests() {
  test(
    'rollback never publishes a private index or deletes public data',
    () async {
      await seed();
      await store.vault.create('secret-123');
      await expectLater(
        db.atomic(() async {
          await store.moveToVault(book);
          throw StateError('force rollback');
        }),
        throwsStateError,
      );
      expect(store.vault.isPrivate(book.id), isFalse);
      expect(await store.text(book, chapter), body);
      expect(await rawRows('${BookVault.dataPrefix}*'), isEmpty);
    },
  );
  test('locking before outer commit rolls back the entire migration', () async {
    await seed();
    await store.vault.create('secret-123');
    await expectLater(
      db.atomic(() async {
        await store.moveToVault(book);
        store.vault.lock();
      }),
      throwsA(isA<VaultLockedException>()),
    );
    expect(store.vault.isPrivate(book.id), isFalse);
    expect(await store.text(book, chapter), body);
    expect(await rawRows('${BookVault.dataPrefix}*'), isEmpty);
  });
  test(
    'late authentication and decryption cannot revive a locked session',
    () async {
      await store.vault.create('secret-123');
      final encoded = await store.vault.seal('test', {'secret': body});
      final opening = store.vault.open('test', encoded);
      store.vault.lock();
      await expectLater(opening, throwsA(isA<VaultLockedException>()));
      final unlocking = store.vault.unlock('secret-123');
      store.vault.lock();
      await expectLater(unlocking, throwsA(isA<VaultLockedException>()));
      expect(store.vault.unlocked, isFalse);
    },
  );
  test(
    'lock between encryption and commit rejects the pending write',
    () async {
      await store.vault.create('secret-123');
      await expectLater(
        db.atomic(() async {
          await store.vault.write('pending', body);
          store.vault.lock();
        }),
        throwsA(isA<VaultLockedException>()),
      );
      expect(await rawRows('${BookVault.dataPrefix}pending'), isEmpty);
    },
  );
}

void _rollbackTests() {
  test(
    'damaged config and orphan ciphertext cannot be overwritten by setup',
    () async {
      await db.write('INSERT INTO app_meta(key,value) VALUES(?,?)', [
        BookVault.configKey,
        '{broken',
      ]);
      await expectLater(
        store.vault.create('secret-123'),
        throwsA(isA<FormatException>()),
      );
      expect((await rawRows(BookVault.configKey)).values.single, '{broken');
      await db.write('DELETE FROM app_meta WHERE key=?', [BookVault.configKey]);
      store.vault.dispose();
      store = BookStore(db);
      await db.write('INSERT INTO app_meta(key,value) VALUES(?,?)', [
        '${BookVault.dataPrefix}orphan',
        'preserve-me',
      ]);
      await expectLater(
        store.vault.create('secret-123'),
        throwsA(isA<FormatException>()),
      );
      expect(
        (await rawRows('${BookVault.dataPrefix}orphan')).values.single,
        'preserve-me',
      );
    },
  );
  test('concurrent setup cannot replace an already created key', () async {
    final outcomes = await Future.wait([
      store.vault
          .create('secret-123')
          .then((_) => true, onError: (Object _) => false),
      store.vault
          .create('another-123')
          .then((_) => true, onError: (Object _) => false),
    ]);
    expect(outcomes, [true, false]);
    store.vault.lock();
    expect(await store.vault.unlock('secret-123'), isTrue);
  });
  test(
    'password and hint changes preserve each other and require access',
    () async {
      await store.vault.create('secret-123');
      await Future.wait([
        store.vault.changePassword('secret-123', 'new-secret-123'),
        store.vault.setHint('提示'),
      ]);
      store.vault.lock();
      await expectLater(
        store.vault.setHint('unauthorized'),
        throwsA(isA<VaultLockedException>()),
      );
      expect(await store.vault.unlock('new-secret-123'), isTrue);
      expect(store.vault.hint, '提示');
    },
  );
  test(
    'aggregated origins and selected cleanup text move with private data',
    () async {
      await seed();
      final key = 'books_latest_origin:${book.id}:${chapter.id}';
      await store.write(key, {'secret': body});
      await store.write('books_reading_cleanup:v1', [
        {'bookId': book.id, 'text': body, 'replacement': '', 'enabled': true},
      ]);
      await store.vault.create('secret-123');
      await store.moveToVault(book);
      expect(await store.read(key), isNull);
      expect(await store.read('books_reading_cleanup:v1'), isEmpty);
      expect(await store.readBookValue(book, key), {'secret': body});
      await store.writeBookValue(book, key, {'secret': 'new private origin'});
      expect(await store.read(key), isNull);
      await store.moveOutOfVault(book);
      expect(await store.read(key), {'secret': 'new private origin'});
      expect(
        jsonEncode(await store.read('books_reading_cleanup:v1')),
        contains(body),
      );
    },
  );
}

void _revocationTests() {
  test(
    'private removal retains encrypted notes and reachable offline catalog',
    () async {
      await seed();
      await store.vault.create('secret-123');
      await store.moveToVault(book);
      await store.removeFromShelf(book, clearOffline: false);
      expect(await store.vaultShelf(), isEmpty);
      expect(
        (await store.detachedShelf(private: true)).single.chapters.single.id,
        chapter.id,
      );
      expect(await store.detachedShelf(), isEmpty);
      await store.saveBook(book, chapters: [chapter]);
      await store.removeFromShelf(book, clearOffline: true);
      expect(store.vault.isPrivate(book.id), isTrue);
      expect((await store.annotations(book)).single['text'], '私密笔记');
      expect(await store.savedText(book), isEmpty);
    },
  );
  test(
    'adding a download list preserves other collection memberships',
    () async {
      final lists = BookShelfLists(store, BookKind.text);
      await lists.save('追更', ShelfListKind.group);
      await lists.save('收藏', ShelfListKind.collection);
      await lists.save('下载', ShelfListKind.list);
      final all = await lists.load();
      await lists.assign(book, {all[0].id, all[1].id});
      await lists.addToList(book, all[2].id);
      expect(
        (await lists.load()).where((list) => list.books.contains(book.id)),
        hasLength(3),
      );
    },
  );
}
