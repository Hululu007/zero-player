import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_site_revision.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/domain/book.dart';

BookSource _source(String name) => BookSource.fromJson({
  'name': name,
  'kind': 'text',
  'format': 'feed',
  'url': 'https://revision.example/feed',
  'sourceKey': 'fixture:revision',
});

void main() {
  test('unchanged batches do not notify or change generation', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final revisions = BookSiteRevisions(db);
    final initial = await revisions.ensure({'first', 'second'});
    await Future<void>.delayed(Duration.zero);
    var events = 0;
    final subscription = db.changesFor({'app_meta'}).listen((_) => events++);
    addTearDown(subscription.cancel);
    expect(await revisions.ensure({'first', 'second'}), initial);
    expect(await revisions.ensure({'second', 'first'}), initial);
    await Future<void>.delayed(Duration.zero);
    expect(events, 0);
  });

  test(
    'concurrent initialization converges and corruption makes a fresh token',
    () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final revisions = BookSiteRevisions(db);
      final first = await Future.wait([
        revisions.ensure({'one'}),
        revisions.ensure({'one'}),
      ]);
      expect(first[0]['one'], first[1]['one']);
      final original = first[0]['one'];
      await db.write(BookSiteRevisions.upsertSql, [
        BookSiteRevisions.key('one'),
        '{broken',
      ]);
      final repaired = (await revisions.ensure({'one'}))['one'];
      expect(repaired, isNot(original));
      expect(await revisions.get('one'), repaired);
    },
  );

  test(
    'source writes, deletion and restore rotate in their own transactions',
    () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final store = BookStore(db);
      final original = _source('旧规则');
      await store.writeImported([(source: original, previous: null)]);
      final first = (await store.siteRevisions.get(original.id))!;
      await store.saveSource(original, {'favorite': true, 'health': '正常'});
      expect(await store.siteRevisions.get(original.id), first);
      await store.saveSource(original, {'enabled': true});
      final enabled = (await store.siteRevisions.get(original.id))!;
      expect(enabled, isNot(first));
      await store.saveSource(original, {'enabled': false});
      await store.saveSource(original, {'enabled': true});
      expect(await store.siteRevisions.get(original.id), isNot(enabled));
      final revised = _source('新规则');
      await store.saveSource(original, {'source': revised.toJson()});
      final second = (await store.siteRevisions.get(original.id))!;
      expect(second, isNot(first));
      await store.saveSource(revised, {'source': original.toJson()});
      final third = (await store.siteRevisions.get(original.id))!;
      expect(third, isNot(anyOf(first, second)));
      await store.deleteSource(original);
      final deleted = (await store.siteRevisions.get(original.id))!;
      expect(deleted, isNot(third));
      await store.writeImported([(source: original, previous: null)]);
      expect(await store.siteRevisions.get(original.id), isNot(deleted));
    },
  );

  test('rollback leaves source and revision unchanged', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = BookStore(db);
    final original = _source('原始');
    await store.writeImported([(source: original, previous: null)]);
    final before = await store.siteRevisions.get(original.id);
    await expectLater(
      db.atomic(() async {
        await store.saveSource(original, {'source': _source('不应提交').toJson()});
        throw StateError('rollback');
      }),
      throwsStateError,
    );
    expect(await store.siteRevisions.get(original.id), before);
    expect((await store.source(null, original.id))!.source.name, original.name);
  });

  test(
    'restoring a removed built-in invalidates its prior generation',
    () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final store = BookStore(db);
      final builtin = BookSource.fromJson(
        _source('内置').toJson(),
        builtin: true,
      );
      final initial = (await store.siteRevisions.ensure({
        builtin.id,
      }))[builtin.id]!;
      await store.deleteSource(builtin);
      final deleted = (await store.siteRevisions.get(builtin.id))!;
      expect(deleted, isNot(initial));
      await store.restoreBuiltinSource(builtin);
      final restored = (await store.siteRevisions.get(builtin.id))!;
      expect(restored, isNot(deleted));
      expect(await store.source(builtin, builtin.id), isNotNull);
    },
  );

  test('revision remains stable across database reopen', () async {
    final root = await Directory.systemTemp.createTemp('book-site-revision-');
    final path = File('${root.path}/books.sqlite');
    final createdName = p.basename(root.path);
    final tempParent = p.normalize(
      await Directory.systemTemp.resolveSymbolicLinks(),
    );
    AppDatabase? firstDb;
    AppDatabase? secondDb;
    addTearDown(() async {
      await secondDb?.close();
      await firstDb?.close();
      final resolved = p.normalize(await root.resolveSymbolicLinks());
      if (!createdName.startsWith('book-site-revision-') ||
          !p.equals(p.dirname(resolved), tempParent) ||
          !p.equals(resolved, p.join(tempParent, createdName))) {
        throw StateError(
          'refusing to remove an unexpected temporary directory',
        );
      }
      await root.delete(recursive: true);
    });
    final first = AppDatabase(path);
    firstDb = first;
    final store = BookStore(first);
    final source = _source('持久');
    await store.writeImported([(source: source, previous: null)]);
    final revision = await store.siteRevisions.get(source.id);
    await first.close();
    final second = AppDatabase(path);
    secondDb = second;
    expect(await BookStore(second).siteRevisions.get(source.id), revision);
  });
}
