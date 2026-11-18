import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/request_scheduler.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/platform/foreground_workload.dart';
import 'package:zero_player/features/books/application/reader_preloader.dart';
import 'package:zero_player/features/books/data/book_reading_cleanup.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/data/reader_fonts.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/book_image_chapter.dart';
import 'package:zero_player/features/books/presentation/book_reader_page.dart';
import 'package:zero_player/features/books/presentation/reader_font_picker.dart';
import 'package:zero_player/features/books/presentation/reader_pagination.dart';
import 'package:zero_player/features/books/presentation/reader_style.dart';

import '../../test_support/book_fixture_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _cleanupCases();
  _preloadingCases();
  _fontCases();
  _comicCases();
  _readerCases();
  _progressCases();
  _longLayoutCase();
  _returnToCompletedLayoutCase();
}

void _cleanupCases() {
  test('cleanup is scoped, literal, reversible and bounds expansion', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final books = BookReadingCleanup(
      // A fresh instance must restore the same rules without changing text.
      BookStore(db),
    );
    final one = Book('local', BookKind.text, '甲', '', Uri.parse('book:one'));
    final two = Book('local', BookKind.text, '乙', '', Uri.parse('book:two'));
    await books.save([
      ReadingCleanupRule(text: '[广告].*', bookId: one.id),
      const ReadingCleanupRule(text: '原词', replacement: '新词'),
    ]);
    final restored = BookReadingCleanup(BookStore(db));
    await restored.load();
    expect(restored.apply(one, '正文[广告].*原词'), '正文新词');
    expect(restored.apply(two, '正文[广告].*原词'), '正文[广告].*新词');
    await restored.save([]);
    expect(restored.apply(one, '正文[广告].*原词'), '正文[广告].*原词');
    await books.save([ReadingCleanupRule(text: '字', replacement: '长' * 2000)]);
    expect(() => books.apply(one, '字' * 10000), throwsFormatException);
  });

  test(
    'offline text wins over cache and cache hits do not rewrite rows',
    () async {
      final f = await _fixture();
      addTearDown(f.close);
      final source = bookFixtureSource('reader-cache.test');
      await f.services.books.importSources([source]);
      final book = Book(
        source.id,
        BookKind.text,
        '正文',
        '',
        source.endpoint.resolve('/b'),
      );
      final chapter = BookChapter('第一章', source.endpoint.resolve('/1'));
      final store = f.services.books.store;
      await store.cacheReading(book, chapter, '缓存正文');
      final sql =
          "SELECT rowid FROM app_meta WHERE key GLOB 'books_read_cache:*'";
      final before = await store.db.rows(sql);
      expect(
        await f.services.books.readText(book, chapter, CancellationToken()),
        '缓存正文',
      );
      expect(await store.db.rows(sql), before);
      await store.saveText(book, chapter, '离线正文');
      expect(
        await f.services.books.readText(book, chapter, CancellationToken()),
        '离线正文',
      );
      expect(await store.readingCache(book, chapter), '缓存正文');
      await store.clearReadingCache(book);
      expect(await store.text(book, chapter), '离线正文');
    },
  );
}

void _preloadingCases() {
  testWidgets(
    'preloading is serial, cancellable and respects network decision',
    (tester) async {
      final called = <String>[];
      final gate = Completer<void>();
      CancellationToken? active;
      final chapters = [
        for (var i = 0; i < 3; i++)
          BookChapter('第$i章', Uri.parse('https://reader.test/$i')),
      ];
      final preloader = ReaderPreloader((chapter, token) async {
        called.add(chapter.title);
        active = token;
        await gate.future;
        token.check();
      }, delay: const Duration(milliseconds: 10));
      addTearDown(preloader.dispose);
      preloader.schedule(chapters, allowed: () async => false);
      await tester.pump(const Duration(milliseconds: 20));
      expect(called, isEmpty);
      preloader.schedule(chapters);
      await tester.pump(const Duration(milliseconds: 20));
      expect(called, ['第0章']);
      preloader.cancel();
      expect(active!.isCancelled, isTrue);
      gate.complete();
      await tester.pump();
      expect(called, ['第0章']);
    },
  );

  test('request priority is isolated between concurrent async tasks', () async {
    final gate = Completer<void>();
    final job = withRequestPriority(RequestPriority.background, () async {
      await gate.future;
      return currentRequestPriority;
    });
    expect(currentRequestPriority, RequestPriority.interactive);
    gate.complete();
    expect(await job, RequestPriority.background);
  });

  test('reading workload leases nest and release idempotently', () {
    final work = ForegroundWorkload();
    final first = work.beginReading(), second = work.beginReading();
    expect(work.maintenanceAllowed, isFalse);
    first();
    first();
    expect(work.maintenanceAllowed, isFalse);
    second();
    expect(work.maintenanceAllowed, isTrue);
    work.setForeground(false);
    expect(work.maintenanceAllowed, isFalse);
    work.dispose();
  });
}

void _fontCases() {
  test(
    'reader preferences retain real system and known open font identities',
    () {
      final saved = ReaderPreferences.fromJson(
        const ReaderPreferences(
          family: 'system:Microsoft YaHei',
          preloadChapters: 5,
          protectCutout: false,
          topInset: 26,
        ).toJson(),
      );
      expect(saved.family, 'system:Microsoft YaHei');
      expect(saved.bodyStyle.fontFamily, 'Microsoft YaHei');
      expect(saved.topInset, 26);
      expect(saved.protectCutout, isFalse);
      expect(saved.preloadChapters, 5);
      expect(
        ReaderPreferences.fromJson({'family': openReaderFonts.first.id}).family,
        openReaderFonts.first.id,
      );
      expect(
        ReaderPreferences.fromJson({'family': 'open:untrusted'}).family,
        'NotoSerifSC',
      );
      expect(
        ReaderPreferences.fromJson({'preloadChapters': 100}).preloadChapters,
        5,
      );
    },
  );

  testWidgets('font picker enumerates device fonts and selects one', (
    tester,
  ) async {
    final f = await tester.runAsync(_fixture);
    addTearDown(() async {
      await f!.services.close();
      await tester.runAsync(() => f.root.delete(recursive: true));
    });
    const channel = MethodChannel('zero_player/reader_fonts');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => ['Device Serif', 'Device Sans'],
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    String? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                chosen = await showReaderFontPicker(
                  context,
                  f!.services.books.readerFonts,
                  'system',
                );
              },
              child: const Text('字体'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('字体'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.enterText(find.byType(TextField), 'Device Serif');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.widgetWithText(ListTile, 'Device Serif'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.widgetWithText(ListTile, 'Device Serif'));
    await tester.pumpAndSettle();
    expect(chosen, 'system:Device Serif');
    await tester.pumpWidget(const SizedBox());
  });
}

void _comicCases() {
  for (final mode in [
    ReaderTurnMode.slide,
    ReaderTurnMode.vertical,
    ReaderTurnMode.scroll,
  ]) {
    testWidgets('comic taps, drags and zoom coexist in ${mode.name}', (
      tester,
    ) async {
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4z8DwH4QZYAwAR8oH+WdZbrcAAAAASUVORK5CYII=',
      );
      var menus = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BookImageChapter(
              loadImage: (_, _) async => bytes,
              animate: false,
              mode: mode,
              images: [
                Uri.parse('https://comic.test/1'),
                Uri.parse('https://comic.test/2'),
              ],
              onNext: () {},
              onMenu: () => menus++,
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byType(BookImageChapter));
      await tester.tapAt(rect.center);
      await tester.pumpAndSettle();
      expect(menus, 1);
      expect(find.byType(InteractiveViewer), findsNothing);
      await tester.longPressAt(rect.center);
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await tester.tap(find.byTooltip('关闭图片'));
      await tester.pumpAndSettle();
      final scrollable = find
          .descendant(
            of: find.byType(BookImageChapter),
            matching: find.byType(Scrollable),
          )
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      final before = position.pixels;
      await tester.tapAt(
        mode.horizontal
            ? Offset(rect.right - 10, rect.center.dy)
            : Offset(rect.center.dx, rect.bottom - 10),
      );
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(before));
      expect(menus, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

void _readerCases() {
  testWidgets('reader cleanup preserves source and avoids camera cutout', (
    tester,
  ) async {
    final f = await tester.runAsync(_fixture);
    addTearDown(() async {
      await f!.services.close();
      await tester.runAsync(() => f.root.delete(recursive: true));
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.padding = const FakeViewPadding(top: 32, bottom: 20);
    tester.view.viewPadding = const FakeViewPadding(top: 32, bottom: 20);
    addTearDown(tester.view.reset);
    final book = Book(
      'local',
      BookKind.text,
      '测试书',
      '',
      Uri.parse('book:cleanup'),
    );
    final chapter = BookChapter('第一章', Uri.parse('book:cleanup#1'));
    final books = f!.services.books;
    await books.store.saveText(book, chapter, '正文与广告，继续阅读');
    await books.store.write(
      'books_reader_preferences',
      const ReaderPreferences(topInset: 12).toJson(),
    );
    await books.readingCleanup.save([
      ReadingCleanupRule(text: '广告', bookId: book.id),
    ]);
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
    var viewport = tester.widget<ReaderViewport>(find.byType(ReaderViewport));
    expect(viewport.text, contains('正文与，继续阅读'));
    expect(tester.getRect(find.byType(ReaderViewport)).top, 44);
    expect(await books.store.text(book, chapter), '正文与广告，继续阅读');
    // The selected-text action opens an editor with the exact quote.
    viewport.onSelection('继续阅读');
    viewport.onCleanup!();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '继续阅读'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(1), '精彩内容');
    await tester.tap(find.text('保存规则'));
    await tester.pumpAndSettle();
    viewport = tester.widget<ReaderViewport>(find.byType(ReaderViewport));
    expect(viewport.text, contains('正文与，精彩内容'));
    expect(await books.store.text(book, chapter), '正文与广告，继续阅读');
    await books.readingCleanup.save([]);
    await tester.pumpAndSettle();
    viewport = tester.widget<ReaderViewport>(find.byType(ReaderViewport));
    expect(viewport.text, contains('正文与广告，继续阅读'));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}

void _progressCases() {
  test('progress-only writes preserve the catalog and shelf flags', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = BookStore(db);
    final book = Book(
      'local',
      BookKind.text,
      '书',
      '',
      Uri.parse('book:progress'),
    );
    final chapters = [
      for (var i = 0; i < 4000; i++)
        BookChapter('第 $i 章', Uri.parse('book:progress#$i')),
    ];
    await store.saveBook(
      book,
      chapters: chapters,
      favorite: true,
      following: true,
    );
    await store.saveReadingPosition(book, chapters[10], .35, 200);
    final saved = (await store.entry(book))!;
    expect(saved.chapters.length, 4000);
    expect(saved.last, chapters[10].id);
    expect(saved.position, .35);
    expect(saved.textOffset, 200);
    expect(saved.favorite, isTrue);
    expect(saved.following, isTrue);
  });
}

void _longLayoutCase() {
  testWidgets('long layout yields to input and discards an obsolete chapter', (
    tester,
  ) async {
    final text = ValueNotifier('长章节排版时仍应响应操作。' * 30000);
    addTearDown(text.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [
              TextButton(
                onPressed: () => text.value = '新的章节正文',
                child: const Text('切换章节'),
              ),
            ],
          ),
          body: ValueListenableBuilder<String>(
            valueListenable: text,
            builder: (context, value, _) => ReaderViewport(
              text: value,
              titleLength: 0,
              style: const TextStyle(fontSize: 21, height: 1.8),
              palette: ReaderPaper.white.palette(Theme.of(context).colorScheme),
              mode: ReaderTurnMode.slide,
              animate: false,
              texture: false,
              margin: 22,
              initial: readerProgress(0),
              onProgress: (_) {},
              canCross: (_) => false,
              onBoundary: (_) {},
              onSelection: (_) {},
              onAnnotate: () {},
            ),
          ),
        ),
      ),
    );
    expect(find.text('正在排版长章节…'), findsOneWidget);
    await tester.tap(find.text('切换章节'));
    await tester.pumpAndSettle();
    expect(find.text('新的章节正文'), findsOneWidget);
    expect(find.text('正在排版长章节…'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

void _returnToCompletedLayoutCase() {
  testWidgets('returning to a completed layout cancels pending work', (
    tester,
  ) async {
    final previous = '已完成的上一章正文。' * 1500;
    final next = '尚未完成排版的新章节正文。' * 40000;
    final text = ValueNotifier(previous);
    addTearDown(text.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<String>(
            valueListenable: text,
            builder: (context, value, _) => ReaderViewport(
              text: value,
              titleLength: 0,
              style: const TextStyle(fontSize: 21, height: 1.8),
              palette: ReaderPaper.white.palette(Theme.of(context).colorScheme),
              mode: ReaderTurnMode.slide,
              animate: false,
              texture: false,
              margin: 22,
              initial: readerProgress(0),
              onProgress: (_) {},
              canCross: (_) => false,
              onBoundary: (_) {},
              onSelection: (_) {},
              onAnnotate: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    text.value = next;
    await tester.pump();
    expect(find.text('正在排版长章节…'), findsOneWidget);
    text.value = previous;
    await tester.pump();
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('正在排版长章节…'), findsNothing);
    }
    // Reentering the canceled chapter must start a fresh layout.
    text.value = next;
    await tester.pump();
    expect(find.text('正在排版长章节…'), findsOneWidget);
    text.value = '完成';
    await tester.pumpAndSettle();
    expect(find.text('完成'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

// Keep fixture lifecycle independent of Flutter's fake clock and network.
final class _Fixture {
  _Fixture(this.root, this.services);
  final Directory root;
  final AppServices services;
  Future<void> close() async {
    await services.close();
    await root.delete(recursive: true);
  }
}

Future<_Fixture> _fixture() async {
  final root = await Directory.systemTemp.createTemp('reader-upgrade-');
  final services = AppServices.scoped(root, AppDatabase.memory());
  await services.settings.load();
  await services.supervision.load();
  return _Fixture(root, services);
}
