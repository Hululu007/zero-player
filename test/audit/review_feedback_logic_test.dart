import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_chapter_policy.dart';
import 'package:zero_player/features/books/data/book_comic_access.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/catalog/domain/catalog_item.dart';
import 'package:zero_player/features/downloads/application/download_scheduler.dart';
import 'package:zero_player/features/downloads/domain/download_task.dart';
import 'package:zero_player/features/playback/application/playback_controller.dart';
import 'package:zero_player/features/playback/data/skip_repository.dart';
import 'package:zero_player/features/settings/data/backup_service.dart';
import 'package:zero_player/features/sources/domain/video_source.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

import '../../test_support/fake_player_engine.dart';
import '../../test_support/http_test_server.dart';

late Directory root;
late AppServices services;
final book = Book(
  'source',
  BookKind.text,
  '书',
  '',
  Uri.parse('https://book.test/b'),
);
final chapter = BookChapter('一', Uri.parse('https://book.test/1'));

void main() {
  setUp(() async {
    root = await Directory.systemTemp.createTemp('review-feedback-');
    services = AppServices.scoped(
      root,
      AppDatabase.memory(),
      allowPrivateNetworks: true,
    );
    await services.settings.load();
    await services.supervision.load();
    await services.store.initialize();
  });
  tearDown(() async {
    await services.close();
    await root.delete(recursive: true);
  });

  _chapterRecoveryTest();
  _comicRecoveryTest();
  _backupClassificationTest();
  _privateQuotaTest();
  _clearPositionTest();
  _downloadPolicyTests();
  _skipToleranceTests();
}

void _chapterRecoveryTest() {
  test(
    'corrupt chapter rules fail as exceptions, retry and allow authorized repair',
    () async {
      final store = services.books.store;
      await store.write('books_chapter_policy:v1', {
        'rules': [42],
        'exceptions': [],
      });
      final policy = BookChapterPolicy(store, services.contentPolicy);
      await expectLater(policy.load(), throwsFormatException);
      await expectLater(policy.saveRules([]), throwsFormatException);
      await services.supervision.saveCredentials(
        await services.supervision.prepareCredentials('test-password'),
      );
      await services.supervision.execute(
        SensitiveOperation.supervision,
        () => policy.saveRules([const BookTextReplacement('旧', '新')]),
        password: 'test-password',
      );
      await policy.load();
      expect(policy.prepare(book, chapter, '旧文字'), '新文字');
      final retry = BookChapterPolicy(store, services.contentPolicy);
      await store.write('books_chapter_policy:v1', {
        'rules': [],
        'exceptions': [42],
      });
      await expectLater(retry.load(), throwsFormatException);
      await store.write('books_chapter_policy:v1', {
        'rules': [],
        'exceptions': [],
      });
      await retry.load();
    },
  );
}

void _comicRecoveryTest() {
  test(
    'malformed comic approvals grant nothing and do not break books',
    () async {
      await services.books.store.write('books_comic_approvals:v1', {
        'bad': 42,
        'other': 'fingerprint',
      });
      final access = BookComicAccess(
        services.books.store,
        services.contentPolicy,
      );
      await access.load();
      expect(access.loaded, isTrue);
      await access.load();
    },
  );
}

void _backupClassificationTest() {
  test(
    'backup cannot downgrade adult classification by ID or normalized endpoint',
    () async {
      final id = await services.sources.saveManual(
        '普通名称',
        Uri.parse('https://source.test/api'),
        classification: 'adult',
      );
      final backup = BackupService(services.db);
      final raw = jsonDecode(await backup.export()) as Map;
      final row = (raw['tables']['sources'] as List).single as Map;
      row['classification'] = 'general';
      await backup.restore(await backup.preview(jsonEncode(raw)));
      expect(
        (await services.db.rows(
          'SELECT classification FROM sources WHERE id=?',
          [id],
        )).single['classification'],
        'adult',
      );
      row['id'] = 'another-id';
      raw['tables']['source_overrides'] = [];
      raw['tables']['source_memberships'] = [];
      await backup.restore(await backup.preview(jsonEncode(raw)));
      expect(
        (await services.db.rows(
          'SELECT classification FROM sources',
        )).single['classification'],
        'adult',
      );
    },
  );
}

void _privateQuotaTest() {
  test(
    'vault text accepts image usage above 96 MiB and rolls back beyond total budget',
    () async {
      final store = services.books.store;
      await store.saveBook(book, chapters: [chapter]);
      await store.vault.create('secret-123');
      await store.moveToVault(book);
      const key = 'books_vault_data:books_image_data:quota-fixture';
      await services.db.write(
        'INSERT INTO app_meta(key,value) VALUES(?,zeroblob(?))',
        [key, 100 * 1024 * 1024],
      );
      await store.saveText(book, chapter, '正文');
      expect(await store.text(book, chapter), '正文');
      await services.db.write(
        'UPDATE app_meta SET value=zeroblob(?) WHERE key=?',
        [193 * 1024 * 1024, key],
      );
      await expectLater(
        store.saveText(book, chapter, '替换后的正文'),
        throwsFormatException,
      );
      expect(await store.text(book, chapter), '正文');
    },
  );
}

void _clearPositionTest() {
  test(
    'clearing source-switch position differs from preserving absent progress',
    () async {
      final store = services.books.store;
      await store.saveBook(
        book,
        last: chapter,
        position: 12345,
        textOffset: 88,
      );
      await store.saveBook(book, favorite: true);
      expect((await store.entry(book))!.position, 12345);
      await store.saveBook(book, last: chapter, clearPosition: true);
      final raw = await store.read('books_shelf:${book.id}') as Map;
      expect(raw.containsKey('position'), isFalse);
      expect(raw.containsKey('textOffset'), isFalse);
      expect((await store.entry(book))!.position, 0);
    },
  );
}

void _downloadPolicyTests() {
  for (final blocked in [false, true]) {
    test(
      'download policy notifications cancel only blocked=$blocked transfers',
      () async {
        final server = await HttpTestServer.start((request) {
          request.response.contentLength = 4;
          request.response.headers.set('content-type', 'video/mp4');
          request.response.add([1, 2, 3, 4]);
        });
        addTearDown(server.close);
        final entered = Completer<void>(), release = Completer<void>();
        final episode = Episode('一', server.baseUri.resolve('video.mp4'));
        final line = PlayLine('线路', [episode]);
        final item = CatalogItem(
          sourceId: 'fixture',
          id: 'movie',
          title: '电影',
          lines: [line],
        );
        final id = await services.downloads.create(item, line, episode, {});
        final scheduler = DownloadScheduler(
          services.downloads,
          services.fetcher,
          services.http,
          services.offline,
          services.settings,
          validateMp4: (_, _) async {},
          resolve: (task, token) async {
            entered.complete();
            await release.future;
            token.check();
            return task;
          },
        );
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          await scheduler.close();
        });
        services.contentPolicy.rememberSource(
          VideoSource(
            id: 'fixture',
            name: '来源',
            endpoint: Uri.parse('https://fixture.test'),
          ),
        );
        scheduler.kick();
        await entered.future.timeout(const Duration(seconds: 5));
        services.contentPolicy.rememberSource(
          VideoSource(
            id: 'fixture',
            name: '更新名称',
            endpoint: Uri.parse('https://fixture.test'),
          ),
        );
        services.contentPolicy.rememberCategories('unrelated', {'1': '成人'});
        if (blocked) {
          services.contentPolicy.rememberSource(
            VideoSource(
              id: 'fixture',
              name: '来源',
              endpoint: Uri.parse('https://fixture.test'),
              classification: 'adult',
            ),
          );
        }
        release.complete();
        await _until(() async {
          final task = (await services.downloads.find(id))!;
          return task.status != DownloadStatus.queued &&
              task.status != DownloadStatus.running;
        });
        final completed = (await services.downloads.find(id))!;
        expect(
          completed.status,
          blocked ? DownloadStatus.paused : DownloadStatus.complete,
          reason: completed.error,
        );
        if (blocked) {
          expect(completed.error, contains('内容策略'));
          expect(server.calls, isEmpty);
        }
      },
    );
  }
}

void _skipToleranceTests() {
  for (final difference in [2000, 2001, 2900]) {
    test(
      'skip duration tolerance uses exact milliseconds: $difference',
      () async {
        await services.gateway.start();
        final engine = FakePlayerEngine();
        final player = PlaybackController(services, engine);
        addTearDown(player.close);
        final episode = Episode('一', Uri.parse('https://media.test/video.mp4'));
        await player.open(
          PlaybackRequest(
            CatalogItem(
              sourceId: 'test',
              id: 'movie',
              title: '电影',
              lines: [
                PlayLine('main', [episode]),
              ],
            ),
          ),
        );
        player.marks = [
          SkipMark(
            id: 'mark',
            start: const Duration(seconds: 5),
            end: const Duration(seconds: 10),
            duration: Duration(milliseconds: 30000 + difference),
            label: '广告',
          ),
        ];
        engine.change(position: const Duration(seconds: 6));
        await pumpEventQueue();
        expect(
          engine.seeks.contains(const Duration(seconds: 10)),
          difference <= 2000,
        );
      },
    );
  }
}

Future<void> _until(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Condition did not complete');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
