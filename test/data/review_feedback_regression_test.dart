import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/document_client.dart';
import 'package:zero_player/core/network/header_policy.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_download_coordinator.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_download_plan.dart';
import 'package:zero_player/features/catalog/domain/catalog_item.dart';
import 'package:zero_player/features/live/application/channel_preflight.dart';
import 'package:zero_player/features/live/application/live_probe.dart';
import 'package:zero_player/features/live/data/live_audit_defaults.dart';
import 'package:zero_player/features/live/data/live_health_repository.dart';
import 'package:zero_player/features/live/data/live_repository.dart';
import 'package:zero_player/features/live/domain/live_channel.dart';
import 'package:zero_player/features/live/domain/live_health.dart';
import 'package:zero_player/features/music/application/music_controller.dart';
import 'package:zero_player/features/music/data/music_library.dart';
import 'package:zero_player/features/music/data/music_repository.dart';
import 'package:zero_player/features/music/data/myfreemp3_client.dart';
import 'package:zero_player/features/music/domain/music_track.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';
import 'package:zero_player/media/cache/segment_store.dart';
import 'package:zero_player/media/gateway/media_gateway.dart';
import '../../test_support/book_fixture_source.dart';
import '../../test_support/fake_player_engine.dart';
import '../../test_support/http_test_server.dart';
import '../../test_support/supervision_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final overrides = HttpOverrides.current;
  HttpOverrides.global = null;
  tearDownAll(() => HttpOverrides.global = overrides);
  _gatewayKeys();
  _gatewayCloseFailure();
  _liveCancellation();
  _liveCommittedFailure();
  _historyWindow();
  _musicAdvance();
  _redundantBookPolicy();
  _protectedSettings();
}

void _gatewayKeys() {
  for (final prefix in [
    [0x3c],
    [0x4d, 0x5a],
    [0x7f, 0x65, 0x6c, 0x66],
  ]) {
    test(
      'binary HLS key bypasses media sniffing only at key references: $prefix',
      () async {
        final key = [...prefix, ...List.filled(16 - prefix.length, 1)];
        final root = await Directory.systemTemp.createTemp('gateway-key-');
        final upstream = await HttpTestServer.start((request) {
          if (request.uri.path == '/index.m3u8') {
            request.response.write(
              '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXTINF:2,\nsegment.ts\n#EXT-X-ENDLIST\n',
            );
          } else {
            request.response.add(key);
          }
        });
        final gateway = MediaGateway(
          SegmentStore(root),
          allowPrivateNetworks: true,
        );
        final client = HttpClient();
        addTearDown(() async {
          client.close(force: true);
          await gateway.close();
          await upstream.close();
          await root.delete(recursive: true);
        });
        await gateway.start();
        final session = gateway.createSession(HeaderPolicy({}));
        final manifest = await (await client.getUrl(
          session.register(upstream.baseUri.resolve('index.m3u8')),
        )).close();
        final text = await utf8.decoder.bind(manifest).join();
        final uri = Uri.parse(RegExp('URI="([^"]+)"').firstMatch(text)![1]!);
        final response = await (await client.getUrl(uri)).close();
        expect(response.statusCode, 200);
        expect(await response.expand((chunk) => chunk).toList(), key);
        final segment = Uri.parse(
          text.split('\n').firstWhere((line) => line.startsWith('http')),
        );
        final rejected = await (await client.getUrl(segment)).close();
        expect(rejected.statusCode, 502);
        await rejected.drain<void>();
        // Reusing the same origin URL as a segment must not inherit key status.
        final ordinary = session.register(upstream.baseUri.resolve('key'));
        expect(ordinary, isNot(uri));
        final sameUrl = await (await client.getUrl(ordinary)).close();
        expect(sameUrl.statusCode, 502);
        await sameUrl.drain<void>();
      },
    );
  }
}

void _gatewayCloseFailure() {
  test(
    'gateway frees its socket and all sessions after a cancellation listener fails',
    () async {
      final root = await Directory.systemTemp.createTemp('gateway-close-');
      addTearDown(() => root.delete(recursive: true));
      final gateway = MediaGateway(SegmentStore(root));
      await gateway.start();
      final port = gateway.baseUri.port;
      final first = gateway.createSession(HeaderPolicy({}));
      final second = gateway.createSession(HeaderPolicy({}));
      final resource = first.register(
        Uri.parse('https://media.example/video.ts'),
      );
      first.cancellation.listen(() => throw StateError('fixture cancellation'));
      await expectLater(gateway.close(), throwsStateError);
      expect(second.cancellation.isCancelled, isTrue);
      expect(gateway.isRegisteredResource(resource), isFalse);
      final rebound = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      await rebound.close(force: true);
    },
  );
}

void _liveCancellation() {
  test(
    'cancelling a refresh preserves expired proof for the same request',
    () async {
      final db = AppDatabase.memory();
      final http = MediaHttpClient();
      final health = LiveHealthRepository(db);
      final probe = LiveProbe(http, health);
      addTearDown(() async {
        await probe.close();
        http.close();
        await db.close();
      });
      final channel = LiveChannel(
        id: 'one',
        listId: 'list',
        name: 'One',
        urls: [Uri.parse('https://media.test/a.ts')],
      );
      await health.record(
        channel,
        LiveHealth(
          availability: LiveAvailability.responding,
          checkedAt: DateTime(2020),
          preferredUrl: '${channel.urls.single}',
        ),
      );
      final before = await db.rows('SELECT * FROM app_meta');
      final preflight = ChannelPreflight(
        LiveAuditDefaults(() async => '{"results":[]}'),
        health,
        probe,
      );
      await expectLater(
        preflight.refresh([channel], CancellationToken()..cancel()),
        throwsA(isA<RequestCancelled>()),
      );
      expect(await db.rows('SELECT * FROM app_meta'), before);
      expect(
        LiveHealth.decode(
          before.singleWhere((row) => row['key'] == 'live_state:one')['value'],
          channel.urls,
        ).enabled,
        isTrue,
      );
    },
  );
}

void _liveCommittedFailure() {
  test(
    'post-commit verification failure reports the new list accurately',
    () async {
      final db = AppDatabase.memory();
      final http = MediaHttpClient();
      addTearDown(() async {
        http.close();
        await db.close();
      });
      final live = LiveRepository(
        db,
        DocumentClient(http),
        verifyUpdates: (_, _, {bool force = false}) async =>
            throw StateError('probe unavailable'),
      );
      await live.importText(
        'new',
        Uri.parse('https://list.test/a'),
        'One,https://media.test/a.ts',
      );
      expect((await live.channels()).single.name, 'One');
      expect(
        (await db.rows('SELECT error FROM live_lists')).single['error'],
        contains('频道已更新'),
      );
    },
  );
}

void _historyWindow() {
  test('allowed history is found beyond a fully restricted SQL window', () async {
    final root = await Directory.systemTemp.createTemp('history-window-');
    final services = AppServices.scoped(root, AppDatabase.memory());
    addTearDown(() async {
      await services.close();
      await root.delete(recursive: true);
    });
    await services.settings.load();
    await services.supervision.load();
    final episode = Episode('1', Uri.parse('https://media.test/a.mp4'));
    final line = PlayLine('main', [episode]);
    final item = CatalogItem(
      sourceId: 'test',
      id: 'allowed',
      title: '允许的作品',
      lines: [line],
    );
    await services.history.save(
      item,
      line,
      episode,
      const Duration(seconds: 1),
      const Duration(seconds: 10),
    );
    await services.db.batch((batch) {
      for (var i = 0; i < 501; i++) {
        batch.customStatement(
          'INSERT INTO watch_history(id,source_id,remote_id,title,year,poster,line_name,episode_label,position_ms,duration_ms,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)',
          [
            'blocked$i',
            'test',
            'blocked$i',
            '无分类旧记录',
            '',
            '',
            'main',
            '1',
            1000,
            10000,
            DateTime.now().millisecondsSinceEpoch + 1000 + i,
          ],
        );
      }
    });
    expect((await services.history.recentWorks()).single.remoteId, 'allowed');
    expect((await services.history.all()).single.remoteId, 'allowed');
  });
}

void _musicAdvance() {
  test(
    'pause cancels next-track advancement blocked on history persistence',
    () async {
      final db = AppDatabase.memory();
      final http = MediaHttpClient();
      final library = MusicLibrary(db);
      await library.load();
      final engine = FakePlayerEngine();
      final player = MusicController(
        MusicRepository(MyFreeMp3Client(DocumentClient(http))),
        () => engine,
        libraryFactory: () => library,
      );
      final entered = Completer<void>(), release = Completer<void>();
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await player.close();
        await library.close();
        http.close();
        await db.close();
      });
      MusicTrack track(String id) => MusicTrack(
        id: id,
        title: id,
        artist: 'artist',
        url: Uri.parse('https://media.test/$id.mp3'),
        fetchedAt: DateTime.now(),
      );
      await player.select([track('one'), track('two')], 0);
      await pumpEventQueue();
      final hold = db.transaction(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final advance = player.next();
      await pumpEventQueue();
      await player.pause();
      release.complete();
      await hold;
      await advance;
      expect(player.index, 0);
      expect(engine.snapshot.playing, isFalse);
    },
  );
}

void _redundantBookPolicy() {
  test(
    'redundant policy refresh preserves an allowed in-flight chapter',
    () async {
      final root = await Directory.systemTemp.createTemp('book-refresh-');
      final services = AppServices.scoped(root, AppDatabase.memory());
      final entered = Completer<void>(), release = Completer<void>();
      await services.settings.load();
      await services.supervision.load();
      final source = bookFixtureSource('refresh.test');
      await services.books.importSources([source]);
      await services.books.saveSource(source, {'enabled': true});
      final book = Book(
        source.id,
        BookKind.text,
        '测试',
        '',
        source.endpoint.resolve('/book'),
      );
      final chapter = BookChapter('第一章', source.endpoint.resolve('/chapter'));
      final coordinator = BookDownloadCoordinator(
        services.books,
        downloadChapter: (_, _, token) async {
          entered.complete();
          await release.future;
          token.check();
        },
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await coordinator.close();
        await services.close();
        await root.delete(recursive: true);
      });
      final task = coordinator.start(book, [
        chapter,
      ], const BookDownloadPlan(1, 1, false));
      await entered.future;
      final before = services.books.downloadGuard.lease();
      services.contentPolicy.refresh();
      expect(services.books.downloadGuard.lease(), before);
      expect(task.token.isCancelled, isFalse);
      release.complete();
      await task.done;
      expect(task.status, BookDownloadStatus.completed);
    },
  );
}

void _protectedSettings() {
  test('supervised source checking requires settings authorization', () async {
    final f = SupervisionFixture();
    addTearDown(f.close);
    await f.configure();
    await f.authorized(
      SensitiveOperation.supervision,
      () => f.guard.setEnabled(true),
    );
    await expectLater(
      f.settings.update({'backgroundProbe': false}),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      f.settings.update({'bookSiteAutoCheck': false}),
      throwsA(isA<Exception>()),
    );
    expect(f.settings.value.backgroundProbe, isTrue);
    expect(f.settings.value.bookSiteAutoCheck, isTrue);
    await f.authorized(
      SensitiveOperation.settings,
      () => f.settings.update({'backgroundProbe': false}),
    );
    expect(f.settings.value.backgroundProbe, isFalse);
  });
}
