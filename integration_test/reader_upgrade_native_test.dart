import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/features/books/data/reader_fonts.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/book_reader_page.dart';
import 'package:zero_player/features/books/presentation/reader_pagination.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  _fontNativeTest();
  _progressNativeTest();
  _layoutNativeTest();
}

void _fontNativeTest() {
  testWidgets('native device families and verified open fonts render offline', (
    tester,
  ) async {
    final root = await Directory.systemTemp.createTemp('reader-font-native-');
    final services = AppServices.scoped(root, AppDatabase.memory());
    try {
      final fonts = services.books.readerFonts;
      final families = await fonts.systemFamilies();
      expect(families, isNotEmpty);
      final selected =
          families.where((name) => name.contains('YaHei')).firstOrNull ??
          families.first;
      expect(await fonts.ensure('system:$selected'), isTrue);
      await fonts.root.create(recursive: true);
      const project = String.fromEnvironment('PROJECT_ROOT');
      for (final font in openReaderFonts) {
        if (const bool.fromEnvironment('RUN_READER_FONT_ONLINE')) {
          await fonts.download(font, CancellationToken());
        } else {
          final audit = Directory('$project/build/reader-font-audit-20261117');
          await File(
            '${audit.path}/${font.file}',
          ).copy('${fonts.root.path}/${font.file}');
          await File(
            '${audit.path}/${font.file.replaceAll('.otf', '')}-LICENSE.txt',
          ).copy('${fonts.root.path}/${font.file}.OFL.txt');
        }
        expect(await fonts.ensure(font.id), isTrue);
        // The selection survives a new store instance, not just a loaded alias.
        expect(
          await ReaderFontStore(fonts.root, fonts.network).ensure(font.id),
          isTrue,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  Text(
                    '系统字体：山川日月，书卷常新',
                    style: TextStyle(fontFamily: selected),
                  ),
                  Text('开源字体：山川日月，书卷常新', style: TextStyle(fontFamily: font.id)),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    } finally {
      await tester.pumpWidget(const SizedBox());
      await services.close();
      await root.delete(recursive: true);
    }
  });
}

void _progressNativeTest() {
  testWidgets(
    'continuous reading throttles progress writes and flushes on exit',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'reader-progress-native-',
      );
      final services = AppServices.scoped(root, AppDatabase.memory());
      await services.settings.load();
      await services.supervision.load();
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      final books = services.books;
      final book = Book(
        'local',
        BookKind.text,
        '进度书',
        '',
        Uri.parse('book:flush'),
      );
      final chapter = BookChapter('第一章', Uri.parse('book:flush#1'));
      await books.store.saveText(book, chapter, '用于检查连续阅读进度保存的长正文。' * 100);
      await tester.pumpWidget(
        MaterialApp(
          home: BookReaderPage(
            repository: books,
            book: book,
            chapters: [chapter],
            initial: chapter,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await books.store.entry(book);
      var writes = 0;
      final changes = books.store.db
          .changesFor({'app_meta'})
          .listen((_) => writes++);
      final viewport = tester.widget<ReaderViewport>(
        find.byType(ReaderViewport),
      );
      for (var i = 1; i <= 10; i++) {
        viewport.onProgress(readerProgress(i / 20, offset: i * 10));
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(writes, 0);
      await tester.pump(const Duration(milliseconds: 1100));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await books.store.entry(book);
      expect(writes, 1);
      viewport.onProgress(readerProgress(.8, offset: 800));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect((await books.store.entry(book))?.textOffset, 800);
      await changes.cancel();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

void _layoutNativeTest() {
  testWidgets('reader layout benchmark preserves long chapter contents', (
    tester,
  ) async {
    for (final count in [3000, 15000, 100000, 500000]) {
      final text = List.filled(
        (count / 20).ceil(),
        '长章节性能测试，文字顺序应保持一致。\n',
      ).join();
      final watch = Stopwatch()..start();
      final pages = paginateReadingText(
        text,
        const TextStyle(fontFamily: 'NotoSerifSC', fontSize: 21, height: 1.8),
        const Size(346, 710),
        TextScaler.noScaling,
        TextDirection.ltr,
      );
      watch.stop();
      expect(pages.join(), text);
      // Diagnostic timing, never a portable assertion about device frame rate.
      debugPrint(
        'READER_LAYOUT chars=${text.length} pages=${pages.length} ms=${watch.elapsedMilliseconds}',
      );
    }
  });
}
