import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/domain/book.dart';

void main() {
  test(
    'search reuses source snapshot and keeps preferred source first',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final root = await Directory.systemTemp.createTemp(
        'book-search-sources-',
      );
      final services = AppServices.scoped(root, AppDatabase.memory());
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      await services.settings.load();
      await services.supervision.load();
      final preferred = _source('preferred.test');
      final favorite = _source('favorite.test');
      final disabled = _source('disabled.test');
      await services.books.importSources([preferred, favorite, disabled]);
      await services.books.saveSource(preferred, {'enabled': true});
      await services.books.saveSource(favorite, {'enabled': true});
      BookSourceEntry entry(
        BookSource source, {
        bool favorite = false,
        bool enabled = true,
      }) => BookSourceEntry(source, enabled, favorite, '', '', null);
      final order = <String>[];
      final result = await services.books.find(
        BookKind.text,
        '星际',
        CancellationToken(),
        preferredSource: preferred.id,
        maxSources: 2,
        availableSources: [
          entry(favorite, favorite: true),
          entry(disabled, enabled: false),
          entry(preferred),
        ],
        onProgress: (update) {
          if (update.sourceId != null) order.add(update.sourceId!);
        },
      );
      expect(order, [preferred.id, favorite.id]);
      expect(result.books.map((book) => book.sourceId), [
        preferred.id,
        favorite.id,
      ]);
    },
  );

  test(
    'a stale search snapshot cannot use changed or disabled sources',
    () async {
      final root = await Directory.systemTemp.createTemp('book-search-stale-');
      final services = AppServices.scoped(root, AppDatabase.memory());
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      await services.settings.load();
      await services.supervision.load();
      final books = services.books;
      final source = _source('stale.test');
      await books.importSources([source]);
      await books.saveSource(source, {'enabled': true});
      var snapshot = (await books.sourceEntry(BookKind.text, source.id))!;

      Future<List<Book>> search(BookSourceEntry entry) async =>
          (await books.find(
            BookKind.text,
            '星际',
            CancellationToken(),
            availableSources: [entry],
          )).books;

      expect(await search(snapshot), hasLength(1));
      await books.setSourcesEnabled(BookKind.text, {source.id}, false);
      expect(await search(snapshot), isEmpty);
      await books.setSourcesEnabled(BookKind.text, {source.id}, true);
      snapshot = (await books.sourceEntry(BookKind.text, source.id))!;
      final changed = BookSource.fromJson({
        ...source.toJson(),
        'featured': [
          {'title': '星际新作品', 'url': '/new'},
        ],
      });
      await books.saveSource(source, {'source': changed.toJson()});
      expect(await search(snapshot), isEmpty);
      snapshot = (await books.sourceEntry(BookKind.text, source.id))!;
      expect((await search(snapshot)).single.title, '星际新作品');
      await books.saveSource(changed, {'group': '🔞'});
      expect(await search(snapshot), isEmpty);
    },
  );
}

BookSource _source(String host) => BookSource.fromJson({
  'name': host,
  'url': 'https://$host/',
  'kind': 'text',
  'format': 'featured',
  'featured': [
    {'title': '星际小说', 'url': '/book'},
  ],
  'rules': {
    'chapters': 'a',
    'chapterTitle': '@text',
    'chapterUrl': '@href',
    'content': 'p@text',
  },
});
