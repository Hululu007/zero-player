import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_source_groups.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/book_cover.dart';
import 'package:zero_player/features/books/presentation/book_discovery_view.dart';
import 'package:zero_player/features/books/presentation/book_search_page.dart';

void main() {
  testWidgets('selected group scopes discovery and search without covers', (
    tester,
  ) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('book-source-groups-'),
    ))!;
    final services = AppServices.scoped(root, AppDatabase.memory());
    addTearDown(() async {
      await tester.runAsync(() async {
        await services.close();
        await root.delete(recursive: true);
      });
    });
    await services.settings.load();
    await services.supervision.load();
    final repository = services.books;
    for (final entry in await repository.sources(
      BookKind.text,
      enabledOnly: true,
    )) {
      await repository.saveSource(entry.source, {'enabled': false});
    }
    final included = _source('scoped.test', '分组内星际小说');
    final excluded = _source('other.test', '分组外星际小说');
    await repository.importSources([included, excluded]);
    await repository.setSourcesEnabled(BookKind.text, {
      included.id,
      excluded.id,
    }, true);
    final sourceGroups = BookSourceGroups(repository.store, BookKind.text);
    await sourceGroups.save('书友推荐');
    final id = (await sourceGroups.load()).single.id;
    await sourceGroups.updateMembers(id, add: {included.id}, remove: {});
    await sourceGroups.save('星际分组', id: id);
    final groups = await sourceGroups.load();
    expect(groups.single.sourceIds, {included.id});
    expect(
      await BookSourceGroups(repository.store, BookKind.comic).load(),
      isEmpty,
    );
    await repository.store.write('books_discovery_group:text', id);
    final sources = await repository.sources(BookKind.text, enabledOnly: true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookDiscoveryView(
            repository: repository,
            kind: BookKind.text,
            sources: sources,
            sourceGroups: groups,
            active: true,
            onOpen: (_, {bool direct = false}) {},
            onSearch: (_, _, _) {},
            onSourceFavorite: (_, _) {},
            onManage: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('分组内星际小说'), findsWidgets);
    expect(find.text('分组外星际小说'), findsNothing);

    await repository.store.write('books_search_without_covers', true);
    await tester.pumpWidget(
      MaterialApp(
        home: BookSearchPage(
          repository: repository,
          kind: BookKind.text,
          query: '星际',
          sourceGroupId: id,
          onOpen: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('分组内星际小说'), findsOneWidget);
    expect(find.text('分组外星际小说'), findsNothing);
    expect(find.byType(BookCover), findsNothing);
    await tester.tap(find.text('快速搜索'));
    await tester.pumpAndSettle();
    expect(find.byType(BookCover), findsOneWidget);
    expect(await repository.store.read('books_search_without_covers'), isFalse);
    await tester.pumpWidget(const SizedBox());
  });
}

BookSource _source(String host, String title) => BookSource.fromJson({
  'name': host,
  'url': 'https://$host/',
  'format': 'featured',
  'kind': 'text',
  'featured': [
    {'title': title, 'url': '/book'},
  ],
  'rules': {
    'chapters': 'a',
    'chapterTitle': '@text',
    'chapterUrl': '@href',
    'content': 'p@text',
  },
});
