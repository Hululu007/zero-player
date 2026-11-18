import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/catalog/domain/catalog_item.dart';
import 'package:zero_player/features/downloads/application/download_scheduler.dart';
import 'package:zero_player/features/downloads/domain/download_task.dart';
import '../../test_support/http_test_server.dart';

void main() {
  _committedRemovalRecovery();
  test(
    'failed task transaction preserves its complete output and pins',
    () async {
      final f = await _Fixture.create();
      final id = await f.createTask();
      final task = (await f.services.downloads.find(id))!;
      final file = await File(
        '${task.directory}/video.mp4',
      ).writeAsBytes([1, 2]);
      await f.services.downloads.complete(id, 'video.mp4');
      final key = 'a' * 64;
      await f.services.store.write(
        key,
        Stream.value([1]),
        statusCode: 200,
        headers: {},
      );
      await f.services.store.pin(id, key);
      await f.services.db.customStatement(
        "CREATE TRIGGER reject_task_delete BEFORE DELETE ON downloads BEGIN SELECT RAISE(ABORT,'fixture'); END",
      );
      final scheduler = DownloadScheduler(
        f.services.downloads,
        f.services.fetcher,
        f.services.http,
        f.services.offline,
        f.services.settings,
        validateMp4: (_, _) async {},
      );
      addTearDown(scheduler.close);
      await expectLater(scheduler.remove(id), throwsA(isA<Exception>()));
      expect(await file.readAsBytes(), [1, 2]);
      expect(
        (await f.services.downloads.find(id))!.status,
        DownloadStatus.complete,
      );
      expect(await f.services.store.pinnedResources(id), {key: 1});
    },
  );
  test(
    'resume repairs a complete record whose local output disappeared',
    () async {
      final f = await _Fixture.create();
      final id = await f.createTask();
      await f.services.downloads.complete(id, 'video.mp4');
      final scheduler = DownloadScheduler(
        f.services.downloads,
        f.services.fetcher,
        f.services.http,
        f.services.offline,
        f.services.settings,
        validateMp4: (_, _) async {},
      );
      addTearDown(scheduler.close);
      final done = f.services.downloads.changes
          .asyncMap((_) => f.services.downloads.find(id))
          .firstWhere((task) => task?.status == DownloadStatus.complete);
      await scheduler.resume(id);
      final completed = (await done.timeout(const Duration(seconds: 5)))!;
      expect(
        await File(
          '${completed.directory}/${completed.localPath}',
        ).readAsBytes(),
        [1, 2, 3, 4],
      );
    },
  );
  test(
    'locked task deletion journals cleanup and releases its pins',
    _lockedRemoval,
    skip: !Platform.isWindows,
  );
  test(
    'restart leaves queued work schedulable and pauses only interrupted transfers',
    _recoverQueue,
  );
  test(
    'resume queues behind an unfinished pause and completes the task',
    _quickResume,
  );
  test(
    'deferred cleanup preserves current task paths and retries orphan paths',
    _cleanup,
  );
  test(
    'download progress does not notify source or settings observers',
    _scopedChanges,
  );
}

void _committedRemovalRecovery() {
  test(
    'startup releases pins when removal committed before process interruption',
    () async {
      final fixture = await _Fixture.create();
      final id = await fixture.createTask();
      final key = 'e' * 64;
      final store = fixture.services.store;
      await store.write(key, Stream.value([1]), statusCode: 200, headers: {});
      await store.pin(id, key);
      await fixture.services.downloads.remove(id);
      // Simulate process interruption before scheduler unpin/directory cleanup.
      expect(await store.pinnedResources(id), {key: 1});
      final scheduler = DownloadScheduler(
        fixture.services.downloads,
        fixture.services.fetcher,
        fixture.services.http,
        fixture.services.offline,
        fixture.services.settings,
        validateMp4: (_, _) async {},
      );
      addTearDown(scheduler.close);
      await scheduler.initialize();
      expect(await store.pinnedResources(id), isEmpty);
      expect(
        await fixture.services.db.rows(
          "SELECT key FROM app_meta WHERE key GLOB 'download_unpin:*'",
        ),
        isEmpty,
      );
    },
  );
}

Future<void> _lockedRemoval() async {
  final fixture = await _Fixture.create();
  final repository = fixture.services.downloads;
  final id = await fixture.createTask();
  final directory = (await repository.find(id))!.directory;
  final file = await File('$directory/locked.part').writeAsString('pending');
  final store = fixture.services.store;
  final key = 'd' * 64;
  await store.write(key, Stream.value([1, 2]), statusCode: 200, headers: {});
  await store.pin(id, key);
  final process = await Process.start(
    'powershell.exe',
    [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r"$lockedFile = [System.IO.File]::Open([Environment]::GetEnvironmentVariable('ZERO_PLAYER_TEST_LOCK'), 'Open', 'Read', 'None'); [Console]::WriteLine('READY'); [Console]::In.ReadLine() | Out-Null; $lockedFile.Dispose()",
    ],
    environment: {'ZERO_PLAYER_TEST_LOCK': file.path},
  );
  try {
    expect(
      await utf8.decoder
          .bind(process.stdout)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 10)),
      'READY',
    );
    final scheduler = DownloadScheduler(
      repository,
      fixture.services.fetcher,
      fixture.services.http,
      fixture.services.offline,
      fixture.services.settings,
      validateMp4: (_, _) async {},
    );
    try {
      await scheduler.remove(id);
    } finally {
      await scheduler.close();
    }
    expect(await repository.find(id), isNull);
    expect(await store.pinnedResources(id), isEmpty);
    expect(await Directory(directory).exists(), isTrue);
    expect(
      (await repository.db.rows(
        "SELECT value FROM app_meta WHERE key GLOB 'download_cleanup:*'",
      )).map((row) => row['value']),
      contains(directory),
    );
  } finally {
    process.kill();
    await process.exitCode.timeout(const Duration(seconds: 10));
  }
  await repository.cleanupPending();
  expect(await Directory(directory).exists(), isFalse);
}

Future<void> _recoverQueue() async {
  final fixture = await _Fixture.create();
  final repository = fixture.services.downloads;
  final queued = await fixture.createTask();
  final running = await fixture.createTask();
  await repository.status(running, DownloadStatus.running);
  await repository.recover();
  expect((await repository.find(queued))!.status, DownloadStatus.queued);
  expect((await repository.find(running))!.status, DownloadStatus.paused);
}

Future<void> _quickResume() async {
  final fixture = await _Fixture.create();
  final entered = Completer<void>();
  final release = Completer<void>();
  var attempts = 0;
  final scheduler = DownloadScheduler(
    fixture.services.downloads,
    fixture.services.fetcher,
    fixture.services.http,
    fixture.services.offline,
    fixture.services.settings,
    validateMp4: (_, _) async {},
    resolve: (task, token) async {
      if (attempts++ == 0) {
        entered.complete();
        await release.future;
      }
      return task;
    },
  );
  addTearDown(scheduler.close);
  final id = await fixture.createTask();
  final complete = fixture.services.downloads.changes
      .asyncMap((_) => fixture.services.downloads.find(id))
      .firstWhere((task) => task?.status == DownloadStatus.complete)
      .timeout(const Duration(seconds: 5));
  scheduler.kick();
  await entered.future;
  final pause = scheduler.pause(id);
  final resume = scheduler.resume(id);
  release.complete();
  await Future.wait([pause, resume]);
  expect((await complete)!.status, DownloadStatus.complete);
  expect(attempts, 2);
}

Future<void> _cleanup() async {
  final fixture = await _Fixture.create();
  final repository = fixture.services.downloads;
  final id = await fixture.createTask();
  final current = (await repository.find(id))!.directory;
  final orphan = Directory('${repository.root.path}/old-attempt');
  await orphan.create(recursive: true);
  await File('${orphan.path}/part').writeAsString('unused');
  await repository.deferCleanup(current);
  await repository.deferCleanup(orphan.path);
  await repository.cleanupPending();
  expect(await Directory(current).exists(), isTrue);
  expect(await orphan.exists(), isFalse);
  expect(
    () => repository.deferCleanup(fixture.directory.parent.path),
    throwsStateError,
  );
}

Future<void> _scopedChanges() async {
  final fixture = await _Fixture.create();
  var sourceEvents = 0, downloadEvents = 0;
  final sources = fixture.services.sources.changes.listen(
    (_) => sourceEvents++,
  );
  final downloads = fixture.services.downloads.changes.listen(
    (_) => downloadEvents++,
  );
  addTearDown(sources.cancel);
  addTearDown(downloads.cancel);
  await fixture.services.settings.update({'theme': 'dark'});
  final id = await fixture.createTask();
  await fixture.services.downloads.progress(id, 1, 10, 100);
  await pumpEventQueue();
  expect(sourceEvents, 0);
  expect(downloadEvents, 2);
  await fixture.services.db.atomic(() async {});
  await pumpEventQueue();
  expect(
    sourceEvents,
    1,
    reason: 'global restores still refresh every observer',
  );
}

final class _Fixture {
  _Fixture(this.directory, this.services, this.server);
  final Directory directory;
  final AppServices services;
  final HttpTestServer server;
  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('download-control');
    final services = AppServices.scoped(
      root,
      AppDatabase.memory(),
      allowPrivateNetworks: true,
    );
    await services.settings.load();
    await services.store.initialize();
    final server = await HttpTestServer.start((request) {
      request.response.contentLength = 4;
      request.response.headers.set('content-type', 'video/mp4');
      request.response.add([1, 2, 3, 4]);
    });
    addTearDown(() async {
      await services.close();
      await server.close();
      await root.delete(recursive: true);
    });
    return _Fixture(root, services, server);
  }

  Future<String> createTask() {
    final episode = Episode('1', server.baseUri.resolve('video.mp4'));
    final line = PlayLine('main', [episode]);
    final item = CatalogItem(
      sourceId: 'test',
      id: '1',
      title: 'test',
      lines: [line],
    );
    return services.downloads.create(item, line, episode, {});
  }
}
