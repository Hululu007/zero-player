import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../../core/network/cancellation_token.dart';
import '../../supervision/domain/supervision_rules.dart';
import '../domain/book.dart';
import '../domain/book_download_plan.dart';
import 'books_repository.dart';
import 'book_chapter_policy.dart';
import 'book_latest_aggregation.dart';
import 'book_catalog_window.dart';
import 'book_site_check.dart';
import 'book_vault.dart';

enum BookDownloadStatus { running, completed, partial, paused, failed }

final class BookDownloadTask extends ChangeNotifier {
  BookDownloadTask(this.book, this.token, this.chapters);

  final Book book;
  final CancellationToken token;
  final List<BookChapter> chapters;
  late final Future<void> done;
  BookDownloadStatus status = BookDownloadStatus.running;
  int finished = 0;
  int total = 0;
  int failures = 0;
  final Map<String, ChapterContentBlocked> blockedChapters = {};
  final Map<String, String> failedChapters = {};
  bool _stoppedByPolicy = false;
  final Set<String> savedChapterIds = {};
  String? error;

  void pause() => token.cancel();

  void changed() => notifyListeners();
}

/// Owns downloads for the lifetime of the repository, independently of routes.
final class BookDownloadCoordinator extends ChangeNotifier {
  BookDownloadCoordinator(
    this.repository, {
    this.downloadChapter,
    this.maxConcurrency,
    this.loadLatestEditions,
  }) {
    _policySnapshot = bookSitePolicySnapshot(repository.policy);
    repository.policy.addListener(_policyChanged);
    repository.sourceRiskChanges.addListener(_policyChanged);
    repository.store.vault.addListener(_vaultChanged);
  }

  final BooksRepository repository;
  final Future<void> Function(Book, BookChapter, CancellationToken)?
  downloadChapter;

  /// Optional cap on parallel chapter fetches; defaults are tuned per kind.
  final int? maxConcurrency;

  @visibleForTesting
  final Future<List<BookEdition>> Function(Book, CancellationToken)?
  loadLatestEditions;

  /// Text pages are cheap and latency-bound, so a wider pool pays off; image
  /// and audio payloads are heavier, so they keep a narrower one.
  static const _parallelByKind = <BookKind, int>{
    BookKind.text: 4,
    BookKind.comic: 3,
    BookKind.audio: 2,
  };

  int _concurrencyFor(Book book, int chapters) {
    final cap = maxConcurrency ?? _parallelByKind[book.kind] ?? 2;
    return math.max(1, math.min(cap, chapters));
  }

  final Map<String, BookDownloadTask> _tasks = {};
  bool _closed = false;
  late String _policySnapshot;

  BookDownloadTask? active(Book book) => _tasks[book.id];
  List<BookDownloadTask> get activeTasks => List.unmodifiable(_tasks.values);

  BookDownloadTask start(
    Book book,
    List<BookChapter> catalog,
    BookDownloadPlan plan, {
    bool keepPlan = true,
  }) {
    if (_closed) throw StateError('下载服务已关闭');
    final running = _tasks[book.id];
    if (running != null) return running;
    final task = BookDownloadTask(book, CancellationToken(), List.of(catalog));
    _tasks[book.id] = task;
    task.addListener(notifyListeners);
    task.done = _run(task, List.of(catalog), plan, keepPlan).whenComplete(() {
      task.removeListener(notifyListeners);
      notifyListeners();
    });
    notifyListeners();
    return task;
  }

  Future<void> pause(Book book) async {
    final task = active(book);
    if (task == null) return;
    task.pause();
    await task.done;
  }

  Future<void> removePlan(Book book) async {
    final task = active(book);
    if (task != null) {
      task.pause();
      await task.done;
    }
    await repository.store.writeBookValue(
      book,
      'books_download:${book.id}',
      null,
    );
    await repository.store.writeBookValue(
      book,
      'books_download_failures:${book.id}',
      null,
    );
    notifyListeners();
  }

  Future<void> _run(
    BookDownloadTask task,
    List<BookChapter> catalog,
    BookDownloadPlan plan,
    bool keepPlan,
  ) async {
    final book = task.book;
    final token = task.token;
    final key = 'books_download:${book.id}';
    final blockedReasons = <String, String>{};
    final failedReasons = <String, String>{};
    var reasonsLoaded = false;
    try {
      if (await repository.store.isPrivateBook(book.id) &&
          !repository.store.vault.unlocked) {
        throw const VaultLockedException();
      }
      await _loadReasons(task.book, catalog, blockedReasons, failedReasons);
      reasonsLoaded = true;
      catalog = await _extendCatalog(task, catalog, plan);
      final ids = plan.fullBook ? null : plan.chapterIds?.toSet();
      final range = ids == null
          ? catalog
                .skip(plan.fullBook ? 0 : plan.first - 1)
                .take(
                  plan.fullBook ? catalog.length : plan.last - plan.first + 1,
                )
                .toList()
          : catalog.where((chapter) => ids.contains(chapter.id)).toList();
      if (range.isEmpty) throw const FormatException('目录中已找不到所选章节');
      await repository.store.saveBook(
        book,
        chapters: catalog,
        preserveCatalog: true,
      );
      if (keepPlan) {
        final savedPlan = BookDownloadPlan(
          plan.first,
          plan.fullBook ? catalog.length : plan.last,
          plan.fallback,
          fullBook: plan.fullBook,
          aggregateLatest: plan.aggregateLatest,
          chapterIds: range.map((chapter) => chapter.id).toList(),
        );
        await repository.store.writeBookValue(book, key, savedPlan.toJson());
      }
      final saved = await repository.reusableDownloads(book, range, token);
      token.check();
      blockedReasons.removeWhere((id, _) => saved.contains(id));
      failedReasons.removeWhere((id, _) => saved.contains(id));
      final chapters = range
          .where((chapter) => !saved.contains(chapter.id))
          .toList();
      task.total = chapters.length;
      task.changed();
      if (chapters.isEmpty) {
        task.status = BookDownloadStatus.completed;
        return;
      }
      token.check();
      await _downloadRange(task, chapters, plan, blockedReasons, failedReasons);
      token.check();
      task.status = task.failures == 0
          ? BookDownloadStatus.completed
          : BookDownloadStatus.partial;
      if (task.failedChapters.isNotEmpty) {
        task.error = '${task.failedChapters.length} 章下载失败，可继续下载重试';
      }
    } on RequestCancelled {
      task.status = BookDownloadStatus.paused;
      if (task._stoppedByPolicy) task.error = '内容策略已改变，下载已暂停';
    } on VaultLockedException {
      task.status = BookDownloadStatus.paused;
      task.error = '私密书架已锁定，解锁后可继续下载';
    } on ContentBlocked {
      task.status = BookDownloadStatus.paused;
      task.error = '内容策略已改变，下载已暂停';
    } on Exception catch (error) {
      task.status = BookDownloadStatus.failed;
      task.error = error is FormatException
          ? error.message
          : error is BookCatalogCapacityExceeded
          ? error.toString()
          : '下载未完成，请检查来源或网络';
    } finally {
      if (reasonsLoaded) {
        await _saveResult(task, blockedReasons, failedReasons, keepPlan);
      }
      if (identical(_tasks[book.id], task)) _tasks.remove(book.id);
      task.changed();
    }
  }

  Future<void> _saveResult(
    BookDownloadTask task,
    Map<String, String> blocked,
    Map<String, String> failed,
    bool keepPlan,
  ) async {
    try {
      await repository.store.db.atomic(() async {
        await repository.store.writeBookValue(
          task.book,
          'books_download_blocked:${task.book.id}',
          blocked,
        );
        await repository.store.writeBookValue(
          task.book,
          'books_download_failures:${task.book.id}',
          failed,
        );
        if (task.status == BookDownloadStatus.completed && keepPlan) {
          await repository.store.writeBookValue(
            task.book,
            'books_download:${task.book.id}',
            null,
          );
        }
      });
    } on VaultLockedException {
      task.status = BookDownloadStatus.paused;
      task.error = '私密书架已锁定，解锁后将重新核对已下载章节';
    } on Exception {
      if (task.status == BookDownloadStatus.completed ||
          task.status == BookDownloadStatus.partial) {
        task.status = BookDownloadStatus.failed;
      }
      task.error = [
        if (task.error != null) task.error,
        '下载状态未保存，请继续下载检查',
      ].join('；');
    }
  }

  Future<void> _loadReasons(
    Book book,
    List<BookChapter> catalog,
    Map<String, String> blocked,
    Map<String, String> failed,
  ) async {
    final previous = await repository.store.readBookValue(
      book,
      'books_download_blocked:${book.id}',
    );
    final previousFailures = await repository.store.readBookValue(
      book,
      'books_download_failures:${book.id}',
    );
    for (final chapter in catalog) {
      final reason = previous is Map ? previous[chapter.id] : null;
      if (reason == '成人正文规则命中' || reason == '监管关键词命中') {
        blocked[chapter.id] = reason as String;
      }
      if (previousFailures is Map && previousFailures.containsKey(chapter.id)) {
        failed[chapter.id] = '下载失败，请检查来源或网络';
      }
    }
  }

  Future<List<BookChapter>> _extendCatalog(
    BookDownloadTask task,
    List<BookChapter> catalog,
    BookDownloadPlan plan,
  ) async {
    if (!plan.fullBook ||
        !plan.aggregateLatest ||
        task.book.kind != BookKind.text) {
      return catalog;
    }
    task.token.check();
    final editions =
        await (loadLatestEditions?.call(task.book, task.token) ??
            repository.alternatives(task.book, task.token, refresh: true));
    task.token.check();
    final result = await BookLatestAggregation(
      repository.store,
      repository.downloadGuard,
    ).prepare(task.book, catalog, editions, task.token);
    task.token.check();
    task.chapters
      ..clear()
      ..addAll(result);
    task.changed();
    return result;
  }

  Future<void> _downloadRange(
    BookDownloadTask task,
    List<BookChapter> chapters,
    BookDownloadPlan plan,
    Map<String, String> blockedReasons,
    Map<String, String> failedReasons,
  ) async {
    final book = task.book;
    final token = task.token;
    Future<List<BookEdition>>? alternatives;
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < chapters.length) {
        final chapter = chapters[cursor++];
        token.check();
        try {
          await _downloadOne(
            book,
            chapter,
            plan,
            token,
            () async => alternatives ??= repository.alternatives(book, token),
          );
          task.savedChapterIds.add(chapter.id);
          blockedReasons.remove(chapter.id);
          failedReasons.remove(chapter.id);
        } on ChapterContentBlocked catch (error) {
          token.check();
          task.failures++;
          task.blockedChapters[chapter.id] = error;
          failedReasons.remove(chapter.id);
          blockedReasons[chapter.id] = error.supervised
              ? '监管关键词命中'
              : '成人正文规则命中';
          task.error = '部分章节正文触发过滤，已跳过并继续下载其他章节；可验证复核或设置替换后续传';
        } on ContentBlocked {
          if (!token.isCancelled) task._stoppedByPolicy = true;
          token.cancel();
          rethrow;
        } on Exception {
          token.check();
          task.failures++;
          task.failedChapters[chapter.id] = '下载失败，请检查来源或网络';
          failedReasons[chapter.id] = task.failedChapters[chapter.id]!;
        }
        task.finished++;
        task.changed();
      }
    }

    await Future.wait(
      List.generate(_concurrencyFor(book, chapters.length), (_) => worker()),
    );
  }

  Future<void> _downloadOne(
    Book book,
    BookChapter chapter,
    BookDownloadPlan plan,
    CancellationToken token,
    Future<List<BookEdition>> Function() alternatives,
  ) async {
    try {
      if (downloadChapter case final callback?) {
        await callback(book, chapter, token);
      } else {
        await repository.download(book, chapter, token);
      }
    } on ContentBlocked {
      rethrow;
    } on Exception {
      token.check();
      if (!plan.fallback) rethrow;
      await repository.download(
        book,
        chapter,
        token,
        alternatives: await alternatives(),
        tryOriginal: false,
      );
    }
  }

  void _policyChanged() {
    final next = bookSitePolicySnapshot(repository.policy);
    final changed = next != _policySnapshot;
    _policySnapshot = next;
    for (final task in _tasks.values) {
      if (!repository.closing &&
          !changed &&
          repository.bookAllowed(task.book)) {
        continue;
      }
      if (task.status == BookDownloadStatus.running &&
          !task.token.isCancelled) {
        if (!repository.closing) task._stoppedByPolicy = true;
        task.pause();
      }
    }
  }

  void _vaultChanged() {
    if (repository.store.vault.unlocked) return;
    for (final task in _tasks.values) {
      if (task.status == BookDownloadStatus.running &&
          !task.token.isCancelled &&
          repository.store.vault.isPrivate(task.book.id)) {
        task.pause();
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    repository.policy.removeListener(_policyChanged);
    repository.sourceRiskChanges.removeListener(_policyChanged);
    repository.store.vault.removeListener(_vaultChanged);
    final tasks = _tasks.values.toList();
    for (final task in tasks) {
      task.pause();
    }
    await Future.wait(tasks.map((task) => task.done));
  }
}
