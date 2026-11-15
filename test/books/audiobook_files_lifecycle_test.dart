import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/audiobook_files.dart';
import 'package:zero_player/features/books/domain/book.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _widgetAudioStoreCloseTests();
  _audioQueueCloseTests();
}

void _widgetAudioStoreCloseTests() {
  testWidgets(
    'unused audio store created in a widget can close from runAsync',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('audio-idle-close-'),
      ))!;
      final services = (await tester.runAsync(
        () async => AppServices.scoped(root, AppDatabase.memory()),
      ))!;
      await tester.runAsync(() async {
        await services.settings.load();
        await services.supervision.load();
      });
      late AudiobookFiles audio;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (_) {
              audio = services.books.audioFiles;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await audio.close().timeout(const Duration(seconds: 1));
        await services.books.coverCache.waitForIdle().timeout(
          const Duration(seconds: 1),
        );
        await services.close();
        await root.delete(recursive: true);
      });
    },
  );
}

void _audioQueueCloseTests() {
  test(
    'queued audio open cannot start after the store begins closing',
    () async {
      final root = await Directory.systemTemp.createTemp('audio-open-close-');
      final services = AppServices.scoped(root, AppDatabase.memory());
      final release = Completer<void>();
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await services.close();
        await root.delete(recursive: true);
      });
      final source = BookSource.fromJson({
        'name': '测试源',
        'kind': 'audio',
        'format': 'feed',
        'url': 'https://queue.example/feed',
      });
      final book = Book(source.id, BookKind.audio, '作品', '', source.endpoint);
      final chapter = BookChapter('第一章', source.endpoint.resolve('/one'));
      final other = BookChapter('第二章', source.endpoint.resolve('/two'));
      final audio = services.books.audioFiles;
      final directory = Directory(
        p.join(audio.root.path, '${book.id}-${chapter.id}'),
      );
      await directory.create(recursive: true);
      final bytes = utf8.encode('valid fixture bytes');
      await File(p.join(directory.path, 'audio.mp3')).writeAsBytes(bytes);
      await File(p.join(directory.path, 'entry')).writeAsString('audio.mp3');
      await File(p.join(directory.path, 'integrity.json')).writeAsString(
        jsonEncode({
          'bytes': bytes.length,
          'digest': sha256.convert(bytes).toString(),
        }),
      );
      final clearing = Completer<void>();
      final removal = audio.removeDownloaded(
        book,
        chapter: other,
        clearProof: () async {
          clearing.complete();
          await release.future;
        },
      );
      await clearing.future.timeout(const Duration(seconds: 5));
      final queuedOpen = expectLater(
        audio.open(book, chapter),
        throwsStateError,
      );
      final closing = audio.close();
      release.complete();
      await removal;
      await queuedOpen;
      await closing;
      expect(
        services.offline.isPlaying('books:${book.id}:${chapter.id}'),
        isFalse,
      );
      expect(await directory.exists(), isTrue);
    },
  );

  test(
    'selected audio deletion holds the queue until its proof is cleared',
    () async {
      final root = await Directory.systemTemp.createTemp('audio-delete-proof-');
      final services = AppServices.scoped(root, AppDatabase.memory());
      final release = Completer<void>();
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await services.close();
        await root.delete(recursive: true);
      });
      final source = BookSource.fromJson({
        'name': '测试源',
        'kind': 'audio',
        'format': 'feed',
        'url': 'https://queue.example/feed',
      });
      final book = Book(source.id, BookKind.audio, '作品', '', source.endpoint);
      final first = BookChapter('第一章', source.endpoint.resolve('/one'));
      final second = BookChapter('第二章', source.endpoint.resolve('/two'));
      final audio = services.books.audioFiles;
      final firstLegacy = Directory(
        p.join(audio.root.path, '${book.id}-${first.id}'),
      );
      final firstVersion = Directory(
        p.join(audio.root.path, 'v2-${book.id}-${first.id}-one'),
      );
      final secondLegacy = Directory(
        p.join(audio.root.path, '${book.id}-${second.id}'),
      );
      final secondVersion = Directory(
        p.join(audio.root.path, 'v2-${book.id}-${second.id}-two'),
      );
      for (final directory in [
        firstLegacy,
        firstVersion,
        secondLegacy,
        secondVersion,
      ]) {
        await directory.create(recursive: true);
        await File(p.join(directory.path, 'entry')).writeAsString('audio.mp3');
      }
      final clearing = Completer<void>();
      final removing = audio.removeDownloaded(
        book,
        chapter: first,
        clearProof: () async {
          clearing.complete();
          await release.future;
        },
      );
      await clearing.future.timeout(const Duration(seconds: 5));
      final started = Completer<void>();
      final later = expectLater(
        audio.download(source, book, first, CancellationToken(), () {
          started.complete();
          throw const FormatException('测试终止下载');
        }),
        throwsFormatException,
      );
      await Future<void>.delayed(Duration.zero);
      expect(started.isCompleted, isFalse);
      expect(await firstLegacy.exists(), isFalse);
      expect(await firstVersion.exists(), isFalse);
      expect(await secondLegacy.exists(), isTrue);
      expect(await secondVersion.exists(), isTrue);
      release.complete();
      await removing;
      await later;
      expect(started.isCompleted, isTrue);
    },
  );

  test(
    'failed write does not poison the queue and close waits for deletion',
    () async {
      final root = await Directory.systemTemp.createTemp('audio-write-queue-');
      final services = AppServices.scoped(root, AppDatabase.memory());
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      final source = BookSource.fromJson({
        'name': '测试源',
        'kind': 'audio',
        'format': 'feed',
        'url': 'https://queue.example/feed',
      });
      final book = Book(source.id, BookKind.audio, '作品', '', source.endpoint);
      final chapter = BookChapter('第一章', source.endpoint.resolve('/chapter'));
      final audio = services.books.audioFiles;
      final target = Directory(
        p.join(audio.root.path, '${book.id}-${chapter.id}'),
      );
      await target.create(recursive: true);
      await File(
        p.join(target.path, 'keep-until-removed'),
      ).writeAsString('sample');
      final failed = expectLater(
        audio.download(source, book, chapter, CancellationToken(), () {
          throw const FormatException('拒绝下载');
        }),
        throwsFormatException,
      );
      final removal = audio.remove(book, chapter);
      await audio.close();
      expect(await target.exists(), isFalse);
      await failed;
      await removal;
      expect(
        () => audio.download(source, book, chapter, CancellationToken(), () {}),
        throwsStateError,
      );
    },
  );

  test(
    'close prevents a pending removeSaved from starting a later deletion',
    () async {
      final root = await Directory.systemTemp.createTemp('audio-close-race-');
      final services = AppServices.scoped(root, AppDatabase.memory());
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      final source = BookSource.fromJson({
        'name': '测试源',
        'kind': 'audio',
        'format': 'feed',
        'url': 'https://queue.example/feed',
      });
      final book = Book(source.id, BookKind.audio, '作品', '', source.endpoint);
      final chapter = BookChapter('第一章', source.endpoint.resolve('/chapter'));
      final audio = services.books.audioFiles;
      final target = Directory(
        p.join(audio.root.path, '${book.id}-${chapter.id}'),
      );
      await target.create(recursive: true);
      await File(p.join(target.path, 'entry')).writeAsString('audio.mp3');
      await File(p.join(target.path, 'audio.mp3')).writeAsBytes([1, 2, 3]);
      final removing = expectLater(audio.removeSaved(book), throwsStateError);
      await audio.close();
      await removing;
      expect(await target.exists(), isTrue);
    },
  );
}
