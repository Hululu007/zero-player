import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:zero_player/core/diagnostics/performance_counters.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/catalog/domain/catalog_item.dart';
import 'package:zero_player/features/library/data/history_repository.dart';
import 'package:zero_player/features/music/data/music_library.dart';
import 'package:zero_player/features/playback/domain/player_engine.dart';
import '../../test_support/music_library_workload.dart';

const _state = PlaybackSnapshot(
  position: Duration(seconds: 12),
  duration: Duration(minutes: 4),
);

void main() {
  for (final writer in [
    'video',
    'reading',
    'raw',
    'batch',
    'atomic',
    'trigger',
    'external',
  ]) {
    for (final enabled in [false, true]) {
      test('$writer mixed music workload, counters $enabled', () async {
        final root = await Directory.systemTemp.createTemp('music-mixed-');
        final file = File('${root.path}/test.sqlite');
        final db = AppDatabase(file);
        final library = MusicLibrary(db);
        final previous = PerformanceCounters.enabled;
        await seedMusicWorkload(db);
        await library.load();
        final external = writer == 'external' ? sqlite3.open(file.path) : null;
        addTearDown(() async {
          PerformanceCounters.enabled = previous;
          PerformanceCounters.reset();
          external?.close();
          await library.close();
          await db.close();
          await root.delete(recursive: true);
        });
        if (writer == 'trigger') {
          await db.customStatement(
            '''CREATE TRIGGER mixed AFTER INSERT ON app_meta
            WHEN NEW.key GLOB 'music_history:*' BEGIN
            INSERT OR REPLACE INTO app_meta VALUES('music_mode','"repeatOne"');
            END''',
          );
        }
        PerformanceCounters.enabled = enabled;
        PerformanceCounters.reset();
        for (var i = 0; i < 20; i++) {
          await _interleave(db, writer, i, external);
          await library.record(workloadTrack(0), _state);
        }
        final counts = PerformanceCounters.snapshot();
        expect(library.playlists, hasLength(20));
        expect(library.playlists.first.tracks, hasLength(100));
        expect(library.history, hasLength(200));
        expect(library.history.first.position, _state.position);
        final changesMode = !{'video', 'reading'}.contains(writer);
        expect(
          library.mode,
          changesMode ? MusicPlayMode.repeatOne : MusicPlayMode.shuffle,
        );
        if (enabled) {
          expect(counts['music.read.fallback'], 20);
          expect(counts['music.read.all'], 20);
          expect(counts['music.decode.playlist_tracks'], 40000);
          stdout.writeln(
            jsonEncode({
              'scenario': 'music-20x100-200-20ticks-mixed-$writer',
              'counts': counts,
            }),
          );
        } else {
          expect(counts, isEmpty);
        }
        await _verifyOtherData(db, writer);
        await library.reload();
        expect(library.history.first.position, _state.position);
      });
    }
  }
}

Future<void> _interleave(
  AppDatabase db,
  String writer,
  int i,
  Database? external,
) async {
  const sql = 'INSERT OR REPLACE INTO app_meta VALUES(?,?)';
  const args = ['music_mode', '"repeatOne"'];
  switch (writer) {
    case 'video':
      final episode = Episode('第1集', Uri.parse('https://media.test/a.mp4'));
      final line = PlayLine('线路', [episode]);
      await HistoryRepository(db).save(
        const CatalogItem(sourceId: 'fixture', id: 'video', title: '视频'),
        line,
        episode,
        Duration(seconds: i),
        const Duration(minutes: 2),
      );
    case 'reading':
      final book = _book();
      final chapter = BookChapter('第一章', Uri.parse('https://book.test/a/1'));
      final store = BookStore(db);
      await store.saveReadingPosition(book, chapter, i / 20, i);
      await store.cacheReading(book, chapter, '正文$i');
    case 'raw':
      await db.customStatement(sql, args);
    case 'batch':
      await db.batch((batch) => batch.customStatement(sql, args));
    case 'atomic':
      await db.atomic(() => db.customStatement(sql, args));
    case 'external':
      external!.execute(sql, args);
    case 'trigger':
      break;
  }
}

Future<void> _verifyOtherData(AppDatabase db, String writer) async {
  if (writer == 'video') {
    final history = (await HistoryRepository(db).recentWorks()).single;
    expect(history.position, const Duration(seconds: 19));
    expect(history.title, '视频');
  } else if (writer == 'reading') {
    final book = _book();
    final chapter = BookChapter('第一章', Uri.parse('https://book.test/a/1'));
    expect(await BookStore(db).readingCache(book, chapter), '正文19');
    final shelf = await BookStore(db).read('books_shelf:${book.id}') as Map;
    expect(shelf['position'], .95);
    expect(shelf['textOffset'], 19);
  }
}

Book _book() => Book(
  'fixture',
  BookKind.text,
  '文字',
  '作者',
  Uri.parse('https://book.test/a'),
);
