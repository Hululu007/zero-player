import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/persistence/installation_metadata.dart';
import 'package:zero_player/features/books/application/audiobook_controller.dart';
import 'package:zero_player/features/books/data/book_download_coordinator.dart';
import 'package:zero_player/features/books/data/book_download_evidence.dart';
import 'package:zero_player/features/books/data/book_mixed_content.dart';
import 'package:zero_player/features/books/data/books_repository.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_download_plan.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

import '../../test_support/book_fixture_source.dart';
import '../../test_support/fake_player_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _textEvidenceTests();
  _revisionAndConcurrencyTests();
  _audioEvidenceTests();
}

void _textEvidenceTests() {
  test(
    'fallback fetches from B without relabelling an unknown old cache',
    () async {
      final calls = <String>[];
      final f = await _Fixture.create(
        fetch: (source, book, chapter, token) async {
          calls.add(source.id);
          expect(chapter.body, isEmpty);
          return '来自新请求的正文';
        },
      );
      addTearDown(f.close);
      await f.books.store.saveText(f.origin, f.originChapter, '旧的未知来源正文');
      await f.books.store.saveText(f.target, f.targetChapter, '原有目标缓存');
      final cachedChapter = BookChapter(
        f.originChapter.title,
        f.originChapter.uri,
        body: '不可当作新数据的旧正文',
      );
      await f.books.download(
        f.target,
        f.targetChapter,
        CancellationToken(),
        alternatives: [
          (book: f.origin, chapters: [cachedChapter]),
        ],
        tryOriginal: false,
      );
      expect(calls, [f.originSource.id]);
      expect(await f.books.store.text(f.origin, f.originChapter), '旧的未知来源正文');
      expect(await f.books.store.text(f.target, f.targetChapter), '原有目标缓存');
      final saved = (await f.books.store.provenText(
        f.target,
        f.targetChapter,
      ))!;
      expect(saved.body, '来自新请求的正文');
      expect(saved.evidence.target.sourceId, f.targetSource.id);
      expect(saved.evidence.origin.sourceId, f.originSource.id);
      expect(
        await f.books.readText(f.target, f.targetChapter, CancellationToken()),
        saved.body,
      );
      await f.restart();
      expect(
        await f.books.readText(f.target, f.targetChapter, CancellationToken()),
        saved.body,
      );
    },
  );

  test('adult evidence on B blocks A only while filtering is active', () async {
    final f = await _Fixture.create(adultAccess: true);
    addTearDown(f.close);
    await f.services.settings.update({'filterAdult': false});
    await f.downloadFromOrigin();
    await f.books.markSourceRisk(f.originSource, adult: true);
    expect(
      await f.books.readText(f.target, f.targetChapter, CancellationToken()),
      '新正文',
    );
    await f.services.settings.update({'filterAdult': true});
    expect(f.books.bookAllowed(f.target), isTrue);
    await expectLater(
      f.books.readText(f.target, f.targetChapter, CancellationToken()),
      throwsA(isA<ContentBlocked>()),
    );
    await expectLater(
      f.books.offlineText(f.target, f.targetChapter, CancellationToken()),
      throwsA(isA<ContentBlocked>()),
    );
    expect(
      (await f.books.store.provenText(f.target, f.targetChapter))!.body,
      '新正文',
    );
  });

  for (final remove in [false, true]) {
    test(
      'origin ${remove ? 'removal' : 'blacklist'} blocks proven target text',
      () async {
        final f = await _Fixture.create();
        addTearDown(f.close);
        await f.downloadFromOrigin();
        if (remove) {
          await f.books.removeSource(f.originSource);
        } else {
          await f.books.blockSource(f.originSource);
        }
        expect(f.books.bookAllowed(f.target), isTrue);
        await expectLater(
          f.books.offlineText(f.target, f.targetChapter, CancellationToken()),
          throwsA(isA<ContentBlocked>()),
        );
        expect(
          (await f.books.store.provenText(f.target, f.targetChapter))!.body,
          '新正文',
        );
      },
    );
  }

  test('quarantine on B blocks A even with adult filtering disabled', () async {
    final f = await _Fixture.create(adultAccess: true);
    addTearDown(f.close);
    await f.services.settings.update({'filterAdult': false});
    await f.downloadFromOrigin();
    await f.books.markSourceRisk(f.originSource, quarantine: true);
    await expectLater(
      f.books.readText(f.target, f.targetChapter, CancellationToken()),
      throwsA(isA<ContentBlocked>()),
    );
  });

  test('deleting one offline chapter removes all its versions only', () async {
    final f = await _Fixture.create();
    addTearDown(f.close);
    final second = BookChapter(
      '第二章',
      f.targetSource.endpoint.resolve('/second'),
    );
    await f.books.store.saveText(f.target, f.targetChapter, '原有第一章');
    await f.books.store.saveText(f.target, second, '原有第二章');
    await f.books.store.cacheReading(f.target, f.targetChapter, '独立阅读缓存');
    await f.books.download(f.target, f.targetChapter, CancellationToken());
    await f.downloadFromOrigin();
    await f.books.download(f.target, second, CancellationToken());
    final prefix =
        'books_proven_text_record:${f.target.id}:${f.targetChapter.id}:';
    expect(
      await f.services.db.rows('SELECT key FROM app_meta WHERE key GLOB ?', [
        '$prefix*',
      ]),
      hasLength(2),
    );

    await f.books.store.deleteText(f.target, f.targetChapter);
    expect(await f.books.store.text(f.target, f.targetChapter), isNull);
    expect(await f.books.store.provenText(f.target, f.targetChapter), isNull);
    expect(
      await f.services.db.rows('SELECT key FROM app_meta WHERE key GLOB ?', [
        '$prefix*',
      ]),
      isEmpty,
    );
    expect(
      await f.books.store.readingCache(f.target, f.targetChapter),
      '独立阅读缓存',
    );
    expect(await f.books.store.text(f.target, second), '原有第二章');
    expect(
      await f.books.readText(f.target, second, CancellationToken()),
      '新正文',
    );
    expect(await f.books.store.savedText(f.target), {second.id});
  });
}

void _revisionAndConcurrencyTests() {
  test('close drains pending source mutations and rejects new work', () async {
    final f = await _Fixture.create();
    addTearDown(f.close);
    final locked = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final held = f.services.db.atomic(() async {
      locked.complete();
      await release.future;
    });
    await locked.future.timeout(const Duration(seconds: 5));
    final registered = Completer<void>();
    void listener() {
      if (!registered.isCompleted) registered.complete();
    }

    f.books.sourceRiskChanges.addListener(listener);
    final mutation = f.books.saveSource(f.originSource, {'group': '保留分组'});
    await registered.future.timeout(const Duration(seconds: 5));
    f.books.sourceRiskChanges.removeListener(listener);
    final closing = f.books.close();
    expect(identical(closing, f.books.close()), isTrue);
    var closed = false;
    unawaited(closing.then((_) => closed = true));
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    await expectLater(f.books.importSources([]), throwsStateError);
    release.complete();
    await held;
    await mutation;
    await closing.timeout(const Duration(seconds: 5));
    expect(closed, isTrue);
  });

  test(
    'source A→B→A cannot revive old evidence; fresh download keeps it',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      await f.books.store.saveText(f.target, f.targetChapter, '保留旧正文');
      await f.downloadFromOrigin();
      final old = (await f.books.store.provenText(f.target, f.targetChapter))!;
      final changed = BookSource.fromJson({
        ...f.originSource.toJson(),
        'name': '修订后来源',
      });
      await f.books.saveSource(f.originSource, {'source': changed.toJson()});
      await f.books.saveSource(changed, {'source': f.originSource.toJson()});
      await expectLater(
        f.books.readText(f.target, f.targetChapter, CancellationToken()),
        throwsA(isA<ContentBlocked>()),
      );
      expect(
        await f.books.reusableDownloads(f.target, [
          f.targetChapter,
        ], CancellationToken()),
        isEmpty,
      );
      await f.books.download(f.target, f.targetChapter, CancellationToken());
      final revised = (await f.books.store.provenText(
        f.target,
        f.targetChapter,
      ))!;
      expect(revised.evidence.origin.sourceId, f.targetSource.id);
      expect(await f.books.store.text(f.target, f.targetChapter), '保留旧正文');
      final records = await f.services.db.rows(
        "SELECT key FROM app_meta WHERE key GLOB 'books_proven_text_record:${f.target.id}:${f.targetChapter.id}:*'",
      );
      expect(records, hasLength(2));
      expect(old.evidence.origin.sourceId, f.originSource.id);
    },
  );

  test(
    'policy change during commit rolls back proof and preserves legacy data',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      await f.books.store.saveText(f.target, f.targetChapter, '旧正文');
      final evidence = await f.capture();
      final lease = f.books.downloadGuard.lease();
      var calls = 0;
      await expectLater(
        f.books.store.saveProvenText(
          f.target,
          f.targetChapter,
          '不应提交',
          evidence,
          () async {
            await f.books.downloadGuard.validate(evidence, expected: lease);
            if (++calls == 1) f.services.contentPolicy.refresh();
          },
        ),
        throwsA(isA<ContentBlocked>()),
      );
      expect(await f.books.store.provenText(f.target, f.targetChapter), isNull);
      expect(await f.books.store.text(f.target, f.targetChapter), '旧正文');
      expect(
        await f.services.db.rows(
          "SELECT key FROM app_meta WHERE key GLOB 'books_proven_text_record:*'",
        ),
        isEmpty,
      );
    },
  );

  test(
    'three real coordinator workers can capture and publish concurrently',
    () async {
      final allStarted = Completer<void>();
      var started = 0;
      final f = await _Fixture.create(
        fetch: (source, book, chapter, token) async {
          if (++started == 3) allStarted.complete();
          await allStarted.future.timeout(const Duration(seconds: 5));
          token.check();
          return '正文 ${chapter.title}';
        },
      );
      addTearDown(f.close);
      final chapters = List.generate(
        3,
        (index) => BookChapter(
          '第${index + 1}章',
          f.targetSource.endpoint.resolve('/chapter/$index'),
        ),
      );
      final coordinator = BookDownloadCoordinator(f.books);
      addTearDown(coordinator.close);
      final task = coordinator.start(
        f.target,
        chapters,
        const BookDownloadPlan(1, 3, false),
      );
      await task.done.timeout(const Duration(seconds: 10));
      expect(task.status, BookDownloadStatus.completed);
      expect(task.failures, 0);
      expect(task.finished, 3);
      for (final chapter in chapters) {
        expect(
          (await f.books.store.provenText(f.target, chapter))!.body,
          '正文 ${chapter.title}',
        );
      }
    },
  );

  test(
    'policy changes while a source is being fetched prevent publication',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final f = await _Fixture.create(
        fetch: (source, book, chapter, token) async {
          started.complete();
          await release.future;
          token.check();
          return '不应保存';
        },
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await f.close();
      });
      final pending = expectLater(
        f.downloadFromOrigin(),
        throwsA(isA<ContentBlocked>()),
      );
      await started.future.timeout(const Duration(seconds: 5));
      await f.books.markSourceRisk(f.originSource, adult: true);
      release.complete();
      await pending;
      expect(await f.books.store.provenText(f.target, f.targetChapter), isNull);
    },
  );

  test('caller cancellation remains cancellation during download', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final f = await _Fixture.create(
      fetch: (_, _, _, token) async {
        started.complete();
        await release.future;
        token.check();
        return '不应保存';
      },
    );
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await f.close();
    });
    final token = CancellationToken();
    final pending = expectLater(
      f.books.download(f.target, f.targetChapter, token),
      throwsA(isA<RequestCancelled>()),
    );
    await started.future.timeout(const Duration(seconds: 5));
    token.cancel();
    release.complete();
    await pending.timeout(const Duration(seconds: 5));
    expect(await f.books.store.provenText(f.target, f.targetChapter), isNull);
  });

  for (final change in ['filter', 'source']) {
    test('$change ABA invalidates download even after restoration', () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final f = await _Fixture.create(
        adultAccess: true,
        fetch: (_, _, _, token) async {
          started.complete();
          await release.future;
          token.check();
          return '不应保存';
        },
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await f.close();
      });
      final pending = expectLater(
        f.downloadFromOrigin(),
        throwsA(isA<ContentBlocked>()),
      );
      await started.future.timeout(const Duration(seconds: 5));
      if (change == 'filter') {
        await f.services.settings.update({'filterAdult': false});
        await f.services.settings.update({'filterAdult': true});
      } else {
        await f.books.saveSource(f.originSource, {'enabled': false});
        await f.books.saveSource(f.originSource, {'enabled': true});
      }
      release.complete();
      await pending.timeout(const Duration(seconds: 5));
      expect(await f.books.store.provenText(f.target, f.targetChapter), isNull);
    });
  }

  test('a revoked source does not continue to the fallback source', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final visited = <String>[];
    final f = await _Fixture.create(
      fetch: (source, _, _, token) async {
        visited.add(source.id);
        if (!started.isCompleted) started.complete();
        await release.future;
        token.check();
        return '不应保存';
      },
    );
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await f.close();
    });
    final pending = expectLater(
      f.books.download(
        f.target,
        f.targetChapter,
        CancellationToken(),
        alternatives: [
          (book: f.origin, chapters: [f.originChapter]),
        ],
      ),
      throwsA(isA<ContentBlocked>()),
    );
    await started.future.timeout(const Duration(seconds: 5));
    await f.books.markSourceRisk(f.targetSource, adult: true);
    release.complete();
    await pending.timeout(const Duration(seconds: 5));
    expect(visited, [f.targetSource.id]);
    expect(await f.books.store.provenText(f.target, f.targetChapter), isNull);
  });

  test('repository shutdown remains cancellation', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final f = await _Fixture.create(
      fetch: (_, _, _, token) async {
        started.complete();
        await release.future;
        token.check();
        return '不应保存';
      },
    );
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await f.close();
    });
    final pending = expectLater(
      f.downloadFromOrigin(),
      throwsA(isA<RequestCancelled>()),
    );
    await started.future.timeout(const Duration(seconds: 5));
    await f.books.close().timeout(const Duration(seconds: 5));
    release.complete();
    await pending.timeout(const Duration(seconds: 5));
    expect(await f.books.store.provenText(f.target, f.targetChapter), isNull);
  });

  test(
    'mixed layout stays with its proven source and never reuses old A data',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final same = await f.books.downloadGuard.capture(
        f.target,
        f.targetChapter,
        f.target,
        f.targetChapter,
      );
      final image = f.targetSource.endpoint.resolve('/image.png');
      await f.books.store.saveProvenText(
        f.target,
        f.targetChapter,
        '新正文',
        same,
        () => f.books.downloadGuard.validate(same),
        segments: [BookTextSegment('新正文'), BookImageSegment(image)],
      );
      final direct = await f.books.mixedReading(
        f.target,
        f.targetChapter,
        CancellationToken(),
      );
      expect(direct.whereType<BookImageSegment>().single.address, image);
      await f.books.store.cacheMixedReading(f.target, f.targetChapter, [
        const BookTextSegment('旧混排'),
        BookImageSegment(image),
      ]);
      final alternate = await f.capture();
      await f.books.store.saveProvenText(
        f.target,
        f.targetChapter,
        '备用来源正文',
        alternate,
        () => f.books.downloadGuard.validate(alternate),
        segments: [const BookTextSegment('备用正文'), BookImageSegment(image)],
      );
      expect(
        await f.books.mixedReading(
          f.target,
          f.targetChapter,
          CancellationToken(),
        ),
        isEmpty,
      );
    },
  );
}

void _audioEvidenceTests() {
  test(
    'deleting one audio chapter preserves other chapters and their proofs',
    () async {
      final f = await _Fixture.create(kind: BookKind.audio);
      addTearDown(f.close);
      final second = BookChapter(
        '第二章',
        f.targetSource.endpoint.resolve('/second'),
      );
      final firstFile = await f.installProvenAudio();
      final secondFile = await f.installProvenAudio(
        chapter: second,
        suffix: 'second',
      );
      await f.books.removeSavedAudio(f.target, chapter: f.targetChapter);
      expect(await firstFile.exists(), isFalse);
      expect(await secondFile.exists(), isTrue);
      expect(
        await f.books.store.provenAudio(f.target, f.targetChapter),
        isNull,
      );
      expect(await f.books.store.provenAudio(f.target, second), isNotNull);
      final playable = await f.books.openOfflineAudio(
        f.target,
        second,
        CancellationToken(),
      );
      playable.session.close();
    },
  );

  test(
    'origin risk stops active proven audio and preserves its file',
    () async {
      final f = await _Fixture.create(kind: BookKind.audio);
      addTearDown(f.close);
      final file = await f.installProvenAudio();
      final engine = FakePlayerEngine();
      final player = AudiobookController(f.books, () => engine, () async {});
      addTearDown(player.close);
      final playing = Completer<void>();
      void listener() {
        if (!player.loading && player.playing && !playing.isCompleted) {
          playing.complete();
        }
      }

      player.addListener(listener);
      player.start(f.target, [f.targetChapter], f.targetChapter);
      await playing.future.timeout(const Duration(seconds: 5));
      player.removeListener(listener);
      await f.books.markSourceRisk(f.originSource, adult: true);
      expect(player.error, isNotNull);
      expect(engine.snapshot.playing, isFalse);
      await expectLater(
        f.books.openOfflineAudio(
          f.target,
          f.targetChapter,
          CancellationToken(),
        ),
        throwsA(isA<ContentBlocked>()),
      );
      expect(await file.exists(), isTrue);
    },
  );

  test(
    'a changed origin invalidates audio without deleting its old file',
    () async {
      final f = await _Fixture.create(kind: BookKind.audio);
      addTearDown(f.close);
      final file = await f.installProvenAudio();
      final session = await f.books.openOfflineAudio(
        f.target,
        f.targetChapter,
        CancellationToken(),
      );
      session.session.close();
      final changed = BookSource.fromJson({
        ...f.originSource.toJson(),
        'name': '新版本',
      });
      await f.books.saveSource(f.originSource, {'source': changed.toJson()});
      await expectLater(
        f.books.openOfflineAudio(
          f.target,
          f.targetChapter,
          CancellationToken(),
        ),
        throwsA(isA<ContentBlocked>()),
      );
      expect(
        await f.books.reusableDownloads(f.target, [
          f.targetChapter,
        ], CancellationToken()),
        isEmpty,
      );
      expect(await file.exists(), isTrue);
      final replacement = await f.installProvenAudio(
        direct: true,
        suffix: 'replacement',
      );
      final current = (await f.books.store.provenAudio(
        f.target,
        f.targetChapter,
      ))!;
      expect(current.evidence.origin.sourceId, f.targetSource.id);
      expect(await file.exists(), isTrue);
      expect(await replacement.exists(), isTrue);
    },
  );

  for (final remove in [false, true]) {
    test(
      'audio rejects origin ${remove ? 'removal' : 'blacklisting'}',
      () async {
        final f = await _Fixture.create(kind: BookKind.audio);
        addTearDown(f.close);
        final file = await f.installProvenAudio();
        if (remove) {
          await f.books.removeSource(f.originSource);
        } else {
          await f.books.blockSource(f.originSource);
        }
        await expectLater(
          f.books.openOfflineAudio(
            f.target,
            f.targetChapter,
            CancellationToken(),
          ),
          throwsA(isA<ContentBlocked>()),
        );
        expect(await file.exists(), isTrue);
      },
    );
  }

  test('origin restriction during engine open stops the late player', () async {
    final f = await _Fixture.create(kind: BookKind.audio);
    addTearDown(f.close);
    await f.installProvenAudio();
    final started = Completer<void>();
    final release = Completer<void>();
    final engine = FakePlayerEngine(
      onOpen: () async {
        started.complete();
        await release.future;
      },
    );
    final player = AudiobookController(f.books, () => engine, () async {});
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await player.close();
    });
    final stopped = Completer<void>();
    void listener() {
      if (!player.loading && player.error != null && !stopped.isCompleted) {
        stopped.complete();
      }
    }

    player.addListener(listener);
    player.start(f.target, [f.targetChapter], f.targetChapter);
    await started.future.timeout(const Duration(seconds: 5));
    await f.books.blockSource(f.originSource);
    release.complete();
    await stopped.future.timeout(const Duration(seconds: 5));
    player.removeListener(listener);
    expect(engine.snapshot.playing, isFalse);
  });
}

typedef _TextFetch =
    Future<String> Function(
      BookSource source,
      Book book,
      BookChapter chapter,
      CancellationToken token,
    );

final class _Fixture {
  _Fixture(
    this.root,
    this.services,
    this.books,
    this.targetSource,
    this.originSource,
  );
  final Directory root;
  AppServices services;
  BooksRepository books;
  final BookSource targetSource, originSource;
  late final target = Book(
    targetSource.id,
    targetSource.kind,
    '作品',
    '作者',
    targetSource.endpoint.resolve('/book'),
  );
  late final origin = Book(
    originSource.id,
    originSource.kind,
    '作品',
    '作者',
    originSource.endpoint.resolve('/book'),
  );
  late final targetChapter = BookChapter(
    '第一章',
    targetSource.endpoint.resolve('/chapter'),
  );
  late final originChapter = BookChapter(
    '第一章',
    originSource.endpoint.resolve('/chapter'),
  );

  static Future<_Fixture> create({
    BookKind kind = BookKind.text,
    bool adultAccess = false,
    _TextFetch? fetch,
  }) async {
    final root = await Directory.systemTemp.createTemp(
      'book-download-evidence-',
    );
    final services = AppServices.scoped(
      root,
      AppDatabase(File(p.join(root.path, 'db.sqlite'))),
    );
    if (adultAccess) {
      await services.db.write('INSERT OR REPLACE INTO app_meta VALUES(?,?)', [
        installationAccessKey,
        upgradedInstallationAccess,
      ]);
    }
    await services.settings.load();
    await services.supervision.load();
    final books = _repository(services, fetch);
    final target = bookFixtureSource('target.example', kind: kind);
    final origin = bookFixtureSource('origin.example', kind: kind);
    await books.importSources([target, origin]);
    await books.saveSource(target, {'enabled': true});
    await books.saveSource(origin, {'enabled': true});
    return _Fixture(root, services, books, target, origin);
  }

  static BooksRepository _repository(AppServices services, _TextFetch? fetch) =>
      BooksRepository(
        services.db,
        services.root,
        services.offline,
        services.contentPolicy,
        (file, token, extension) async {},
        downloadText: fetch ?? (source, book, chapter, token) async => '新正文',
      );

  Future<BookDownloadEvidence> capture() =>
      books.downloadGuard.capture(target, targetChapter, origin, originChapter);

  Future<void> downloadFromOrigin() => books.download(
    target,
    targetChapter,
    CancellationToken(),
    alternatives: [
      (book: origin, chapters: [originChapter]),
    ],
    tryOriginal: false,
  );

  Future<File> installProvenAudio({
    bool direct = false,
    String suffix = 'fixture',
    BookChapter? chapter,
  }) async {
    final targetPart = chapter ?? targetChapter;
    final evidence = direct
        ? await books.downloadGuard.capture(
            target,
            targetPart,
            target,
            targetPart,
          )
        : await books.downloadGuard.capture(
            target,
            targetPart,
            origin,
            originChapter,
          );
    final lease = books.downloadGuard.lease();
    final directory = 'v2-${target.id}-${targetPart.id}-$suffix';
    final dir = Directory(p.join(books.audioFiles.root.path, directory));
    await dir.create(recursive: true);
    final bytes = utf8.encode('fixture audio bytes');
    final file = await File(p.join(dir.path, 'audio.mp3')).writeAsBytes(bytes);
    await File(p.join(dir.path, 'entry')).writeAsString('audio.mp3');
    await File(p.join(dir.path, 'integrity.json')).writeAsString(
      jsonEncode({
        'bytes': bytes.length,
        'digest': sha256.convert(bytes).toString(),
      }),
    );
    await File(
      p.join(dir.path, 'source-evidence.json'),
    ).writeAsString(jsonEncode(evidence.toJson()));
    await books.store.saveProvenAudio(
      target,
      targetPart,
      directory,
      evidence,
      () => books.downloadGuard.validate(evidence, expected: lease),
    );
    return file;
  }

  Future<void> restart() async {
    await books.close();
    await services.close();
    services = AppServices.scoped(
      root,
      AppDatabase(File(p.join(root.path, 'db.sqlite'))),
    );
    await services.settings.load();
    await services.supervision.load();
    books = _repository(services, null);
    await books.ensureSourceRiskLoaded();
  }

  Future<void> close() async {
    await books.close();
    await services.close();
    await root.delete(recursive: true);
  }
}
