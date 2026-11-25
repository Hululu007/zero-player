import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_catalog_rebuild.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/domain/book.dart';

import '../../test_support/verified_temp_directory.dart';

void main() {
  final book = Book(
    'local',
    BookKind.text,
    '目录重建测试',
    '作者',
    Uri.parse('book:catalog-test'),
    documentFormat: 'txt',
  );
  final chapters = [
    BookChapter('原目录错误标题一', book.uri.replace(fragment: 'a')),
    BookChapter('原目录错误标题二', book.uri.replace(fragment: 'b')),
  ];
  const rules = [r'第\d+章.*', r'Chapter\s+\d+.*'];
  late VerifiedTempDirectory temp;
  late AppServices services;
  late BookStore store;
  late BookCatalogRebuild rebuild;

  setUp(() async {
    temp = await VerifiedTempDirectory.create('book-catalog-rebuild-');
    services = AppServices.scoped(temp.directory, AppDatabase.memory());
    store = services.books.store;
    rebuild = BookCatalogRebuild(services.books);
    await store.saveBook(book, chapters: chapters, favorite: true);
    await store.saveText(book, chapters.first, '序言正文\n第1章 新标题\n第一段');
  });

  tearDown(() async {
    await services.close();
    await temp.delete();
  });

  Future<List<BookChapter>> buildCatalog(List<String> patterns) async =>
      rebuild.rebuild(
        (await store.entry(book))!,
        patterns,
        CancellationToken(),
        available: () => true,
      );

  test(
    'complete text is resegmented using both rules and is still offline',
    () async {
      await expectLater(buildCatalog(rules), throwsFormatException);
      expect(await rebuild.catalog(book), isEmpty);
      await store.saveText(book, chapters.last, '第二段\nChapter 2 新标题\n结尾');

      final catalog = await buildCatalog(rules);
      expect(catalog.map((chapter) => chapter.title), [
        '序章',
        '第1章 新标题',
        'Chapter 2 新标题',
      ]);
      expect(await rebuild.rules(book), rules);
      expect(
        (await store.entry(book))!.chapters.map((chapter) => chapter.id),
        chapters.map((chapter) => chapter.id),
      );
      expect(
        await services.books.readText(book, catalog[1], CancellationToken()),
        '第1章 新标题\n第一段\n\n第二段\n',
      );
      expect(
        await services.books.readText(book, catalog.last, CancellationToken()),
        'Chapter 2 新标题\n结尾',
      );

      await expectLater(buildCatalog([r'[']), throwsFormatException);
      expect(
        (await rebuild.catalog(book)).map((chapter) => chapter.id),
        catalog.map((chapter) => chapter.id),
      );

      await store.saveText(book, chapters.last, '内容已变化\nChapter 2 新标题\n结尾');
      await expectLater(
        services.books.readText(book, catalog[1], CancellationToken()),
        throwsFormatException,
      );
      await store.deleteText(book, chapters.first);
      expect(await rebuild.catalog(book), isEmpty);
    },
  );

  test('rebuilt index and slices follow the book into the vault', () async {
    await store.saveText(book, chapters.last, '第二段\nChapter 2 新标题\n结尾');
    final result = await buildCatalog(rules);
    await store.vault.create('rebuild-test-secret');
    await store.moveToVault(book);

    expect(await store.read(rebuiltCatalogKey(book)), isNull);
    expect(await rebuild.catalog(book), isNotEmpty);
    store.vault.lock();
    expect(await rebuild.catalog(book), isEmpty);
    expect(await store.vault.unlock('rebuild-test-secret'), isTrue);
    expect(
      await services.books.readText(book, result.last, CancellationToken()),
      'Chapter 2 新标题\n结尾',
    );
    await store.moveOutOfVault(book);
    expect(await rebuild.catalog(book), isNotEmpty);
    await store.clearOffline(book);
    expect(await rebuild.catalog(book), isEmpty);
  });
}
