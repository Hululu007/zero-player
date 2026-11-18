import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/network/document_client.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/data/book_catalog_window.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/catalog/domain/catalog_item.dart';
import 'package:zero_player/features/downloads/data/download_repository.dart';
import 'package:zero_player/features/downloads/domain/download_location.dart';
import 'package:zero_player/features/library/data/history_repository.dart';
import 'package:zero_player/features/supervision/data/content_records.dart';
import 'package:zero_player/features/sources/domain/video_source.dart';
import 'package:zero_player/features/live/data/live_repository.dart';
import 'package:zero_player/features/live/domain/live_channel.dart';
import 'package:zero_player/media/cache/segment_index.dart';
import 'package:zero_player/media/cache/segment_store.dart';

late AppDatabase db;
late BookStore store;
final book = Book(
  'source',
  BookKind.text,
  'Book',
  '',
  Uri.parse('https://fixture.test/book'),
);
BookChapter chapter(int n) =>
    BookChapter('Chapter $n', Uri.parse('https://fixture.test/$n'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    db = AppDatabase.memory();
    store = BookStore(db);
  });
  tearDown(() => db.close());
  _catalogTests();
  _capacityTests();
  _notificationTests();
  _epgTests();
  _cacheTests();
  _switchTests();
}

void _catalogTests() {
  test(
    'rotated 4000-entry catalog retains newest, resume and offline chapters',
    () async {
      await store.saveBook(
        book,
        chapters: List.generate(4000, chapter),
        following: true,
        last: chapter(1),
      );
      await store.saveText(book, chapter(0), 'offline');
      final result = await store.updateShelfChapters(
        book,
        List.generate(4000, (i) => chapter(i + 1)),
      );
      final saved = (await store.entry(book))!;
      expect(result!.omitted, 1);
      expect(saved.chapters.length, 4000);
      expect(
        saved.chapters.map((c) => c.id),
        containsAll([chapter(0).id, chapter(1).id, chapter(4000).id]),
      );
      expect(saved.newChapters, 1);
      expect(await store.text(book, chapter(0)), 'offline');
    },
  );
  test(
    'following save keeps supplied last chapter inside persisted window',
    () async {
      await store.saveBook(book, chapters: [chapter(0)], following: true);
      final fresh = List.generate(4000, (i) => chapter(i + 1));
      await store.saveBook(
        book,
        chapters: fresh,
        last: fresh.last,
        position: 0.5,
      );
      final saved = (await store.entry(book))!;
      expect(saved.chapters.length, 4000);
      expect(saved.last, fresh.last.id);
      expect(saved.chapters.map((c) => c.id), contains(saved.last));
    },
  );
  test(
    'fresh save also retains resume chapter absent from incoming catalog',
    () async {
      await store.saveBook(book, chapters: [chapter(0)], last: chapter(0));
      await store.saveBook(
        book,
        chapters: List.generate(4000, (i) => chapter(i + 1)),
      );
      final saved = (await store.entry(book))!;
      expect(saved.chapters.map((c) => c.id), contains(saved.last));
      expect(saved.chapters.last.id, chapter(4000).id);
    },
  );
}

void _capacityTests() {
  test(
    'required download window overflow is explicit and leaves shelf unchanged',
    () async {
      final old = List.generate(4000, chapter);
      await store.saveBook(
        book,
        chapters: old,
        following: true,
        last: old.first,
      );
      await store.write('books_download:${book.id}', {
        'first': 1,
        'last': 4000,
        'fallback': false,
        'chapterIds': old.map((c) => c.id).toList(),
      });
      final before = await store.read('books_shelf:${book.id}');
      await expectLater(
        store.updateShelfChapters(book, [chapter(4000)]),
        throwsA(isA<BookCatalogCapacityExceeded>()),
      );
      expect(await store.read('books_shelf:${book.id}'), before);
    },
  );
  test(
    'a small feed merge preserves catalog order and metadata updates',
    () async {
      await store.saveBook(
        book,
        chapters: [chapter(0), chapter(1)],
        following: true,
      );
      final renamed = BookChapter('Updated', chapter(1).uri);
      final result = await store.updateShelfChapters(book, [
        renamed,
        chapter(2),
      ]);
      expect(result!.omitted, 0);
      final saved = (await store.entry(book))!;
      expect(saved.chapters.map((c) => c.id), [
        chapter(0).id,
        chapter(1).id,
        chapter(2).id,
      ]);
      expect(saved.chapters[1].title, 'Updated');
      expect(saved.newChapters, 1);
    },
  );
}

void _notificationTests() {
  test(
    'content label commit notifies history and does not broadcast downloads',
    () async {
      var events = 0, unrelated = 0;
      final h = HistoryRepository(db).changes.listen((_) => events++);
      final d = db.changesFor({'downloads'}).listen((_) => unrelated++);
      addTearDown(h.cancel);
      addTearDown(d.cancel);
      await rememberContent(
        db,
        const CatalogItem(sourceId: 's', id: 'i', title: 'new'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(events, 1);
      expect(unrelated, 0);
    },
  );
  test(
    'favorite and watched commits only notify channel preferences',
    () async {
      final http = MediaHttpClient();
      addTearDown(http.close);
      final live = LiveRepository(db, DocumentClient(http));
      var related = 0, unrelated = 0;
      final c = db.changesFor({'channel_preferences'}).listen((_) => related++);
      final d = db.changesFor({'downloads'}).listen((_) => unrelated++);
      addTearDown(c.cancel);
      addTearDown(d.cancel);
      const channel = LiveChannel(
        id: 'c',
        listId: 'l',
        name: 'Channel',
        urls: [],
      );
      await live.favorite(channel, true);
      await live.watched(channel);
      await Future<void>.delayed(Duration.zero);
      expect(related, 2);
      expect(unrelated, 0);
    },
  );
}

void _epgTests() {
  for (final aliases in [
    '{',
    '[]',
    'null',
    '{"bad":42,"good":[null,42,"Channel"]}',
  ]) {
    test('bad EPG alias is isolated: $aliases', () async {
      final http = MediaHttpClient();
      addTearDown(http.close);
      const guide = 'https://fixture.test/epg';
      await db.write(
        'INSERT INTO live_lists(id,name,url,epg_url) VALUES(?,?,?,?)',
        ['l', 'List', 'https://fixture.test/list', guide],
      );
      await db.write('INSERT INTO app_meta VALUES(?,?)', [
        'epg_names:${stableId(guide)}',
        aliases,
      ]);
      await db.write('INSERT INTO epg_programs VALUES(?,?,?,?,?)', [
        guide,
        'good',
        0,
        DateTime.now().millisecondsSinceEpoch + 600000,
        'Programme',
      ]);
      final live = LiveRepository(db, DocumentClient(http));
      final result = await live.schedule(
        const LiveChannel(id: 'c', listId: 'l', name: 'Channel', urls: []),
      );
      expect(result.length, aliases.contains('good') ? 1 : 0);
      await db.write('UPDATE app_meta SET value=? WHERE key=?', [
        jsonEncode({
          'good': ['Channel'],
        }),
        'epg_names:${stableId(guide)}',
      ]);
      expect(
        (await live.schedule(
          const LiveChannel(id: 'c', listId: 'l', name: 'Channel', urls: []),
        )).single.title,
        'Programme',
      );
    });
  }
}

void _cacheTests() {
  test(
    'damaged segment is skipped without deleting file or offline pins',
    () async {
      final root = await Directory.systemTemp.createTemp('cache-recovery-');
      addTearDown(() => root.delete(recursive: true));
      final good = await File('${root.path}/good').writeAsString('ok');
      final bad = await File('${root.path}/bad').writeAsString('bad');
      await db.write('INSERT INTO segment_index VALUES(?,?,?,?,?,?,?)', [
        'bad',
        bad.path,
        3,
        'digest',
        200,
        '{',
        0,
      ]);
      await db.write('INSERT INTO segment_index VALUES(?,?,?,?,?,?,?)', [
        'good',
        good.path,
        2,
        'digest',
        200,
        '{}',
        1,
      ]);
      await db.write('INSERT INTO segment_references VALUES(?,?)', [
        'download',
        'bad',
      ]);
      final cache = SegmentStore(root, metadata: SegmentIndex(db));
      await cache.initialize();
      expect(cache.find('bad'), isNull);
      expect(cache.find('good'), isNotNull);
      expect(await bad.exists(), isTrue);
      expect(await SegmentIndex(db).ownedKeys('download'), {'bad'});
      expect((await db.rows('SELECT * FROM segment_index')).length, 2);
    },
  );
  test('wrong header structure is isolated per row', () async {
    for (final raw in ['[]', '{"a":1}', 'null']) {
      await db.write(
        'INSERT OR REPLACE INTO segment_index VALUES(?,?,?,?,?,?,?)',
        ['bad', 'unused', 1, 'digest', 200, raw, 0],
      );
      expect(await SegmentIndex(db).entries(), isEmpty);
    }
  });
}

void _switchTests() {
  test(
    'switch failure rolls back location, status and content metadata together',
    () async {
      await db.write(
        'INSERT INTO downloads(id,title,url,headers,status,directory,work_json,created_at) VALUES(?,?,?,?,?,?,?,?)',
        [
          'd',
          'Title',
          'https://old.test/1.mp4',
          '{}',
          'paused',
          'old',
          'OLD',
          0,
        ],
      );
      final before = (await db.rows(
        "SELECT * FROM downloads WHERE id='d'",
      )).single;
      await db.customStatement(
        "CREATE TRIGGER fail_metadata BEFORE UPDATE OF work_json ON downloads BEGIN SELECT RAISE(ABORT, 'probe'); END",
      );
      const item = CatalogItem(sourceId: 'new', id: 'new', title: 'New');
      final episode = Episode('1', Uri.parse('https://new.test/1.mp4'));
      final location = DownloadLocation(
        item,
        PlayLine('new', [episode]),
        episode,
        {},
      );
      final repository = DownloadRepository(db, Directory.systemTemp);
      await expectLater(
        repository.switchLocation('d', location, 'new'),
        throwsA(anything),
      );
      expect(
        (await db.rows("SELECT * FROM downloads WHERE id='d'")).single,
        before,
      );
      await db.customStatement('DROP TRIGGER fail_metadata');
      await repository.switchLocation('d', location, 'new');
      final row = (await db.rows(
        "SELECT * FROM downloads WHERE id='d'",
      )).single;
      expect(row['source_id'], 'new');
      expect(row['status'], 'queued');
      expect(jsonDecode(row['work_json'] as String)['title'], 'New');
    },
  );
}
