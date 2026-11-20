import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_download_plan.dart';

import '../../test_support/book_editions_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('follows all directory dropdown pages once and in order', () async {
    final f = await BookEditionsFixture.create(
      targetChapterCount: 40,
      targetCatalogPages: 251,
    );
    addTearDown(f.close);
    final chapters = await f.services.books.chapters(
      f.book,
      CancellationToken(),
    );
    expect(chapters.map((c) => c.title), [
      for (var i = 1; i <= 10040; i++) '第$i章',
    ]);
  });

  test('download plans preserve selected chapter ids past 4000', () {
    final ids = List.generate(10000, (index) => '$index');
    final plan = BookDownloadPlan(1, ids.length, false, chapterIds: ids);
    expect(BookDownloadPlan.fromJson(plan.toJson())?.chapterIds, ids);
  });

  test(
    'reads the current public Ying Shu catalog through the native parser',
    () async {
      final rows =
          jsonDecode(
                File('assets/catalogs/books/verified.json').readAsStringSync(),
              )
              as List;
      final source = BookSource.fromJson(
        rows.cast<Map>().singleWhere((r) => r['name'] == '影书小说'),
      );
      final book = Book(
        source.id,
        BookKind.text,
        '夜无疆',
        '辰东',
        source.endpoint.resolve('/106_106109/'),
      );
      final root = await Directory.systemTemp.createTemp('yingsx-catalog-');
      final services = HttpOverrides.runZoned(() {
        final service = AppServices.scoped(root, AppDatabase.memory());
        service.books.client;
        return service;
      }, createHttpClient: _RealHttp().createHttpClient);
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      await services.supervision.load();
      await services.settings.load();
      final books = services.books;
      final token = CancellationToken();
      final client = books.client;
      final first = await client.fetch(
        source,
        source.endpoint.resolve('/106_106109_1/'),
        token,
      );
      final original = BookChapter(
        '第1章 永夜',
        source.endpoint.resolve('/106_106109/39608097.html'),
      );
      await books.store.saveBook(
        book,
        chapters: [original],
        last: original,
        position: .5,
      );
      final catalog = await books.chapters(book, token);
      final stored = (await books.store.entry(book))!;
      expect(stored.chapters.length, catalog.length);
      expect(stored.last, original.id);
      expect(stored.position, .5);
      expect(catalog.length, greaterThan(800));
      expect(catalog.first.title, startsWith('第1章'));
      expect(catalog.map((c) => c.id).toSet(), hasLength(catalog.length));
      final pages = RegExp(
        r'href="/106_106109_(\d+)/"',
      ).allMatches(first.text).map((m) => int.parse(m[1]!)).toList()..sort();
      final last = await client.fetch(
        source,
        source.endpoint.resolve('/106_106109_${pages.last}/'),
        token,
      );
      expect(last.text, contains(catalog.last.uri.path));
      debugPrint(
        'YINGSX_CATALOG pages=${pages.last} chapters=${catalog.length}',
      );
    },
    skip: !const bool.fromEnvironment('RUN_YINGSX_CATALOG'),
  );
}

final class _RealHttp extends HttpOverrides {}
