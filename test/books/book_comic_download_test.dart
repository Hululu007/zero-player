import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

import '../../test_support/book_fixture_source.dart';
import '../../test_support/comic_source_authorization.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'private offline images encrypt, migrate, and delete without plaintext remnants',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final store = f.services.books.store;
      await store.saveBook(f.book, chapters: [f.chapter]);
      await store.vault.create('secret-123');
      await store.moveToVault(f.book);
      await f.seedImages();
      expect(await store.offlineImages(f.book, f.chapter), f.images);
      expect(await store.savedImages(f.book), {f.chapter.id});
      expect(
        await store.db.rows(
          "SELECT key FROM app_meta WHERE key GLOB 'books_image_data:*'",
        ),
        isEmpty,
      );
      await store.moveOutOfVault(f.book);
      expect(await store.offlineImages(f.book, f.chapter), f.images);
      await store.moveToVault(f.book);
      store.vault.lock();
      expect(await store.offlineImages(f.book, f.chapter), isNull);
      expect(await store.savedImages(f.book), isEmpty);
      await store.vault.unlock('secret-123');
      await store.clearOffline(f.book);
      expect(await store.savedImages(f.book), isEmpty);
      expect(await store.offlineImages(f.book, f.chapter), isNull);
    },
  );

  test('comic download preserves offline image order and bytes', () async {
    final f = await _Fixture.create();
    addTearDown(f.close);
    await f.seedImages();
    await f.services.books.download(f.book, f.chapter, CancellationToken());
    expect(
      await f.services.books.store.offlineImageAddresses(f.book, f.chapter),
      f.images.keys.toList(),
    );
    expect(
      await f.services.books.store.offlineImages(f.book, f.chapter),
      f.images,
    );
  });

  test(
    'cancelled comic download retains the previous offline images',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      await f.seedImages();
      final token = CancellationToken()..cancel();
      await expectLater(
        f.services.books.download(f.book, f.chapter, token),
        throwsA(isA<RequestCancelled>()),
      );
      expect(
        await f.services.books.store.offlineImages(f.book, f.chapter),
        f.images,
      );
    },
  );

  _accessAndPublicationTests();
}

void _accessAndPublicationTests() {
  test(
    'a disabled comic source cannot publish and preserves old images',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      await f.seedImages();
      await f.services.books.saveSource(f.source, {'enabled': false});
      // The offline data is readable by the old cache path, so publication must
      // still check that the original source is currently enabled.
      expect(f.services.books.bookAllowed(f.book), isTrue);
      await expectLater(
        f.services.books.download(f.book, f.chapter, CancellationToken()),
        throwsFormatException,
      );
      expect(
        await f.services.books.store.offlineImages(f.book, f.chapter),
        f.images,
      );
    },
  );

  test(
    'adult evidence blocks comic download without deleting images',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      await f.seedImages();
      await f.services.books.markSourceRisk(f.source, adult: true);
      await expectLater(
        f.services.books.download(f.book, f.chapter, CancellationToken()),
        throwsA(isA<ContentBlocked>()),
      );
      expect(
        await f.services.books.store.offlineImages(f.book, f.chapter),
        f.images,
      );
    },
  );

  test(
    'cancellation at image publication keeps the old transaction data',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      await f.seedImages();
      final token = CancellationToken();
      var validated = false;
      await expectLater(
        f.services.books.store.saveOfflineImages(
          f.book,
          f.chapter,
          {
            f.images.keys.first: base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4z8DwH4QZYAwAR8oH+WdZbrcAAAAASUVORK5CYII=',
            ),
          },
          () async {
            validated = true;
            token.cancel();
            token.check();
          },
        ),
        throwsA(isA<RequestCancelled>()),
      );
      expect(validated, isTrue);
      expect(
        await f.services.books.store.offlineImages(f.book, f.chapter),
        f.images,
      );
    },
  );
}

final class _Fixture {
  _Fixture(this.root, this.services);

  final Directory root;
  final AppServices services;
  final source = bookFixtureSource('comic-fixture.test', kind: BookKind.comic);
  late final book = Book(
    source.id,
    BookKind.comic,
    '漫画示例',
    '作者',
    source.endpoint.resolve('/book'),
  );
  late final chapter = BookChapter('第一话', source.endpoint.resolve('/chapter'));
  late final images = <Uri, List<int>>{
    source.endpoint.resolve('/first.png'): base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4z8DwH4QZYAwAR8oH+WdZbrcAAAAASUVORK5CYII=',
    ),
    source.endpoint.resolve('/second.png'): base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4z8DwH4QZYAwAR8oH+WdZbrcAAAAASUVORK5CYII=',
    ),
  };

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('book-comic-download-');
    final services = AppServices.scoped(root, AppDatabase.memory());
    await services.settings.load();
    await services.supervision.load();
    final fixture = _Fixture(root, services);
    await services.books.importSources([fixture.source]);
    await authorizeComicFixture(services, fixture.source);
    await services.books.saveSource(fixture.source, {'enabled': true});
    return fixture;
  }

  Future<void> seedImages() => services.books.store.saveOfflineImages(
    book,
    chapter,
    images,
    () async {},
  );

  Future<void> close() async {
    await services.close();
    await root.delete(recursive: true);
  }
}
