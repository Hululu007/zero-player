import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/book_search_page.dart';

void main() {
  testWidgets(
    'search lists newest chapter with channel and each edition update',
    (tester) async {
      late Directory root;
      late AppServices services;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('search-latest-');
        services = AppServices.scoped(root, AppDatabase.memory());
        await services.settings.load();
        await services.supervision.load();
        for (final entry in await services.books.sources(
          BookKind.text,
          enabledOnly: true,
        )) {
          await services.books.saveSource(entry.source, {'enabled': false});
        }
        final sources = [
          _source('a', '旧渠道', '第10章', '2026-11-17'),
          _source('b', '新渠道', '第12章', '2026-11-18'),
          _source('c', '无章节渠道', '', '2026-11-19'),
        ];
        await services.books.importSources(sources);
        for (final source in sources) {
          await services.books.saveSource(source, {'enabled': true});
        }
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await services.close();
          await root.delete(recursive: true);
        });
      });
      await tester.pumpWidget(
        MaterialApp(
          home: BookSearchPage(
            repository: services.books,
            kind: BookKind.text,
            query: '星际',
            onOpen: (_) async {},
          ),
        ),
      );
      for (var i = 0; i < 100 && find.text('星际小说').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.text('最新章节：第12章（新渠道）'), findsOneWidget);
      await tester.tap(find.text('星际小说'));
      await tester.pumpAndSettle();
      expect(find.textContaining('最新章节：第10章'), findsOneWidget);
      expect(find.textContaining('最新章节：第12章'), findsNWidgets(2));
      expect(find.textContaining('更新：2026-11-18'), findsOneWidget);
      expect(find.textContaining('最新章节：渠道未提供'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

BookSource _source(String host, String name, String latest, String updated) =>
    BookSource.fromJson({
      'name': name,
      'url': 'https://$host.example/',
      'format': 'featured',
      'kind': 'text',
      'featured': [
        {
          'title': '星际小说',
          'author': '作者',
          'url': '/book',
          'latestChapter': latest,
          'updatedLabel': updated,
        },
      ],
      'rules': {
        'chapters': 'a',
        'chapterTitle': '@text',
        'chapterUrl': '@href',
        'content': 'p@text',
      },
    });
