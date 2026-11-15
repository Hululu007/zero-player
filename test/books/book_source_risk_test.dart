import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_source_risk.dart';

BookSource _source(
  String host,
  String name, {
  String group = '漫画',
  String kind = 'comic',
}) => BookSource.fromJson({
  'name': name,
  'group': group,
  'kind': kind,
  'format': 'html',
  'url': 'https://$host/',
  'search': '/search/{key}',
  'rules': {
    'list': '.book',
    'title': '.title@text',
    'book': 'a@href',
    'chapters': '.chapter',
    'chapterTitle': '@text',
    'chapterUrl': '@href',
    'content': '.content',
  },
});

void main() {
  test('off-site redirect hosts stay quarantined', () {
    for (final host in [
      'www.jpxgyw.cc',
      'www.yeseimg.com',
      'www.kukk.net',
      'www.bdido.com',
    ]) {
      expect(quarantinedComicSource(_source(host, '漫画')), isTrue);
    }
    expect(
      quarantinedComicSource(_source('manga.bilibili.com', '漫画')),
      isFalse,
    );
  });

  test(
    'explicit adult labels and bundled adult-labelled hosts are restricted',
    () {
      for (final source in [
        _source('example.com', '漫画🔞'),
        _source('example.com', '普通漫画', group: '🔞漫画'),
        _source('example.com', '肉漫屋'),
        _source('www.18mh.cc', '普通漫画'),
        _source('www.jpxgyw.cc', '普通漫画'),
        _source('www.lcmhx.asia', '普通漫画'),
      ]) {
        expect(adultComicSource(source), isTrue, reason: source.name);
      }
    },
  );

  test(
    'generic comics and non-comic titles are not classified by this rule',
    () {
      expect(adultComicSource(_source('manga.bilibili.com', '漫画')), isFalse);
      expect(adultComicSource(_source('example.com', '韩漫大全')), isFalse);
      expect(
        adultComicSource(_source('www.18mh.cc', '新闻', kind: 'text')),
        isFalse,
      );
    },
  );

  test('default adult filter hides a persisted adult comic source', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final root = await Directory.systemTemp.createTemp('comic-source-risk-');
    final services = AppServices.scoped(root, AppDatabase.memory());
    addTearDown(() async {
      await services.close();
      await root.delete(recursive: true);
    });
    await services.settings.load();
    await services.supervision.load();
    expect(services.contentPolicy.filterAdult, isTrue);
    final source = _source('www.18mh.cc', '普通漫画');
    expect(services.books.sourceAllowed(source), isFalse);
    expect(
      services.books.bookAllowed(
        Book(
          source.id,
          BookKind.comic,
          '普通作品',
          '',
          Uri.parse('https://www.18mh.cc/comic/1'),
        ),
      ),
      isFalse,
    );
    expect(
      services.books.bookAllowed(
        Book(
          'old-quarantined-source',
          BookKind.comic,
          '普通作品',
          '',
          Uri.parse('https://www.kukk.net/comic/1'),
        ),
      ),
      isFalse,
    );
    expect(
      services.books.sourceAllowed(_source('www.kukk.net', '普通漫画')),
      isFalse,
    );
    await services.books.store.write('books_source:${source.id}', {
      'source': source.toJson(),
      'enabled': true,
    });
    expect(await services.books.sourceEntry(BookKind.comic, source.id), isNull);
    expect(
      (await services.books.sources(
        BookKind.comic,
      )).where((entry) => entry.source.id == source.id),
      isEmpty,
    );
  });
}
