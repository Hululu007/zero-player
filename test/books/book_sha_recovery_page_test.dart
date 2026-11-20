import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/aoaostar_book_catalog.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/book_sources_page.dart';

void main() {
  testWidgets(
    'source file import recovers a reviewed rule without enabling it',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('book-sha-recovery-page-'),
      ))!;
      late AppServices services;
      late BookSource previous;
      late File sourceFile;
      await tester.runAsync(() async {
        services = AppServices.scoped(root, AppDatabase.memory());
        await services.settings.load();
        await services.supervision.load();
        final revision = (await AoaoStarBookCatalog.load()).revision;
        await services.books.store.write(
          'books_catalog_revision',
          '$revision:adult-filtered:2',
        );
        final bytes = await File(
          'assets/catalogs/books/legado/catalog.json.bz2',
        ).readAsBytes();
        final archive =
            jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(bytes))) as Map;
        previous = parseBookSourceRecord((archive['records'] as List)[12]);
        final candidate = BookSource.fromJson({
          ...previous.toJson(),
          'name': '已修订规则',
          'legado': {
            ...previous.legado!.toJson(),
            'rules': {'content': 'p@text', 'searchList': '.book'},
          },
        });
        await services.books.store.write('books_source:${previous.id}', {
          'source': previous.toJson(),
          'enabled': true,
          'favorite': true,
          'group': '珍藏分组',
        });
        await services.books.refreshSourceRisks();
        sourceFile = await File(
          p.join(root.path, 'source.json'),
        ).writeAsString(jsonEncode([candidate.toJson()]));
      });
      final oldPicker = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = _SourcePicker(sourceFile.path);
      addTearDown(() async {
        FileSelectorPlatform.instance = oldPicker;
        await tester.pumpWidget(const SizedBox.shrink());
        var closed = false;
        final closing = services.close().then((_) => closed = true);
        for (var i = 0; i < 400 && !closed; i++) {
          await tester.pump(const Duration(milliseconds: 10));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        expect(closed, isTrue);
        await closing;
        await tester.runAsync(() => root.delete(recursive: true));
      });

      await tester.pumpWidget(
        MaterialApp(
          home: BookSourcesPage(services: services, kind: BookKind.text),
        ),
      );
      await _waitFor(
        tester,
        () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      await tester.tap(find.byTooltip('导入书源'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入来源文件'));
      await _waitFor(
        tester,
        () => find.textContaining('更新 1').evaluate().isNotEmpty,
      );
      if (find.byTooltip('搜索渠道').evaluate().isNotEmpty) {
        await tester.tap(find.byTooltip('搜索渠道'));
        await tester.pump();
      }
      await tester.enterText(find.byType(TextField).first, '已修订规则');
      final row = find.widgetWithText(ListTile, '已修订规则');
      await _waitFor(tester, () => row.evaluate().isNotEmpty);
      final toggle = find.descendant(of: row, matching: find.byType(Switch));
      expect(tester.widget<Switch>(toggle).value, isFalse);
      expect(
        find.descendant(of: row, matching: find.byTooltip('取消收藏源')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.textContaining('珍藏分组')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _waitFor(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 600 && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(condition(), isTrue);
}

final class _SourcePicker extends FileSelectorPlatform {
  _SourcePicker(this.path);
  final String path;
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => XFile(path);
}
