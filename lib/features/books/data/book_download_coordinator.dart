import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../../core/network/cancellation_token.dart';
import '../../supervision/domain/supervision_rules.dart';
import '../domain/book.dart';
import '../domain/book_chapter_alignment.dart';
import '../domain/book_download_plan.dart';
import 'books_repository.dart';
import 'book_chapter_policy.dart';
import 'book_latest_aggregation.dart';
import 'book_catalog_window.dart';
import 'book_download_source_health.dart';
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
  final _sourceHealth = BookDownloadSourceHealth();
  BookDownloadSourceUnavailable? _sourcePause;
  final Set<String> savedChapterIds = {};
  String? error;
  String? preparation = '正在准备下载';
  bool aggregationLimited = false;
  String? aggregationProgress;
  ({int scheduled, int eligible})? aggregationScope;

  String? get aggregationNotice {
    final scope = aggregationScope;
    final notices = [
      if (scope != null && scope.eligible > scope.scheduled)
        '可检查 ${scope.eligible} 个渠道，本次最多检查 ${scope.scheduled} 个',
      if (scope != null &&
          scope.eligible == scope.scheduled &&
          scope.eligible > 8)
        '渠道较多，本次限时检查 ${scope.scheduled} 个',
      if (aggregationLimited) '部分渠道检测超时，继续下载已核验章节',
    ];
    return notices.isEmpty ? null : notices.join('。');
  }

  Timer? _progress;

  void pause() => token.cancel();

  void changed() {
    _progress?.cancel();
    _progress = null;
    notifyListeners();
  }

  void _progressChanged() {
    _progress ??= Timer(const Duration(milliseconds: 150), changed);
  }
}

/// Owns downloads for the lifetime of the repository, independently of routes.
final class BookDownloadCoordinator extends ChangeNotifier {
  BookDownloadCoordinator(
    this.repository, {
    this.downloadChapter,
    this.maxConcurrency,
    this.loadLatestEditions,
    this.aggregationTimeLimit = const Duration(seconds: 40),
    this.aggregationSourceLimit = 24,
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
  @visibleForTesting
  final Duration aggregationTimeLimit;
  @visibleForTesting
  final int aggregationSourceLimit;

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
    final store = repository.store;
    await store.vault.ensureLoaded();
    await store.db.atomic(() async {
      await store.writeBookValue(book, 'books_download:${book.id}', null);
      await store.writeBookValue(
        book,
        'books_download_failures:${book.id}',
        null,
      );
    }, tables: {'app_meta'});
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
    final blockedReasons = <String, String>{};
    final failedReasons = <String, String>{};
    var reasonsLoaded = false;
    _BookAggregateScan? scan;
    try {
      if (await repository.store.isPrivateBook(book.id) &&
          !repository.store.vault.unlocked) {
        throw const VaultLockedException();
      }
      await _loadReasons(task.book, catalog, blockedReasons, failedReasons);
      reasonsLoaded = true;
      final (range, needsScan) = await _prepareDownload(
        task,
        catalog,
        plan,
        keepPlan,
      );
      if (needsScan) {
        token.check();
        scan = _startAggregateScan(task);
      }
      final selected = await _downloadBatches(
        task,
        plan,
        range,
        blockedReasons,
        failedReasons,
        scan,
        keepPlan,
      );
      token.check();
      if (task._sourcePause case final refusal?) {
        task.status = BookDownloadStatus.paused;
        task.error = refusal.pauseMessage;
        return;
      }
      if (scan != null && keepPlan && task.failures != 0) {
        await _savePlan(task.book, plan, selected, aggregationPending: false);
      }
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
      await scan?.close();
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
        failed[chapter.id] = bookDownloadFailureReason(
          previousFailures[chapter.id],
        );
      }
    }
  }

  Future<(List<BookChapter>, bool)> _prepareDownload(
    BookDownloadTask task,
    List<BookChapter> catalog,
    BookDownloadPlan plan,
    bool keepPlan,
  ) async {
    final aggregate =
        plan.fullBook &&
        plan.aggregateLatest &&
        task.book.kind == BookKind.text;
    final ids = plan.chapterIds?.toSet();
    final selected = ids == null
        ? null
        : catalog.where((chapter) => ids.contains(chapter.id)).toList();
    final prepared =
        aggregate &&
        (selected?.isNotEmpty ?? false) &&
        selected!.length == ids!.length;
    final needsScan = aggregate && (!prepared || plan.aggregationPending);
    final range = prepared
        ? selected
        : plan.fullBook
        ? catalog
        : selected ??
              catalog
                  .skip(plan.first - 1)
                  .take(plan.last - plan.first + 1)
                  .toList();
    if (range.isEmpty && !needsScan) throw const FormatException('目录中已找不到所选章节');
    await _saveCatalog(
      task,
      catalog,
      plan,
      range,
      keepPlan,
      aggregationPending: needsScan,
    );
    return (range, needsScan);
  }

  Future<void> _saveCatalog(
    BookDownloadTask task,
    List<BookChapter> catalog,
    BookDownloadPlan plan,
    List<BookChapter> selected,
    bool keepPlan, {
    required bool aggregationPending,
  }) => repository.store.db.atomic(() async {
    if (aggregationPending) {
      task.token.check();
      repository.store.db.beforeCommit(task.token.check);
    }
    await repository.store.saveBook(
      task.book,
      chapters: catalog,
      preserveCatalog: true,
    );
    if (keepPlan) {
      await _savePlan(
        task.book,
        plan,
        selected,
        aggregationPending: aggregationPending,
      );
    }
  }, tables: {'app_meta'});

  Future<void> _savePlan(
    Book book,
    BookDownloadPlan plan,
    List<BookChapter> selected, {
    required bool aggregationPending,
  }) => repository.store.writeBookValue(
    book,
    'books_download:${book.id}',
    BookDownloadPlan(
      plan.first,
      plan.fullBook ? math.max(plan.first, selected.length) : plan.last,
      plan.fallback,
      fullBook: plan.fullBook,
      aggregateLatest: plan.aggregateLatest,
      aggregationPending: aggregationPending,
      chapterIds: selected.map((chapter) => chapter.id).toList(),
    ).toJson(),
  );

  _BookAggregateScan _startAggregateScan(BookDownloadTask task) {
    task.aggregationProgress = '正在后台检查当前目录和其他渠道';
    task.changed();
    return _BookAggregateScan(
      task.token,
      (scan) async {
        if (loadLatestEditions case final loader?) {
          final editions = await loader(task.book, scan.token).timeout(
            aggregationTimeLimit,
            onTimeout: () {
              if (scan.token.isCancelled) return [];
              task.aggregationLimited = true;
              scan.token.cancel();
              return [];
            },
          );
          if (task.aggregationLimited) return;
          scan.token.check();
          for (final edition in editions) {
            scan.publish((
              edition: edition,
              isCurrent: () => repository.bookAllowed(edition.book),
            ));
          }
          return;
        }
        await repository.alternatives(
          task.book,
          scan.token,
          refresh: true,
          includeCurrent: true,
          timeLimit: aggregationTimeLimit,
          maxSources: aggregationSourceLimit,
          onVerified: scan.publish,
          onTimeLimit: () => task.aggregationLimited = true,
          onProgress: (update) {
            task.aggregationScope = (
              scheduled: update.total,
              eligible: update.eligible,
            );
            task.aggregationProgress =
                '后台检查最新章节 ${update.completed}/${update.total}';
            task._progressChanged();
          },
        );
      },
      () {
        task.aggregationProgress = null;
        task._progressChanged();
      },
    );
  }

  Future<List<BookChapter>> _downloadBatches(
    BookDownloadTask task,
    BookDownloadPlan plan,
    List<BookChapter> initial,
    Map<String, String> blockedReasons,
    Map<String, String> failedReasons,
    _BookAggregateScan? scan,
    bool keepPlan,
  ) async {
    final selected = [...initial];
    var batch = initial;
    while (true) {
      if (batch.isNotEmpty) {
        await _downloadBatch(
          task,
          plan,
          batch,
          blockedReasons,
          failedReasons,
          scan,
        );
      }
      task.token.check();
      if (scan == null || task._sourcePause != null) return selected;
      final next = await _nextCatalog(
        task,
        scan,
        (catalog) => _saveCatalog(
          task,
          catalog,
          plan,
          [...selected, ...catalog.skip(task.chapters.length)],
          keepPlan,
          aggregationPending: true,
        ),
      );
      if (next.length == task.chapters.length) {
        if (selected.isEmpty) throw const FormatException('目录中未找到可下载章节');
        return selected;
      }
      batch = next.sublist(task.chapters.length);
      selected.addAll(batch);
      task.chapters
        ..clear()
        ..addAll(next);
    }
  }

  Future<List<BookChapter>> _nextCatalog(
    BookDownloadTask task,
    _BookAggregateScan scan,
    Future<void> Function(List<BookChapter>) saveCatalog,
  ) async {
    final aggregation = BookLatestAggregation(
      repository.store,
      repository.downloadGuard,
    );
    while (true) {
      task.token.check();
      final revision = scan.revision;
      final candidates = scan.current;
      final next = await aggregation.prepareNext(
        task.book,
        task.chapters,
        candidates.values.map((candidate) => candidate.edition),
        task.token,
        (book) => candidates[book.id]?.isCurrent() == true,
        saveCatalog,
      );
      if (next.length > task.chapters.length) return next;
      if (scan.finished && revision == scan.revision) {
        await scan.done;
        return next;
      }
      task.preparation = '等待已在检查的渠道返回目录';
      task.changed();
      await scan.waitForChange(revision);
    }
  }

  Future<void> _downloadBatch(
    BookDownloadTask task,
    BookDownloadPlan plan,
    List<BookChapter> range,
    Map<String, String> blockedReasons,
    Map<String, String> failedReasons,
    _BookAggregateScan? scan,
  ) async {
    task.preparation = '正在核对已下载章节';
    task.changed();
    final saved = await repository.reusableDownloads(
      task.book,
      range,
      task.token,
    );
    task.token.check();
    blockedReasons.removeWhere((id, _) => saved.contains(id));
    failedReasons.removeWhere((id, _) => saved.contains(id));
    final chapters = range
        .where((chapter) => !saved.contains(chapter.id))
        .toList();
    task.total += chapters.length;
    task.preparation = null;
    task.changed();
    if (chapters.isEmpty) return;
    await _downloadRange(
      task,
      chapters,
      plan,
      blockedReasons,
      failedReasons,
      scan,
    );
  }

  Future<List<BookEdition>> _fallbackEditions(BookDownloadTask task) async {
    try {
      task.preparation = '正在查找可用的替代书源';
      task.changed();
      return await repository.alternatives(
        task.book,
        task.token,
        timeLimit: aggregationTimeLimit,
        maxSources: aggregationSourceLimit,
      );
    } finally {
      task.preparation = null;
      task.changed();
    }
  }

  Future<void> _downloadRange(
    BookDownloadTask task,
    List<BookChapter> chapters,
    BookDownloadPlan plan,
    Map<String, String> blockedReasons,
    Map<String, String> failedReasons,
    _BookAggregateScan? scan,
  ) async {
    final book = task.book;
    final token = task.token;
    Future<List<BookEdition>>? alternatives;
    final fallback = _BookFallbackRoutes(repository, task);
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < chapters.length && task._sourcePause == null) {
        final chapter = chapters[cursor++];
        token.check();
        try {
          await _downloadOne(
            task,
            chapter,
            plan,
            fallback,
            () async => scan != null
                ? _latestFallback(task, scan, chapter, fallback)
                : (alternatives ??= _fallbackEditions(task)),
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
        } on Exception catch (error) {
          token.check();
          task.failures++;
          final reason = bookDownloadFailureReason(error);
          task.failedChapters[chapter.id] = reason;
          failedReasons[chapter.id] = reason;
          if (error is BookDownloadSourceUnavailable) {
            task._sourcePause ??= error;
          }
        }
        task.finished++;
        task._progressChanged();
      }
    }

    await Future.wait(
      List.generate(_concurrencyFor(book, chapters.length), (_) => worker()),
    );
  }

  Future<List<BookEdition>> _latestFallback(
    BookDownloadTask task,
    _BookAggregateScan scan,
    BookChapter chapter,
    _BookFallbackRoutes fallback,
  ) async {
    while (true) {
      task.token.check();
      final revision = scan.revision;
      final editions = [
        for (final candidate in scan.current.values)
          if (candidate.edition.book.sourceId != task.book.sourceId)
            candidate.edition,
      ];
      if (editions.any((edition) => fallback.match(edition, chapter) != null)) {
        return editions;
      }
      if (scan.finished) {
        await scan.done;
        return editions;
      }
      await scan.waitForChange(revision);
    }
  }

  Future<void> _downloadOne(
    BookDownloadTask task,
    BookChapter chapter,
    BookDownloadPlan plan,
    _BookFallbackRoutes fallback,
    Future<List<BookEdition>> Function() alternatives,
  ) async {
    final book = task.book;
    final token = task.token;
    try {
      if (downloadChapter case final callback?) {
        await callback(book, chapter, token);
      } else {
        await repository.download(
          book,
          chapter,
          token,
          sourceHealth: task._sourceHealth,
        );
      }
    } on ContentBlocked {
      rethrow;
    } on Exception catch (error) {
      token.check();
      if (!plan.fallback) rethrow;
      final editions = await alternatives();
      token.check();
      final routes = [
        for (final edition in editions)
          if (fallback.match(edition, chapter) case final match?)
            (edition.book, match),
      ];
      if (routes.isEmpty) {
        if (error is BookDownloadSourceUnavailable &&
            editions.any(fallback.available)) {
          throw const BookDownloadChapterUnmatched();
        }
        rethrow;
      }
      try {
        await repository.download(
          book,
          chapter,
          token,
          matchedAlternatives: routes,
          tryOriginal: false,
          sourceHealth: task._sourceHealth,
        );
      } on ContentBlocked {
        rethrow;
      } on BookDownloadSourceUnavailable {
        if (error is! BookDownloadSourceUnavailable) throw error;
        if (editions.any(fallback.available)) {
          throw const BookDownloadChapterUnmatched();
        }
        rethrow;
      } on Exception {
        token.check();
        if (error is BookDownloadSourceUnavailable &&
            !editions.any(fallback.available)) {
          throw error;
        }
        rethrow;
      }
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

final class _BookFallbackRoutes {
  _BookFallbackRoutes(this.repository, this.task);

  final BooksRepository repository;
  final BookDownloadTask task;
  late final _target = BookChapterFallbackIndex(task.chapters);
  final _indexes = <List<BookChapter>, BookChapterFallbackIndex>{};

  bool available(BookEdition edition) =>
      task._sourceHealth.unavailable(edition.book.sourceId) == null;

  BookChapter? match(BookEdition edition, BookChapter chapter) {
    if (!available(edition)) return null;
    if (task.book.kind != BookKind.text) {
      return repository.matchingChapter(edition.chapters, chapter);
    }
    final index = _indexes.putIfAbsent(
      edition.chapters,
      () => BookChapterFallbackIndex(edition.chapters),
    );
    return _target.match(chapter, index);
  }
}

/// Keeps verified results available while slower catalog requests are in flight.
final class _BookAggregateScan {
  _BookAggregateScan(
    CancellationToken parent,
    Future<void> Function(_BookAggregateScan) run,
    void Function() onFinished,
  ) {
    final unlink = parent.listen(stop);
    done =
        Future.any([
          Future<void>.sync(() {
            token.check();
            return run(this);
          }),
          _stopped.future,
        ]).whenComplete(() {
          unlink();
          finished = true;
          _signal();
          onFinished();
        });
    // The chapter workers can be busy when the scanner settles.
    unawaited(done.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  }

  final token = CancellationToken();
  final _stopped = Completer<void>();
  final _verified = <String, VerifiedBookEdition>{};
  var _change = Completer<void>();
  late final Future<void> done;
  int revision = 0;
  bool finished = false;

  Map<String, VerifiedBookEdition> get current => {
    for (final entry in _verified.entries)
      if (entry.value.isCurrent()) entry.key: entry.value,
  };

  void publish(VerifiedBookEdition candidate) {
    if (token.isCancelled) return;
    _verified[candidate.edition.book.id] = candidate;
    _signal();
  }

  Future<void> waitForChange(int previous) async {
    if (!finished && revision == previous) await _change.future;
  }

  void _signal() {
    revision++;
    _change.complete();
    _change = Completer<void>();
  }

  void stop() {
    if (_stopped.isCompleted) return;
    _stopped.complete();
    token.cancel();
  }

  Future<void> close() async {
    stop();
    await done.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  }
}
