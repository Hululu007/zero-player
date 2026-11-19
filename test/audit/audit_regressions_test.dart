import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/document_client.dart';
import 'package:zero_player/core/network/header_policy.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/application/audiobook_controller.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/book_shelf_view.dart';
import 'package:zero_player/features/books/data/book_resource_limits.dart';
import 'package:zero_player/features/downloads/application/mp4_download.dart';
import 'package:zero_player/features/live/domain/live_channel.dart';
import 'package:zero_player/features/music/application/music_controller.dart';
import 'package:zero_player/features/music/application/music_downloads.dart';
import 'package:zero_player/features/music/data/music_repository.dart';
import 'package:zero_player/features/music/data/myfreemp3_client.dart';
import 'package:zero_player/features/music/domain/music_track.dart';
import 'package:zero_player/features/radio/application/radio_controller.dart';
import 'package:zero_player/media/cache/segment_fetcher.dart';
import 'package:zero_player/media/cache/segment_store.dart';
import 'package:zero_player/media/gateway/offline_server.dart';
import 'package:zero_player/media/hls/hls_manifest.dart';
import 'package:zero_player/media/hls/offline_rewriter.dart';

import '../../test_support/book_fixture_source.dart';
import '../../test_support/fake_player_engine.dart';
import '../../test_support/http_test_server.dart';
import '../../test_support/local_book_fixtures.dart';

// Regression contracts promoted from the confirmed 2026-11-19 audit.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  _aud01();
  _aud02();
  _aud03();
  _aud04();
  _aud05();
  _aud06();
  _aud07();
  _aud08();
  _aud09();
}

void _aud01() {
  test('AUD-01 HLS preserves AUDIO and SUBTITLES sharing group id', () {
    final master = HlsManifest.parse('''#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="main",NAME="Audio",DEFAULT=YES,URI="audio.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="main",NAME="Text",DEFAULT=YES,URI="sub.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=500000,AUDIO="main",SUBTITLES="main"
video.m3u8
''', Uri.parse('https://example.com/master.m3u8'));
    final selected = selectOfflineVariant(master);
    expect(
      selected.lines.where((s) => s.startsWith('#EXT-X-MEDIA:')),
      hasLength(2),
    );
  });
}

void _aud02() {
  test('AUD-02 HLS rejects a mismatched Content-Range', () async {
    final root = await Directory.systemTemp.createTemp('audit-range-');
    final http = MediaHttpClient(allowPrivateNetworks: true);
    final server = await HttpTestServer.start((request) {
      expect(request.headers.value('range'), 'bytes=8-11');
      request.response.statusCode = 206;
      request.response.headers.set('content-range', 'bytes 0-3/16');
      request.response.contentLength = 4;
      request.response.add([0, 1, 2, 3]);
    });
    addTearDown(() async {
      http.close();
      await server.close();
      await root.delete(recursive: true);
    });
    final store = SegmentStore(root);
    await store.initialize();
    final future = SegmentFetcher(store, http).fetch(
      server.baseUri.resolve('segment.ts'),
      HeaderPolicy({server.baseUri: {}}),
      range: 'bytes=8-11',
    );
    // Release even when the defective implementation incorrectly succeeds.
    final checked = future.then((lease) {
      lease.release();
      return lease;
    });
    await expectLater(checked, throwsA(isA<HttpException>()));
    expect(server.calls['/segment.ts'], 1);
  });
}

void _aud03() {
  test(
    'AUD-03 comic reuse excludes an address index with missing image data',
    () async {
      final root = await Directory.systemTemp.createTemp('audit-comic-');
      final services = AppServices.scoped(root, AppDatabase.memory());
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      await services.settings.load();
      await services.supervision.load();
      final source = bookFixtureSource(
        'comic-audit.test',
        kind: BookKind.comic,
      );
      await services.books.importSources([source]);
      final book = Book(
        source.id,
        BookKind.comic,
        '漫画',
        '',
        source.endpoint.resolve('/book'),
      );
      final chapter = BookChapter('第一章', source.endpoint.resolve('/chapter'));
      await services.books.store.db.write(
        'INSERT OR REPLACE INTO app_meta VALUES(?,?)',
        [
          'books_image_offline:${book.id}:${chapter.id}',
          jsonEncode(['https://comic-audit.test/1.png']),
        ],
      );
      expect(await services.books.store.offlineImages(book, chapter), isNull);
      expect(
        await services.books.reusableDownloads(book, [
          chapter,
        ], CancellationToken()),
        isEmpty,
      );
    },
  );
}

void _aud04() {
  for (final resume in [true, false]) {
    _queuedAudiobook(resume);
  }
}

void _queuedAudiobook(bool resume) {
  test('AUD-04 queued audiobook preserves resume=$resume', () async {
    final root = await Directory.systemTemp.createTemp('audit-audio-');
    final services = AppServices.scoped(root, AppDatabase.memory());
    addTearDown(() async {
      await services.close();
      await root.delete(recursive: true);
    });
    await services.settings.load();
    await services.supervision.load();
    final source = bookFixtureSource('audio-audit.test', kind: BookKind.audio);
    await services.books.importSources([source]);
    final a = Book(
      source.id,
      BookKind.audio,
      'A',
      '',
      source.endpoint.resolve('/a'),
    );
    final b = Book(
      source.id,
      BookKind.audio,
      'B',
      '',
      source.endpoint.resolve('/b'),
    );
    final ca = BookChapter('A1', source.endpoint.resolve('/a1'));
    final cb = BookChapter('B1', source.endpoint.resolve('/b1'));
    await cacheAudio(services, a, ca);
    await cacheAudio(services, b, cb);
    await services.books.store.saveBook(
      b,
      chapters: [cb],
      last: cb,
      position: 10000,
    );
    final entered = Completer<void>(), release = Completer<void>();
    var opens = 0;
    final engine = FakePlayerEngine(
      onOpen: () async {
        if (++opens == 1) {
          entered.complete();
          await release.future;
        }
      },
    );
    final player = AudiobookController(
      services.books,
      () => engine,
      () async {},
    );
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await player.close();
    });
    player.start(a, [ca], ca);
    await entered.future.timeout(const Duration(seconds: 5));
    final ready = Completer<void>();
    player.addListener(() {
      if (player.book == b &&
          player.chapter == cb &&
          !player.loading &&
          opens == 2 &&
          !ready.isCompleted) {
        ready.complete();
      }
    });
    player.start(b, [cb], cb, resume: resume);
    release.complete();
    await ready.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(Duration.zero);
    expect(player.error, isNull);
    expect(
      engine.seeks,
      resume ? contains(const Duration(seconds: 10)) : isEmpty,
    );
  });
}

void _aud05() {
  testWidgets('AUD-05 imported EPUB appears under EPUB type filter', (
    tester,
  ) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('audit-epub-'),
    ))!;
    final services = AppServices.scoped(root, AppDatabase.memory());
    addTearDown(
      () => tester.runAsync(() async {
        await services.close();
        await root.delete(recursive: true);
      }),
    );
    final book = (await tester.runAsync(() async {
      await services.settings.load();
      await services.supervision.load();
      final file = File('${root.path}/test.epub');
      await file.writeAsBytes(sampleEpub());
      return services.books.importLocal(file);
    }))!;
    final entry = (await tester.runAsync(
      () => services.books.store.entry(book),
    ))!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookShelfView(
            repository: services.books,
            kind: BookKind.text,
            entries: [entry],
            onOpen: (_) {},
            onFollowChanged: () {},
            onRefresh: () async {},
            onCheckUpdates: (_) async {},
            checking: false,
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    if (find.byTooltip('筛选与追更').evaluate().isNotEmpty) {
      await tester.tap(find.byTooltip('筛选与追更'));
      await tester.pumpAndSettle();
    }
    final types = tester
        .widgetList<DropdownButton<String>>(find.byType(DropdownButton<String>))
        .expand((widget) => widget.items ?? <DropdownMenuItem<String>>[])
        .map((item) => item.value)
        .toList();
    await tester.pumpWidget(const SizedBox());
    expect(types, contains('EPUB'));
  });
}

void _aud06() {
  test(
    'AUD-06 playlist lookup still plays an exact completed local download',
    () async {
      final root = await Directory.systemTemp.createTemp('audit-music-');
      final db = AppDatabase.memory();
      final http = MediaHttpClient(allowPrivateNetworks: true);
      final store = SegmentStore(Directory('${root.path}/segments'));
      final offline = OfflineServer(store);
      final repository = MusicRepository(MyFreeMp3Client(DocumentClient(http)));
      final downloads = MusicDownloads(
        db,
        Directory('${root.path}/downloads'),
        repository,
        http,
        SegmentFetcher(store, http),
        offline,
        validate: (_, _) async {},
      );
      final track = MusicTrack(
        id: 'local',
        title: '已下载',
        artist: '',
        url: Uri.parse('https://audio-audit.test/song.mp3'),
        fetchedAt: DateTime.now(),
      );
      final dir = downloads.directory(track);
      await dir.create(recursive: true);
      final bytes = utf8.encode('local audio for injected player');
      await File('${dir.path}/audio.mp3').writeAsBytes(bytes);
      await File('${dir.path}/integrity.json').writeAsString(
        jsonEncode({
          'bytes': bytes.length,
          'digest': sha256.convert(bytes).toString(),
        }),
      );
      await downloads.load();
      downloads.items = [
        MusicDownload(track, 'complete', bytes.length, entry: 'audio.mp3'),
      ];
      final engine = FakePlayerEngine();
      final player = MusicController(
        repository,
        () => engine,
        downloadsFactory: () => downloads,
      );
      addTearDown(() async {
        await player.close();
        await downloads.close();
        await offline.close();
        http.close();
        await db.close();
        await root.delete(recursive: true);
      });
      final playable = await downloads.open(track);
      expect(playable, isNotNull);
      playable!.close();
      await player.select([track.forPlaylistSearch()], 0);
      expect(player.error, isNull);
      expect(engine.opens, 1);
    },
  );
}

void _aud07() {
  test(
    'AUD-07 simultaneous music and radio resume completes without timeout',
    () async {
      final http = MediaHttpClient();
      final repository = MusicRepository(MyFreeMp3Client(DocumentClient(http)));
      final musicEngine = FakePlayerEngine(), radioEngine = FakePlayerEngine();
      late MusicController music;
      late RadioController radio;
      var simultaneous = false;
      final bothEntered = Completer<void>();
      var entered = 0;
      Future<void> barrier() async {
        if (++entered == 2) bothEntered.complete();
        await bothEntered.future;
      }

      music = MusicController(
        repository,
        () => musicEngine,
        operationTimeout: const Duration(milliseconds: 200),
        beforePlay: () async {
          if (simultaneous) await barrier();
          await radio.pause();
        },
      );
      radio = RadioController(
        () => radioEngine,
        operationTimeout: const Duration(milliseconds: 200),
        beforePlay: () async {
          if (simultaneous) await barrier();
          await music.pause();
        },
      );
      addTearDown(() async {
        await music.close();
        await radio.close();
        http.close();
      });
      await music.select([
        MusicTrack(
          id: 'x',
          title: 'x',
          artist: '',
          url: Uri.parse('https://audio-audit.test/test.mp3'),
          fetchedAt: DateTime.now(),
        ),
      ], 0);
      await radio.select(
        LiveChannel(
          id: 'r',
          listId: 'list',
          name: 'r',
          urls: [Uri.parse('https://radio.test/stream')],
        ),
      );
      await music.pause();
      await radio.pause();
      await Future<void>.delayed(Duration.zero);
      expect(music.error, isNull);
      expect(radio.error, isNull);
      simultaneous = true;
      await Future.wait([music.toggle(), radio.toggle()]);
      expect(music.error, isNull);
      expect(radio.error, isNull);
    },
  );
}

void _aud08() {
  test(
    'AUD-08 changing a resource query must not concatenate unrelated MP4 bodies',
    () async {
      final root = await Directory.systemTemp.createTemp('audit-mp4-');
      final http = MediaHttpClient(allowPrivateNetworks: true);
      final server = await HttpTestServer.start((request) {
        expect(request.uri.query, 'id=B');
        request.response.headers.set('etag', '"v1"');
        if (request.headers.value('range') != null) {
          request.response.statusCode = 206;
          request.response.headers.set('content-range', 'bytes 2-3/4');
          request.response.contentLength = 2;
          request.response.add([7, 8]);
        } else {
          request.response.contentLength = 4;
          request.response.add([5, 6, 7, 8]);
        }
      });
      addTearDown(() async {
        http.close();
        await server.close();
        await root.delete(recursive: true);
      });
      await File('${root.path}/video.mp4.part').writeAsBytes([1, 2]);
      await File('${root.path}/mp4-state.json').writeAsString(
        jsonEncode({
          'uri': server.baseUri.resolve('video?id=A').toString(),
          'etag': '"v1"',
          'total': 4,
        }),
      );
      await downloadMp4(
        uri: server.baseUri.resolve('video?id=B'),
        directory: root,
        http: http,
        policy: HeaderPolicy({server.baseUri: {}}),
        cancellation: CancellationToken(),
        maxBytes: 1024,
        progress: (_, _, _) async {},
        validate: (_, _) async {},
      );
      expect(await File('${root.path}/video.mp4').readAsBytes(), [5, 6, 7, 8]);
    },
  );
}

void _aud09() {
  test(
    'AUD-09 replacing identical private comic images does not increase quota',
    () async {
      final root = await Directory.systemTemp.createTemp('audit-quota-');
      final services = AppServices.scoped(root, AppDatabase.memory());
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      await services.settings.load();
      await services.supervision.load();
      final store = services.books.store;
      final book = Book(
        'local',
        BookKind.comic,
        '漫画',
        '',
        Uri.parse('book:audit'),
      );
      final chapter = BookChapter('1', Uri.parse('book:audit#1'));
      await store.saveBook(book, chapters: [chapter]);
      await store.vault.create('audit-secret-123');
      await store.moveToVault(book);
      final image = Uri.parse('https://comic-audit.test/1.png');
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4z8DwH4QZYAwAR8oH+WdZbrcAAAAASUVORK5CYII=',
      );
      await store.saveOfflineImages(book, chapter, {image: png}, () async {});
      final used =
          (await store.db.rows(
                "SELECT SUM(length(CAST(value AS BLOB))) AS n FROM app_meta WHERE key GLOB 'books_vault_data:*'",
              )).single['n']
              as int;
      // Synthetic capacity filler: its contents are never read or decrypted.
      await store.db.write('INSERT INTO app_meta VALUES(?,zeroblob(?))', [
        'books_vault_data:audit-capacity-filler',
        BookResourceLimits.offlineImageBytes - used - 10,
      ]);
      await store.saveOfflineImages(book, chapter, {image: png}, () async {});
    },
  );
}

Future<void> cacheAudio(
  AppServices services,
  Book book,
  BookChapter chapter,
) async {
  final dir = Directory(
    p.join(services.books.audioFiles.root.path, '${book.id}-${chapter.id}'),
  );
  await dir.create(recursive: true);
  final bytes = utf8.encode('fake audio for injected player');
  await File(p.join(dir.path, 'audio.mp3')).writeAsBytes(bytes);
  await File(p.join(dir.path, 'entry')).writeAsString('audio.mp3');
  await File(p.join(dir.path, 'integrity.json')).writeAsString(
    jsonEncode({
      'bytes': bytes.length,
      'digest': sha256.convert(bytes).toString(),
    }),
  );
}
