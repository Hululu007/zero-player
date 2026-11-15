import 'dart:io';

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
