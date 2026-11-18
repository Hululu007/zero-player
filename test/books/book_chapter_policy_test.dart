import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/features/books/data/book_chapter_policy.dart';
import 'package:zero_player/features/books/data/book_comic_access.dart';
import 'package:zero_player/features/books/data/book_download_coordinator.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_download_plan.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';
import '../../test_support/book_fixture_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppServices services;
  late Directory root;
  final book = Book(
    'source',
    BookKind.text,
    '青山',
    '作者',
    Uri.parse('https://fixture.test/book'),
  );
  final chapter = BookChapter('第一百章', Uri.parse('https://fixture.test/100'));
  const password = 'fixture-password';
  setUp(() async {
    root = await Directory.systemTemp.createTemp('chapter-policy-');
    services = AppServices.scoped(root, AppDatabase.memory());
    await services.settings.load();
    await services.supervision.load();
    await services.supervision.saveCredentials(
      await services.supervision.prepareCredentials(password),
    );
    await services.books.chapterPolicy.load();
  });
  tearDown(() async {
    await services.close();
    await root.delete(recursive: true);
  });
  Future<T> verified<T>(Future<T> Function() action) => services.supervision
      .execute(SensitiveOperation.supervision, action, password: password);

  test(
    'diagnostics stay generic and exact chapter approval survives reload',
    () async {
      final policy = services.books.chapterPolicy;
      late ChapterContentBlocked blocked;
      try {
        policy.prepare(book, chapter, '普通上下文中提到色情一词');
      } on ChapterContentBlocked catch (error) {
        blocked = error;
      }
      expect(blocked.message, isNot(contains('色情')));
      expect(blocked.matches, contains('色情'));
      await expectLater(policy.approve(blocked), throwsFormatException);
      await verified(() => policy.approve(blocked));
      expect(policy.prepare(book, chapter, '普通上下文中提到色情一词'), contains('普通上下文'));
      expect(
        () => policy.prepare(book, chapter, '正文发生变化，色情'),
        throwsA(isA<ChapterContentBlocked>()),
      );
      final other = BookChapter(
        '第一百零一章',
        Uri.parse('https://fixture.test/101'),
      );
      expect(
        () => policy.prepare(book, other, '普通上下文中提到色情一词'),
        throwsA(isA<ChapterContentBlocked>()),
      );
      final reloaded = BookChapterPolicy(
        services.books.store,
        services.contentPolicy,
      );
      await reloaded.load();
      expect(
        reloaded.prepare(book, chapter, '普通上下文中提到色情一词'),
        contains('普通上下文'),
      );
    },
  );

  test(
    'reader cleanup validation does not repeat sensitive replacements',
    () async {
      final policy = services.books.chapterPolicy;
      await verified(
        () => policy.saveRules([
          const BookTextReplacement('原词', '原词原词'),
          const BookTextReplacement('色情', ''),
        ]),
      );
      final prepared = policy.prepare(book, chapter, '原词与广告');
      final cleaned = prepared.replaceAll('广告', '');
      expect(policy.checkPrepared(book, chapter, cleaned), '原词原词与');
      expect(
        () => policy.checkPrepared(book, chapter, '新增色情'),
        throwsA(isA<ChapterContentBlocked>()),
      );
    },
  );

  test(
    'verified Qingshan compound does not suppress another real rule hit',
    () {
      final policy = services.books.chapterPolicy;
      expect(policy.prepare(book, chapter, '恨与敬仰交织成灰色情绪。'), '恨与敬仰交织成灰色情绪。');
      expect(
        () => policy.prepare(book, chapter, '灰色情绪。另有色情标记。'),
        throwsA(isA<ChapterContentBlocked>()),
      );
    },
  );

  test(
    'replacement preserves other paragraphs, rechecks output and requires password',
    () async {
      final policy = services.books.chapterPolicy;
      final rules = [const BookTextReplacement('色情', '已替换', paragraph: true)];
      await expectLater(policy.saveRules(rules), throwsFormatException);
      await verified(() => policy.saveRules(rules));
      expect(
        policy.prepare(book, chapter, '前一段\n含有色情的段落\n下一段'),
        '前一段\n已替换\n下一段',
      );
      final reloaded = BookChapterPolicy(
        services.books.store,
        services.contentPolicy,
      );
      await reloaded.load();
      expect(reloaded.prepare(book, chapter, '普通色情段落'), '已替换');
      await verified(
        () => policy.saveRules([const BookTextReplacement('普通', '色情')]),
      );
      expect(
        () => policy.prepare(book, chapter, '普通文字'),
        throwsA(isA<ChapterContentBlocked>()),
      );
      expect(const BookTextReplacement('A.+', 'X').apply('a.+ aaaa'), 'X aaaa');
    },
  );

  test(
    'supervision keyword cannot be cleared by adult false-positive approval',
    () async {
      await verified(
        () => services.supervision.updateRules(
          SupervisionRules(keywords: ['测试屏蔽']),
        ),
      );
      final policy = services.books.chapterPolicy;
      late ChapterContentBlocked blocked;
      try {
        policy.prepare(book, chapter, '测试屏蔽');
      } on ChapterContentBlocked catch (error) {
        blocked = error;
      }
      expect(blocked.supervised, isTrue);
      await expectLater(
        verified(() => policy.approve(blocked)),
        throwsFormatException,
      );
      expect(
        () => policy.prepare(book, chapter, '测试屏蔽'),
        throwsA(isA<ChapterContentBlocked>()),
      );
    },
  );

  test(
    'offline replacement preserves original and does not repeat on reread',
    () async {
      await verified(() => services.supervision.setEnabled(false));
      final local = Book(
        'local',
        BookKind.text,
        '本地',
        '',
        Uri.parse('file:///test.txt'),
      );
      final part = BookChapter('一', Uri.parse('file:///1'));
      await verified(
        () => services.books.chapterPolicy.saveRules([
          const BookTextReplacement('abc', 'abc!'),
        ]),
      );
      await services.books.store.saveText(local, part, 'abc\n后文');
      for (var i = 0; i < 2; i++) {
        expect(
          await services.books.readText(local, part, CancellationToken()),
          'abc!\n后文',
        );
      }
      expect(
        (await services.books.offlineText(
          local,
          part,
          CancellationToken(),
        )).body,
        'abc\n后文',
      );
    },
  );

  test(
    'paused download keeps generic diagnostics and successful retry clears them',
    () async {
      var firstPass = true;
      final second = BookChapter('下一章', Uri.parse('https://fixture.test/101'));
      final coordinator = BookDownloadCoordinator(
        services.books,
        maxConcurrency: 1,
        downloadChapter: (book, part, token) async {
          if (firstPass && part == chapter) {
            services.books.chapterPolicy.prepare(book, part, '色情');
          }
          if (firstPass) {
            token.cancel();
            token.check();
          }
          await services.books.store.saveText(book, part, '普通正文');
        },
      );
      addTearDown(coordinator.close);
      final task = coordinator.start(book, [
        chapter,
        second,
      ], const BookDownloadPlan(1, 2, false));
      await task.done;
      expect(task.status, BookDownloadStatus.paused);
      expect(
        await services.books.store.read('books_download_blocked:${book.id}'),
        {chapter.id: '成人正文规则命中'},
      );
      firstPass = false;
      final retry = coordinator.start(book, [
        chapter,
        second,
      ], const BookDownloadPlan(1, 2, false));
      await retry.done;
      expect(retry.savedChapterIds, hasLength(2));
      expect(
        await services.books.store.read('books_download_blocked:${book.id}'),
        isEmpty,
      );
    },
  );

  test(
    'body filtering skips one chapter and continues all other downloads',
    () async {
      final chapters = [
        chapter,
        for (var i = 1; i < 6; i++)
          BookChapter('目录$i', Uri.parse('https://fixture.test/$i')),
      ];
      final coordinator = BookDownloadCoordinator(
        services.books,
        downloadChapter: (book, part, token) async {
          services.books.chapterPolicy.prepare(
            book,
            part,
            part == chapter ? '色情' : '普通正文',
          );
          await services.books.store.saveText(book, part, '普通正文');
        },
      );
      addTearDown(coordinator.close);
      final task = coordinator.start(
        book,
        chapters,
        const BookDownloadPlan(1, 6, false),
      );
      await task.done;
      expect(task.status, BookDownloadStatus.completed);
      expect(task.finished, 6);
      expect(task.savedChapterIds, hasLength(5));
      expect(task.blockedChapters.keys, [chapter.id]);
      expect(await services.books.store.text(book, chapter), isNull);
      expect(
        await services.books.store.read('books_download:${book.id}'),
        isNotNull,
      );
      expect(
        await services.books.store.read('books_download_blocked:${book.id}'),
        {chapter.id: '成人正文规则命中'},
      );
    },
  );

  test('comic approval needs password and exact source fingerprint', () async {
    final source = bookFixtureSource('comic.test', kind: BookKind.comic);
    final access = services.books.comicAccess;
    await access.load();
    expect(access.allowed(source), isFalse);
    await expectLater(access.approve(source), throwsFormatException);
    await expectLater(
      verified(() => access.approve(source)),
      throwsA(isA<ContentBlocked>()),
    );
    await verified(() => services.supervision.setEnabled(false));
    await verified(() => access.approve(source));
    expect(access.allowed(source), isTrue);
    final updated = BookSource.fromJson({
      ...source.toJson(),
      'name': '规则更新',
      'mediaHosts': ['elsewhere.test'],
    });
    expect(access.allowed(updated), isFalse);
    final reloaded = BookComicAccess(
      services.books.store,
      services.contentPolicy,
    );
    await reloaded.load();
    expect(reloaded.allowed(source), isTrue);
    final sameHost = bookFixtureSource(
      'xapi.xinmanhua.net',
      kind: BookKind.comic,
    );
    expect(access.allowed(sameHost), isFalse);
    expect(
      access.allowed(
        BookSource.fromJson({...sameHost.toJson(), 'name': '新人漫画'}),
      ),
      isTrue,
    );
    expect(
      access.allowed(
        BookSource.fromJson({...sameHost.toJson(), 'name': '新漫画'}),
      ),
      isFalse,
    );
  });
}
