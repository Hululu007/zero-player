import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/application/reader_preloader.dart';
import 'package:zero_player/features/books/data/book_download_evidence.dart';
import 'package:zero_player/features/books/data/book_mixed_content.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/domain/book.dart';

final book = Book(
  's',
  BookKind.text,
  'Book',
  '',
  Uri.parse('https://book.test/1'),
);
final chapter = BookChapter('One', Uri.parse('https://book.test/1/1'));
final evidence = BookDownloadEvidence(
  target: book,
  targetChapter: chapter,
  targetFingerprint: 'a' * 64,
  targetEpoch: 1,
  origin: book,
  originChapter: chapter,
  originFingerprint: 'a' * 64,
  originEpoch: 1,
);

void main() {
  late AppDatabase db;
  late BookStore store;
  setUp(() {
    db = AppDatabase.memory();
    store = BookStore(db);
  });
  tearDown(() => db.close());
  test(
    'filtered reader snapshot preserves hidden directory and omission notice',
    () async {
      final hidden = BookChapter('Hidden', Uri.parse('https://book.test/1/2'));
      await store.saveBook(book, chapters: [chapter, hidden]);
      final raw = await store.read('books_shelf:${book.id}') as Map;
      await store.write('books_shelf:${book.id}', {
        ...raw,
        'catalogOmitted': 5,
      });
      await store.saveBook(
        book,
        chapters: [chapter],
        last: chapter,
        position: .5,
        textOffset: 10,
        preserveCatalog: true,
      );
      final saved = (await store.entry(book))!;
      expect(saved.chapters.map((c) => c.id), [chapter.id, hidden.id]);
      expect(saved.catalogOmitted, 5);
      expect(saved.textOffset, 10);
      await store.updateShelfChapters(book, [chapter]);
      expect((await store.entry(book))!.catalogOmitted, 5);
    },
  );
  test(
    'new provenance preserves old evidence while advancing the current pointer',
    () async {
      for (var i = 0; i < 3; i++) {
        await store.saveProvenText(
          book,
          chapter,
          'Body $i',
          evidence,
          () async {},
        );
      }
      final rows = await db.rows(
        "SELECT key FROM app_meta WHERE key GLOB 'books_proven_text_record:*'",
      );
      expect(rows, hasLength(3));
      expect((await store.provenText(book, chapter))!.body, 'Body 2');
    },
  );
  test(
    'failed final validation rolls back the new proof and pointer together',
    () async {
      await store.saveProvenText(book, chapter, 'Old', evidence, () async {});
      var checks = 0;
      await expectLater(
        store.saveProvenText(book, chapter, 'New', evidence, () async {
          if (++checks == 2) throw StateError('revoked');
        }),
        throwsStateError,
      );
      expect((await store.provenText(book, chapter))!.body, 'Old');
      expect(
        await db.rows(
          "SELECT key FROM app_meta WHERE key GLOB 'books_proven_text_record:*'",
        ),
        hasLength(1),
      );
    },
  );
  test('mixed cache enforces bytes for Chinese text', () async {
    await store.cacheMixedReading(book, chapter, [
      BookTextSegment('中' * 180000),
    ]);
    expect(await store.mixedReading(book, chapter), isEmpty);
    await store.cacheMixedReading(book, chapter, [const BookTextSegment('正文')]);
    expect(await store.mixedReading(book, chapter), hasLength(1));
  });
  test(
    'speculative StateError does not escape an unawaited preloader',
    () async {
      final ran = Completer<void>();
      final loader = ReaderPreloader((_, _) async {
        ran.complete();
        throw StateError('closed');
      }, delay: Duration.zero);
      addTearDown(loader.dispose);
      loader.schedule([chapter]);
      await ran.future;
      await Future<void>.delayed(Duration.zero);
    },
  );
}
