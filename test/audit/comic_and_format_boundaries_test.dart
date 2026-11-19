import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/data/book_resource_limits.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';
import '../../test_support/book_fixture_source.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4z8DwH4QZYAwAR8oH+WdZbrcAAAAASUVORK5CYII=',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final data in ['missing', 'base64', 'image', 'empty', 'valid']) {
    test('AUD-03 validates full comic payload: $data', () => _comicCase(data));
  }
  test(
    'AUD-09 oversized replacement rolls back to original private images',
    _quotaRollback,
  );
  test(
    'AUD-05 explicit and legacy formats preserve content identity',
    _formats,
  );
}

Future<void> _comicCase(String data) async {
  final root = await Directory.systemTemp.createTemp('audit-comic-boundary-');
  final services = AppServices.scoped(root, AppDatabase.memory());
  try {
    await services.settings.load();
    await services.supervision.load();
    final source = bookFixtureSource(
      'comic-boundary.test',
      kind: BookKind.comic,
    );
    await services.books.importSources([source]);
    const password = 'comic-fixture-password';
    await services.supervision.saveCredentials(
      await services.supervision.prepareCredentials(password),
    );
    await services.supervision.execute(
      SensitiveOperation.supervision,
      () => services.supervision.setEnabled(false),
      password: password,
    );
    await services.supervision.execute(
      SensitiveOperation.supervision,
      () => services.books.comicAccess.approve(source),
      password: password,
    );
    await services.books.ensureSourceRiskLoaded();
    final book = Book(
      source.id,
      BookKind.comic,
      'Comic',
      '',
      source.endpoint.resolve('/book'),
    );
    final chapter = BookChapter('1', source.endpoint.resolve('/chapter'));
    final image = source.endpoint.resolve('/1.png');
    final store = services.books.store;
    await store.write(
      'books_image_offline:${book.id}:${chapter.id}',
      data == 'empty' ? [] : [image.toString()],
    );
    if (data != 'missing') {
      await store.write(
        'books_image_data:${book.id}:${chapter.id}:0',
        data == 'base64'
            ? '@invalid@'
            : base64Encode(data == 'image' ? [1, 2, 3] : _png),
      );
    }
    final result = await services.books.reusableDownloads(book, [
      chapter,
    ], CancellationToken());
    expect(result, data == 'valid' ? {chapter.id} : isEmpty);
    // Failed reuse validation retains the old index for atomic repair.
    expect(await store.offlineImageAddresses(book, chapter), isNotNull);
  } finally {
    await services.close();
    await root.delete(recursive: true);
  }
}

Future<void> _quotaRollback() async {
  final root = await Directory.systemTemp.createTemp('audit-quota-boundary-');
  final services = AppServices.scoped(root, AppDatabase.memory());
  try {
    await services.settings.load();
    await services.supervision.load();
    final store = services.books.store;
    final book = Book(
      'local',
      BookKind.comic,
      'Comic',
      '',
      Uri.parse('book:quota'),
    );
    final chapter = BookChapter('1', Uri.parse('book:quota#1'));
    final first = Uri.parse('https://comic.test/1.png');
    final second = Uri.parse('https://comic.test/2.png');
    await store.saveBook(book, chapters: [chapter]);
    await store.vault.create('audit-boundary-secret');
    await store.moveToVault(book);
    await store.saveOfflineImages(book, chapter, {first: _png}, () async {});
    final used =
        (await store.db.rows(
              "SELECT SUM(length(CAST(value AS BLOB))) AS n FROM app_meta WHERE key GLOB 'books_vault_data:*'",
            )).single['n']
            as int;
    await store.db.write('INSERT INTO app_meta VALUES(?,zeroblob(?))', [
      'books_vault_data:quota-filler',
      BookResourceLimits.offlineImageBytes - used - 10,
    ]);
    await expectLater(
      store.saveOfflineImages(book, chapter, {
        first: _png,
        second: _png,
      }, () async {}),
      throwsFormatException,
    );
    expect(await store.offlineImages(book, chapter), {first: _png});
    await store.saveOfflineImages(book, chapter, {first: _png}, () async {});
    expect(await store.offlineImages(book, chapter), {first: _png});
  } finally {
    await services.close();
    await root.delete(recursive: true);
  }
}

Future<void> _formats() async {
  final root = await Directory.systemTemp.createTemp('audit-format-boundary-');
  final services = AppServices.scoped(root, AppDatabase.memory());
  try {
    final legacy = Book(
      'local',
      BookKind.text,
      'Legacy',
      '',
      Uri.parse('book:content-hash'),
    );
    await services.books.documents.create(recursive: true);
    for (final extension in ['epub', 'pdf']) {
      final file = services.books.documentFile(legacy, extension);
      await file.writeAsString('type detection fixture');
      expect(await services.books.localDocumentFormat(legacy), extension);
      await file.delete();
      final json = legacy.toJson()..['documentFormat'] = extension;
      final restored = Book.fromJson(json);
      expect(restored.id, legacy.id);
      expect(restored.documentFormat, extension);
      expect(restored.withDetails(legacy).documentFormat, extension);
      expect(Book.fromJson(restored.toJson()).documentFormat, extension);
    }
    expect(await services.books.localDocumentFormat(legacy), 'txt');
  } finally {
    await services.close();
    await root.delete(recursive: true);
  }
}
