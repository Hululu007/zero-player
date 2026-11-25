import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/aoaostar_book_catalog.dart';
import 'package:zero_player/features/books/data/book_source_groups.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/book_sources_page.dart';

void main() {
  testWidgets('single and bulk source menus add members to a group', (
    tester,
  ) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('book-source-members-'),
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
    final catalog = await AoaoStarBookCatalog.load();
    final filter = services.contentPolicy.filterAdult ? 'filtered' : 'all';
    await services.books.store.write(
      'books_catalog_revision',
      '${catalog.revision}:adult-$filter:2',
    );
    final first = _source('group-menu-one.test', '作品一');
    final second = _source('group-menu-two.test', '作品二');
    await services.books.importSources([first, second]);
    final groups = BookSourceGroups(services.books.store, BookKind.text);
    await groups.save('入口测试分组');
    await tester.pumpWidget(
      MaterialApp(
        home: BookSourcesPage(services: services, kind: BookKind.text),
      ),
    );
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byTooltip('来源操作').evaluate().isNotEmpty) break;
    }
    await tester.tap(find.byTooltip('搜索渠道'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'group-menu-');
    await tester.pumpAndSettle();
    final menu = find.descendant(
      of: find.widgetWithText(ListTile, first.name),
      matching: find.byTooltip('来源操作'),
    );
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加到分组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('入口测试分组'));
    await tester.pumpAndSettle();
    expect((await groups.load()).single.sourceIds, {first.id});
    await tester.tap(find.text('批量选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选筛选结果'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加到分组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('入口测试分组'));
    await tester.pumpAndSettle();
    expect((await groups.load()).single.sourceIds, {first.id, second.id});
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
