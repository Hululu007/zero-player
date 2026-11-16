import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/data/book_resource_limits.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/book_image_chapter.dart';
import 'package:zero_player/features/books/data/book_mixed_content.dart';
import 'package:zero_player/features/books/presentation/reader_pagination.dart';
import 'package:zero_player/features/books/presentation/reader_style.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4z8DwH4QZYAwAR8oH+WdZbrcAAAAASUVORK5CYII=',
);
final _book = Book(
  'fixture',
  BookKind.comic,
  '测试漫画',
  '',
  Uri.parse('https://books.test/book'),
);
final _chapter = BookChapter('第一章', Uri.parse('https://books.test/1'));
final _image = Uri.parse('https://books.test/image.png');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _storageTests();
  _layoutTests();
}

void _storageTests() {
  test(
    'clearing history preserves shelf, favorite, following, notes and downloads',
    () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final store = BookStore(db);
      await store.saveBook(
        _book,
        chapters: [_chapter],
        last: _chapter,
        position: .65,
        textOffset: 129,
        favorite: true,
        following: true,
      );
      await store.saveText(_book, _chapter, '已下载正文');
      await store.addAnnotation(_book, {'id': 'note', 'note': '保留笔记'});
      await store.write('rich_position_${_book.id}', {'offset': 123});
      final other = Book(
        'fixture',
        BookKind.audio,
        '听书',
        '',
        Uri.parse('https://books.test/audio'),
      );
      await store.saveBook(other, last: _chapter, position: .3);
      await store.clearHistory([_book]);
      final entry = (await store.entry(_book))!;
      expect(entry.last, isNull);
      expect(entry.position, 0);
      expect(entry.textOffset, isNull);
      expect(entry.favorite && entry.following, isTrue);
      expect(entry.chapters.single.id, _chapter.id);
      expect(await store.text(_book, _chapter), '已下载正文');
      expect(await store.annotations(_book), hasLength(1));
      expect(await store.read('rich_position_${_book.id}'), isNull);
      expect((await store.entry(other))!.last, _chapter.id);
    },
  );

  test(
    'bad image payloads do not overwrite readable caches or offline chapters',
    () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final store = BookStore(db);
      await store.cacheReadingImage(_book, _image, _png);
      await store.saveOfflineImages(_book, _chapter, {
        _image: _png,
      }, () async {});
      await expectLater(
        store.cacheReadingImage(_book, _image, [1, 2, 3]),
        throwsFormatException,
      );
      await expectLater(
        store.saveOfflineImages(_book, _chapter, {
          _image: [1, 2, 3],
        }, () async {}),
        throwsFormatException,
      );
      expect(await store.readingImage(_book, _image), _png);
      expect(await store.offlineImageBytes(_book, _chapter, _image), _png);
      final giant = List<int>.filled(BookResourceLimits.imageBytes + 1, 0);
      await expectLater(
        store.saveOfflineImages(_book, _chapter, {_image: giant}, () async {}),
        throwsFormatException,
      );
      expect(await store.offlineImageBytes(_book, _chapter, _image), _png);
    },
  );
}

void _layoutTests() {
  testWidgets('comic slides, restores progress and turns at tap edges', (
    tester,
  ) async {
    var progress = 0.0;
    final key = GlobalKey<BookImageChapterState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookImageChapter(
            key: key,
            images: [
              _image,
              _image.replace(path: '/two.png'),
              _image.replace(path: '/three.png'),
            ],
            mode: ReaderTurnMode.slide,
            animate: false,
            initialFraction: 1 / 3,
            loadImage: (_, _) async => _png,
            onNext: null,
            onProgress: (value) => progress = value,
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    final pager = tester.widget<PageView>(find.byType(PageView));
    expect(pager.controller!.page, 1);
    final rect = tester.getRect(find.byType(PageView));
    await tester.tapAt(Offset(rect.right - 10, rect.center.dy));
    await tester.pumpAndSettle();
    expect(progress, closeTo(2 / 3, .001));
    key.currentState!.turn(-1);
    await tester.pumpAndSettle();
    expect(progress, closeTo(1 / 3, .001));
    await tester.pumpWidget(const SizedBox());
  });

  _mixedTextTest();
  _justifyTest();
}

void _mixedTextTest() {
  testWidgets('mixed text uses reading ink, typography and alignment', (
    tester,
  ) async {
    const style = TextStyle(
      color: Colors.white,
      fontSize: 30,
      height: 2.2,
      fontFamily: 'NotoSerifSC',
      fontWeight: FontWeight.w600,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: BookImageChapter(
            images: const [],
            segments: const [BookTextSegment('夜间图文正文')],
            textStyle: style,
            textAlign: TextAlign.justify,
            margin: 30,
            loadImage: (_, _) async => _png,
            onNext: null,
          ),
        ),
      ),
    );
    final text = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(text.style, style);
    expect(text.textAlign, TextAlign.justify);
    expect(tester.takeException(), isNull);
  });
}

void _justifyTest() {
  testWidgets(
    'justify continues across page breaks and keeps paragraph endings short',
    (tester) async {
      final text = '少年推开窗看见山下的灯火一盏盏亮起来风从很远的地方吹来' * 60;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 364,
              height: 390,
              child: ReaderViewport(
                text: text,
                titleLength: 0,
                style: const TextStyle(fontSize: 18, height: 1.8),
                palette: ReaderPaper.white.palette(
                  ColorScheme.fromSeed(seedColor: Colors.blue),
                ),
                mode: ReaderTurnMode.slide,
                animate: false,
                texture: false,
                margin: 22,
                align: TextAlign.justify,
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
      final paragraph = tester.renderObject<RenderParagraph>(
        find
            .descendant(
              of: find.byType(ReaderViewport),
              matching: find.byType(RichText),
            )
            .first,
      );
      final painter = TextPainter(
        text: paragraph.text,
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.justify,
        maxLines: paragraph.maxLines,
      )..layout(maxWidth: paragraph.size.width);
      final lines = painter.computeLineMetrics();
      expect(lines.last.width, closeTo(paragraph.size.width, .01));
      expect(lines.last.hardBreak, isFalse);
      painter.dispose();
      final ending = TextPainter(
        text: const TextSpan(text: '段末短句', style: TextStyle(fontSize: 18)),
        textAlign: TextAlign.justify,
        textDirection: ui.TextDirection.ltr,
      )..layout(maxWidth: 320);
      expect(ending.computeLineMetrics().single.width, lessThan(320));
      ending.dispose();
      expect(tester.takeException(), isNull);
    },
  );
}
