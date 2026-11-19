import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/application/audiobook_controller.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/audiobook_player_page.dart';

import '../../test_support/book_fixture_source.dart';
import '../../test_support/fake_player_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _riskDuringResumePreparationTests();
  _privateAudioLockTests();
  _blacklistDuringOpenTests();
  _blacklistDuringResumeTests();
  _quarantinedChapterSheetTests();
}

void _privateAudioLockTests() {
  test(
    'vault lock stops background audio and clears private playback metadata',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'audiobook-vault-lock-',
      );
      final services = AppServices.scoped(root, AppDatabase.memory());
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      await services.settings.load();
      await services.supervision.load();
      final source = bookFixtureSource(
        'audio-vault.test',
        kind: BookKind.audio,
      );
      await services.books.importSources([source]);
      final book = Book(
        source.id,
        BookKind.audio,
        '私密音频',
        '',
        source.endpoint.resolve('/book'),
      );
      final chapter = BookChapter('第一章', source.endpoint.resolve('/chapter'));
      await _cacheAudio(services, book, chapter);
      final store = services.books.store;
      await store.saveBook(book, chapters: [chapter]);
      await store.vault.create('secret-123');
      await store.moveToVault(book);
      final engine = FakePlayerEngine();
      final player = AudiobookController(
        services.books,
        () => engine,
        () async {},
      );
      addTearDown(player.close);
      final ready = Completer<void>();
      player.addListener(() {
        if (!player.loading && player.playing && !ready.isCompleted) {
          ready.complete();
        }
      });
      player.start(book, [chapter], chapter);
      await ready.future.timeout(const Duration(seconds: 5));
      engine.change(position: const Duration(seconds: 17));
      store.vault.lock();
      expect(player.active, isFalse);
      expect(player.title, isEmpty);
      expect(player.book, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(engine.snapshot.playing, isFalse);
      player.start(book, [chapter], chapter);
      expect(player.active, isFalse);
      expect(player.progressNotice, contains('补存'));
      final unencrypted = await services.db.rows(
        "SELECT key FROM app_meta WHERE key GLOB 'books_shelf:*'",
      );
      expect(unencrypted, isEmpty);
      expect(await store.vault.unlock('secret-123'), isTrue);
      for (var i = 0; i < 200 && player.progressNotice != null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(player.progressNotice, isNull);
      expect((await store.entry(book))!.position, 17000);
      expect(player.active, isFalse);
    },
  );
}

void _riskDuringResumePreparationTests() {
  test(
    'a risk change while preparing resume cannot restart playback',
    () async {
      final root = await Directory.systemTemp.createTemp('audiobook-risk-');
      final services = AppServices.scoped(root, AppDatabase.memory());
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      await services.settings.load();
      await services.supervision.load();
      final source = bookFixtureSource('audio-risk.test', kind: BookKind.audio);
      await services.books.importSources([source]);
      final book = Book(
        source.id,
        BookKind.audio,
        '作品',
        '',
        source.endpoint.resolve('/book'),
      );
      final chapter = BookChapter('第一章', source.endpoint.resolve('/chapter'));
      await _cacheAudio(services, book, chapter);

      final engine = FakePlayerEngine();
      final beforeResume = Completer<void>();
      final releaseResume = Completer<void>();
      var starts = 0;
      final player = AudiobookController(
        services.books,
        () => engine,
        () async {
          if (++starts > 1) {
            beforeResume.complete();
            await releaseResume.future;
          }
        },
      );
      addTearDown(() async {
        if (!releaseResume.isCompleted) releaseResume.complete();
        await player.close();
      });
      final ready = Completer<void>();
      void onPlayer() {
        if (!player.loading && player.playing && !ready.isCompleted) {
          ready.complete();
        }
      }

      player.addListener(onPlayer);
      player.start(book, [chapter], chapter);
      await ready.future.timeout(const Duration(seconds: 5));
      player.removeListener(onPlayer);
      await player.pause();
      await Future<void>.delayed(Duration.zero);
      expect(player.playing, isFalse);
      final pending = player.toggle();
      await beforeResume.future.timeout(const Duration(seconds: 5));
      await services.books.markSourceRisk(source, adult: true);
      releaseResume.complete();
      await pending;
      expect(engine.snapshot.playing, isFalse);
      expect(player.error, isNotNull);
    },
  );
}

void _blacklistDuringOpenTests() {
  test(
    'blacklisting during delayed audio open stops and blocks offline playback',
    () async {
      final root = await Directory.systemTemp.createTemp('audiobook-blocked-');
      final services = AppServices.scoped(root, AppDatabase.memory());
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      await services.settings.load();
      await services.supervision.load();
      final source = bookFixtureSource(
        'audio-blocked.test',
        kind: BookKind.audio,
      );
      await services.books.importSources([source]);
      final book = Book(
        source.id,
        BookKind.audio,
        '作品',
        '',
        source.endpoint.resolve('/book'),
      );
      final chapter = BookChapter('第一章', source.endpoint.resolve('/chapter'));
      await _cacheAudio(services, book, chapter);
      final started = Completer<void>();
      final release = Completer<void>();
      final engine = FakePlayerEngine(
        onOpen: () async {
          started.complete();
          await release.future;
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
      final done = Completer<void>();
      void onPlayer() {
        if (!player.loading && player.error != null && !done.isCompleted) {
          done.complete();
        }
      }

      player.addListener(onPlayer);
      player.start(book, [chapter], chapter);
      await started.future.timeout(const Duration(seconds: 5));
      await services.books.blockSource(source);
      expect(services.books.bookAllowed(book), isFalse);
      release.complete();
      await done.future.timeout(const Duration(seconds: 5));
      expect(engine.snapshot.playing, isFalse);
      expect(engine.opens, 1);
      await player.toggle();
      expect(engine.snapshot.playing, isFalse);
      await player.stop();
      final blocked = Completer<void>();
      void onBlocked() {
        if (!player.loading && player.error != null && !blocked.isCompleted) {
          blocked.complete();
        }
      }

      player.removeListener(onPlayer);
      player.addListener(onBlocked);
      player.start(book, [chapter], chapter);
      await blocked.future.timeout(const Duration(seconds: 5));
      expect(engine.opens, 1);
      expect(engine.snapshot.playing, isFalse);
      player.removeListener(onBlocked);
      await services.books.unblockSource(source.id);
      expect(services.books.bookAllowed(book), isTrue);
      expect(await services.books.audioFiles.contains(book, chapter), isTrue);
    },
  );
}

void _blacklistDuringResumeTests() {
  test('blacklisting during delayed resume pauses the late command', () async {
    final root = await Directory.systemTemp.createTemp(
      'audiobook-late-resume-',
    );
    final services = AppServices.scoped(root, AppDatabase.memory());
    addTearDown(() async {
      await services.close();
      await root.delete(recursive: true);
    });
    await services.settings.load();
    await services.supervision.load();
    final source = bookFixtureSource('late-resume.test', kind: BookKind.audio);
    await services.books.importSources([source]);
    final book = Book(
      source.id,
      BookKind.audio,
      '作品',
      '',
      source.endpoint.resolve('/book'),
    );
    final chapter = BookChapter('第一章', source.endpoint.resolve('/chapter'));
    await _cacheAudio(services, book, chapter);
    final started = Completer<void>();
    final release = Completer<void>();
    final engine = FakePlayerEngine(
      onPlayOrPause: () async {
        started.complete();
        await release.future;
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
    final ready = Completer<void>();
    void onPlayer() {
      if (!player.loading && player.playing && !ready.isCompleted) {
        ready.complete();
      }
    }

    player.addListener(onPlayer);
    player.start(book, [chapter], chapter);
    await ready.future.timeout(const Duration(seconds: 5));
    player.removeListener(onPlayer);
    await player.pause();
    await Future<void>.delayed(Duration.zero);
    final pending = player.toggle();
    await started.future.timeout(const Duration(seconds: 5));
    await services.books.blockSource(source);
    release.complete();
    await pending;
    expect(engine.snapshot.playing, isFalse);
    expect(player.error, isNotNull);
  });
}

void _quarantinedChapterSheetTests() {
  testWidgets('open chapter sheet hides titles when source is quarantined', (
    tester,
  ) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('audiobook-sheet-risk-'),
    ))!;
    final services = AppServices.scoped(root, AppDatabase.memory());
    addTearDown(() async {
      await tester.runAsync(() async {
        await services.close();
        await root.delete(recursive: true);
      });
    });
    final source = bookFixtureSource('audio-sheet.test', kind: BookKind.audio);
    await tester.runAsync(() async {
      await services.settings.load();
      await services.supervision.load();
      await services.books.importSources([source]);
    });
    final book = Book(
      source.id,
      BookKind.audio,
      '作品',
      '',
      source.endpoint.resolve('/book'),
    );
    final chapter = BookChapter('保留的章节标题', source.endpoint.resolve('/chapter'));
    final player = services.audiobookPlayer;
    player.book = book;
    player.chapter = chapter;
    player.chapters = [chapter];
    await tester.pumpWidget(
      MaterialApp(
        home: AudiobookPlayerPage(
          services: services,
          book: book,
          chapters: [chapter],
          initial: chapter,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('章节 1/1'));
    await tester.pumpAndSettle();
    expect(find.text('保留的章节标题'), findsWidgets);
    await tester.runAsync(
      () => services.books.markSourceRisk(source, quarantine: true),
    );
    await tester.pumpAndSettle();
    expect(find.text('保留的章节标题'), findsNothing);
    expect(find.text('当前内容策略限制访问此作品'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _cacheAudio(
  AppServices services,
  Book book,
  BookChapter chapter,
) async {
  final audioDir = Directory(
    p.join(services.books.audioFiles.root.path, '${book.id}-${chapter.id}'),
  );
  await audioDir.create(recursive: true);
  final bytes = utf8.encode('fake audio for the injected player');
  await File(p.join(audioDir.path, 'audio.mp3')).writeAsBytes(bytes);
  await File(p.join(audioDir.path, 'entry')).writeAsString('audio.mp3');
  await File(p.join(audioDir.path, 'integrity.json')).writeAsString(
    jsonEncode({
      'bytes': bytes.length,
      'digest': sha256.convert(bytes).toString(),
    }),
  );
}
