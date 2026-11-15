import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/known_untrusted_book_rules.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reviewed executable fragments remain blocked when moved', () async {
    final records = await _records();
    final old = parseBookSourceRecord(records[3836]);
    final fragment = old.legado!.rules['content']!;
    for (final moved in [
      _variant(old, rules: {'searchList': fragment, 'content': 'p@text'}),
      _variant(old, rules: {'infoInit': fragment, 'content': 'p@text'}),
      _variant(old, search: fragment, rules: {'content': 'p@text'}),
      _variant(old, library: fragment, rules: {'content': 'p@text'}),
      _variant(
        old,
        explore: [
          {'title': '分类', 'url': fragment},
        ],
        rules: {'content': 'p@text'},
      ),
    ]) {
      expect(moved.id, old.id);
      expect(knownUntrustedBookRule(moved), isTrue);
    }
  });

  test(
    'reviewed comment needs its caller, even after moving that caller',
    () async {
      final records = await _records();
      final old = parseBookSourceRecord(records[12]);
      final caller = old.legado!.rules['searchList']!;
      final moved = _variant(
        old,
        rules: {'chapters': caller, 'content': 'p@text'},
      );
      expect(knownUntrustedBookRule(moved), isTrue);
      final noCaller = _variant(old, rules: {'content': 'p@text'});
      expect(knownUntrustedBookRule(noCaller), isFalse);
      final noComment = BookSource.fromJson({
        ...moved.toJson(),
        'legado': {...moved.legado!.toJson(), 'comment': '普通说明'},
      });
      expect(knownUntrustedBookRule(noComment), isFalse);
    },
  );

  test(
    'changed variants of repaired sources cannot revive old eval rules',
    () async {
      final records = await _records();
      final yuque = parseBookSourceRecord(records[4083]);
      expect(knownUntrustedBookRule(yuque), isFalse);
      final yuqueRaw = Map.of(records[4083] as Map);
      yuqueRaw['exploreUrl'] = (yuqueRaw['exploreUrl'] as String).replaceFirst(
        '📜哈哈哈的书单',
        '修改后的分类',
      );
      final unrepairedYuque = parseBookSourceRecord(yuqueRaw);
      expect(unrepairedYuque.id, yuque.id);
      expect(knownUntrustedBookRule(unrepairedYuque), isTrue);
      final withoutYuqueCaller = _variant(
        unrepairedYuque,
        rules: {'content': 'p@text'},
      );
      expect(knownUntrustedBookRule(withoutYuqueCaller), isFalse);

      for (final index in [3462, 4136]) {
        final fixed = parseBookSourceRecord(records[index]);
        expect(knownUntrustedBookRule(fixed), isFalse);
        final raw = Map.of(records[index] as Map);
        final searchRules = Map.of(raw['ruleSearch'] as Map);
        searchRules['bookList'] = r'$.data';
        raw['ruleSearch'] = searchRules;
        final unrepaired = parseBookSourceRecord(raw);
        expect(unrepaired.id, fixed.id);
        expect(knownUntrustedBookRule(unrepaired), isTrue, reason: '$index');
      }
    },
  );

  test('a dangerous comment requires its own page-reading caller', () async {
    final records = await _records();
    final source = parseBookSourceRecord(records[1030]);
    expect(knownUntrustedBookRule(source), isTrue);
    final searchOnly = _variant(source, rules: {'content': 'p@text'});
    expect(knownUntrustedBookRule(searchOnly), isFalse);
  });

  test('moving a dangerous rule cannot pass manual recovery', () async {
    final records = await _records();
    final old = parseBookSourceRecord(records[3836]);
    final moved = _variant(
      old,
      rules: {'searchList': old.legado!.rules['content']!, 'content': 'p@text'},
    );
    final root = await Directory.systemTemp.createTemp('moved-book-rule-');
    final services = AppServices.scoped(root, AppDatabase.memory());
    addTearDown(() async {
      await services.close();
      await root.delete(recursive: true);
    });
    await services.settings.load();
    await services.supervision.load();
    await services.books.store.write('books_source:${old.id}', {
      'source': old.toJson(),
      'enabled': true,
    });
    await services.books.refreshSourceRisks();
    final changes = await services.books.importSources([moved]);
    expect(changes.updated, 0);
    expect(changes.skipped, 1);
    final saved = (await services.books.store.source(null, old.id))!;
    expect(knownUntrustedBookRule(saved.source), isTrue);
  });

  test(
    'same ID at a different host cannot validate old cached books',
    () async {
      final records = await _records();
      final old = parseBookSourceRecord(records[3836]);
      final cleaned = _variant(
        old,
        rules: {'searchList': '.book', 'content': 'p@text'},
      );
      final alternate = BookSource.fromJson({
        ...cleaned.toJson(),
        'url': cleaned.endpoint.replace(host: 'haipu-xs.com').toString(),
      });
      expect(alternate.id, old.id);
      expect(alternate.endpoint.host, isNot(old.endpoint.host));

      final root = await Directory.systemTemp.createTemp('book-history-host-');
      final services = AppServices.scoped(root, AppDatabase.memory());
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      await services.settings.load();
      await services.supervision.load();
      final book = Book(
        old.id,
        BookKind.text,
        '旧书',
        '',
        old.endpoint.resolve('/1'),
      );
      final chapter = BookChapter('第一章', old.endpoint.resolve('/1/1'));
      await services.books.store.write('books_source:${alternate.id}', {
        'source': alternate.toJson(),
        'enabled': false,
      });
      await services.books.store.saveText(book, chapter, '原有离线正文');
      await services.books.refreshSourceRisks();
      expect(services.books.sourceAllowed(alternate), isTrue);
      expect(services.books.bookAllowed(book), isFalse);
      expect(await services.books.store.text(book, chapter), '原有离线正文');
    },
  );
}

BookSource _variant(
  BookSource source, {
  required Map<String, String> rules,
  String? search,
  String? library,
  List<Map<String, String>>? explore,
}) => BookSource.fromJson({
  ...source.toJson(),
  'legado': {
    ...source.legado!.toJson(),
    'rules': rules,
    'search': ?search,
    'library': ?library,
    'explore': ?explore,
  },
});

Future<List> _records() async {
  final archive = await File(
    'assets/catalogs/books/legado/catalog.json.bz2',
  ).readAsBytes();
  return (jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive)))
          as Map)['records']
      as List;
}
