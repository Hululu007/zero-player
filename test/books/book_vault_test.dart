import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_download_evidence.dart';
import 'package:zero_player/features/books/data/book_shelf_lists.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/data/book_vault.dart';
import 'package:zero_player/features/books/domain/book.dart';

void main() {
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

  setUp(() {
    db = AppDatabase.memory();
    store = BookStore(db);
  });

  tearDown(() => db.close());

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
    return {
      for (final row in rows) row['key'] as String: row['value'] as String,
    };
  }

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
}
