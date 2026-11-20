import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_services.dart';
import '../data/book_download_coordinator.dart';
import '../data/book_download_source_health.dart';
import '../data/book_store.dart';
import '../domain/book.dart';
import '../domain/book_download_plan.dart';
import 'book_detail_page.dart';
import 'book_page_route.dart';
import 'book_text_policy_dialog.dart';
import 'book_blocked_chapters_dialog.dart';
import '../data/book_chapter_policy.dart';
import '../../../core/network/cancellation_token.dart';

typedef _DownloadItem = ({
  BookShelfEntry entry,
  BookDownloadPlan? plan,
  Set<String> saved,
  Map<String, String> blocked,
  Map<String, String> failed,
});

enum _DownloadFilter { all, running, pending, saved }

final class BookDownloadManagementPage extends StatefulWidget {
  const BookDownloadManagementPage({
    super.key,
    required this.services,
    this.private = false,
    this.inline = false,
    this.initialKind,
  });
  final AppServices services;
  final bool private, inline;
  final BookKind? initialKind;

  @override
  State<BookDownloadManagementPage> createState() =>
      _BookDownloadManagementPageState();
}

final class _BookDownloadManagementPageState
    extends State<BookDownloadManagementPage> {
  List<_DownloadItem> _items = [];
  Set<String> _activeIds = {};
  final Set<String> _busyIds = {};
  late BookKind? _kind = widget.initialKind;
  _DownloadFilter _filter = _DownloadFilter.all;
  int _sequence = 0;
  bool _loading = true;
  String? _error;

  BookDownloadCoordinator get _manager => widget.services.bookDownloads;

  @override
  void initState() {
    super.initState();
    _manager.addListener(_tasksChanged);
    widget.services.books.store.vault.addListener(_vaultChanged);
    widget.services.contentPolicy.addListener(_policyChanged);
    widget.services.books.sourceRiskChanges.addListener(_policyChanged);
    unawaited(_reload());
  }

  @override
  void dispose() {
    _manager.removeListener(_tasksChanged);
    widget.services.books.store.vault.removeListener(_vaultChanged);
    widget.services.contentPolicy.removeListener(_policyChanged);
    widget.services.books.sourceRiskChanges.removeListener(_policyChanged);
    super.dispose();
  }

  void _vaultChanged() {
    if (!mounted) return;
    _sequence++;
    setState(() {
      _items = [];
      _activeIds = {};
    });
    unawaited(_reload());
  }

  void _policyChanged() {
    if (!mounted) return;
    setState(() {
      _items.removeWhere(
        (item) => !widget.services.books.bookAllowed(item.entry.book),
      );
    });
    unawaited(_reload());
  }

  void _tasksChanged() {
    if (!mounted) return;
    final ids = _manager.activeTasks.map((task) => task.book.id).toSet();
    if (ids.length != _activeIds.length || !_activeIds.containsAll(ids)) {
      _activeIds = ids;
      unawaited(_reload());
    } else {
      setState(() {});
    }
  }

  Future<Set<String>> _saved(Book book) => switch (book.kind) {
    BookKind.text => widget.services.books.store.savedText(book),
    BookKind.comic => widget.services.books.store.savedImages(book),
    BookKind.audio => widget.services.books.savedAudio(book),
  };

  Future<void> _reload() async {
    final sequence = ++_sequence;
    if (mounted) setState(() => _loading = true);
    try {
      await widget.services.books.ensureSourceRiskLoaded();
      final store = widget.services.books.store;
      final plans = widget.private
          ? await store.vaultDownloadPlans()
          : await store.downloadPlans();
      final shelf = [
        ...widget.private ? await store.vaultShelf() : await store.shelf(),
        ...await store.detachedShelf(private: widget.private),
      ];
      final items = <_DownloadItem>[];
      final seen = <String>{};
      for (final entry in shelf) {
        final book = entry.book;
        if (!widget.services.books.bookAllowed(book) || !seen.add(book.id)) {
          continue;
        }
        final plan = plans[book.id];
        final active = _manager.active(book);
        final saved = await _saved(book);
        final failed = await _failed(book);
        if (plan != null ||
            active != null ||
            saved.isNotEmpty ||
            failed.isNotEmpty) {
          items.add((
            entry: entry,
            plan: plan,
            saved: saved,
            blocked: await _blocked(book),
            failed: failed,
          ));
          seen.add(book.id);
        }
      }
      for (final task in _manager.activeTasks) {
        final book = task.book;
        if (seen.contains(book.id) ||
            store.vault.isPrivate(book.id) != widget.private ||
            (widget.private && !store.vault.unlocked) ||
            !widget.services.books.bookAllowed(book)) {
          continue;
        }
        items.add((
          entry: BookShelfEntry(book, task.chapters, null, 0, false, 0),
          plan: plans[book.id],
          saved: await _saved(book),
          blocked: await _blocked(book),
          failed: await _failed(book),
        ));
      }
      if (!mounted || sequence != _sequence) return;
      setState(() {
        _items = items;
        _activeIds = _manager.activeTasks.map((task) => task.book.id).toSet();
        _loading = false;
        _error = null;
      });
    } on Exception {
      if (mounted && sequence == _sequence) {
        setState(() {
          _loading = false;
          _error = '无法读取下载记录';
        });
      }
    }
  }

  Future<Map<String, String>> _blocked(Book book) async {
    final raw = await widget.services.books.store.readBookValue(
      book,
      'books_download_blocked:${book.id}',
    );
    if (raw is! Map) return {};
    return {
      for (final key in raw.keys.whereType<String>())
        key: raw[key] == '监管关键词命中' ? '监管关键词命中' : '成人正文规则命中',
    };
  }

  Future<Map<String, String>> _failed(Book book) async {
    final raw = await widget.services.books.store.readBookValue(
      book,
      'books_download_failures:${book.id}',
    );
    return {
      if (raw is Map)
        for (final key in raw.keys.whereType<String>())
          key: bookDownloadFailureReason(raw[key]),
    };
  }

  Future<void> _failureReport(_DownloadItem item) async {
    final chapters = [
      for (final (position, chapter) in item.entry.chapters.indexed)
        if (item.failed[chapter.id] case final reason?)
          (position, chapter, reason),
    ];
    final book = item.entry.book;
    final books = widget.services.books;
    final vault = books.store.vault;
    bool allowed(BookChapter chapter) =>
        books.policy.textAllowed(chapter.title);
    final selected = {
      for (final (_, chapter, _) in chapters)
        if (allowed(chapter)) chapter.id,
    };
    final changes = Listenable.merge([
      books.policy,
      books.sourceRiskChanges,
      vault,
      _manager,
    ]);
    final retry = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => ListenableBuilder(
          listenable: changes,
          builder: (context, _) {
            final visible = _bookVisible(book);
            final canRetry = visible && _manager.active(book) == null;
            return AlertDialog(
              title: const Text('下载失败章节'),
              content: visible
                  ? SizedBox(
                      width: 420,
                      height: 320,
                      child: _failureChapters(
                        chapters,
                        selected,
                        allowed,
                        update,
                      ),
                    )
                  : const Text('作品当前不可访问'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭'),
                ),
                if (item.plan != null && canRetry)
                  TextButton(
                    onPressed: () => Navigator.pop(context, 'resume'),
                    child: const Text('重试未完成章节'),
                  ),
                if (canRetry)
                  FilledButton(
                    onPressed:
                        chapters.any(
                          (row) =>
                              selected.contains(row.$2.id) && allowed(row.$2),
                        )
                        ? () => Navigator.pop(context, 'fallback')
                        : null,
                    child: Text(
                      book.kind == BookKind.comic ? '重试所选章节' : '所选章节自动换源重试',
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
    if (!mounted ||
        retry == null ||
        _manager.active(book) != null ||
        !_bookVisible(book)) {
      return;
    }
    if (retry == 'resume') {
      // The coordinator rechecks each chapter under the current policy.
      _manager.start(book, item.entry.chapters, item.plan!);
      return;
    }
    final retryIds = [
      for (final (_, chapter, _) in chapters)
        if (selected.contains(chapter.id) && allowed(chapter)) chapter.id,
    ];
    if (retryIds.isEmpty) return;
    _manager.start(
      book,
      item.entry.chapters,
      BookDownloadPlan(
        1,
        item.entry.chapters.length,
        book.kind != BookKind.comic,
        chapterIds: retryIds,
      ),
      keepPlan: false,
    );
  }

  Widget _failureChapters(
    List<(int, BookChapter, String)> chapters,
    Set<String> selected,
    bool Function(BookChapter) allowed,
    StateSetter update,
  ) => ListView.builder(
    itemCount: chapters.length,
    itemBuilder: (_, index) {
      final (position, chapter, reason) = chapters[index];
      if (!allowed(chapter)) {
        return ListTile(title: Text('第${position + 1}章 · 内容已过滤'));
      }
      return CheckboxListTile(
        value: selected.contains(chapter.id),
        title: Text('第${position + 1}章 · ${chapter.title}'),
        subtitle: Text(reason),
        onChanged: (checked) => update(() {
          if (checked == true) {
            selected.add(chapter.id);
          } else {
            selected.remove(chapter.id);
          }
        }),
      );
    },
  );

  Future<void> _blockedReport(_DownloadItem item) => showBlockedChaptersDialog(
    context,
    chapters: [
      for (final (index, chapter) in item.entry.chapters.indexed)
        if (item.blocked[chapter.id] case final reason?)
          (
            position: index + 1,
            reason: reason,
            review: () => _reviewChapter(item.entry.book, chapter),
          ),
    ],
    replacements: () =>
        showBookTextReplacements(context, widget.services.books),
  );

  Future<void> _reviewChapter(Book book, BookChapter chapter) async {
    final books = widget.services.books;
    final token = CancellationToken();
    try {
      await books.readText(book, chapter, token);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('此章当前已可读取，可继续下载重试')));
      }
    } on ChapterContentBlocked catch (block) {
      if (mounted) await reviewBlockedChapter(context, books, block);
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('章节无法复核，请检查来源或网络')));
      }
    } finally {
      token.cancel();
    }
  }

  Future<void> _action(Book book, Future<void> Function() action) async {
    if (!_busyIds.add(book.id)) return;
    setState(() {});
    try {
      await action();
      await _reload();
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('操作未完成，请检查文件或内容权限')));
      }
    } finally {
      _busyIds.remove(book.id);
      if (mounted) setState(() {});
    }
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _removePlan(Book book) async {
    if (!await _confirm('移除下载计划？', '已保存的章节仍会保留，可从书籍详情重新选择下载。')) return;
    await _action(book, () => _manager.removePlan(book));
  }

  Future<void> _deleteOffline(Book book) async {
    if (!await _confirm('删除离线内容？', '将删除这本书已下载的章节，保留书架记录和阅读进度。')) return;
    await _action(book, () async {
      await _manager.removePlan(book);
      if (book.kind == BookKind.audio) {
        await widget.services.books.removeSavedAudio(book);
      } else {
        await widget.services.books.store.clearOffline(book);
      }
    });
  }

  Future<void> _open(Book book) async {
    await Navigator.of(context).push(
      BookPageRoute<void>(
        builder: (_) =>
            BookDetailPage(services: widget.services, initial: book),
      ),
    );
    if (mounted) await _reload();
  }

  bool _bookVisible(Book book) {
    final books = widget.services.books;
    final vault = books.store.vault;
    return vault.isPrivate(book.id) == widget.private &&
        (!widget.private || vault.unlocked) &&
        books.bookAllowed(book);
  }

  List<_DownloadItem> get _visible => _items.where((item) {
    if (!_bookVisible(item.entry.book)) return false;
    if (_kind != null && item.entry.book.kind != _kind) return false;
    final running = _manager.active(item.entry.book) != null;
    return switch (_filter) {
      _DownloadFilter.all => true,
      _DownloadFilter.running => running,
      _DownloadFilter.pending => !running && item.plan != null,
      _DownloadFilter.saved =>
        !running && item.plan == null && item.saved.isNotEmpty,
    };
  }).toList();

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return Scaffold(
      appBar: widget.inline
          ? null
          : AppBar(
              title: const Text('书籍下载管理'),
              actions: [
                IconButton(
                  tooltip: '刷新下载记录',
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
      body: Column(
        children: [
          _filters(),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _error != null
                ? Center(
                    child: TextButton(
                      onPressed: _reload,
                      child: Text('$_error，重试'),
                    ),
                  )
                : visible.isEmpty
                ? const Center(child: Text('暂无符合条件的下载'))
                : RefreshIndicator(
                    onRefresh: _reload,
                    child: ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (_, index) => _tile(visible[index]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _filters() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final kinds = DropdownButton<BookKind?>(
          value: _kind,
          isExpanded: constraints.maxWidth < 620,
          items: const [
            DropdownMenuItem(value: null, child: Text('全部类型')),
            DropdownMenuItem(value: BookKind.text, child: Text('文字')),
            DropdownMenuItem(value: BookKind.comic, child: Text('漫画')),
            DropdownMenuItem(value: BookKind.audio, child: Text('听书')),
          ],
          onChanged: (value) => setState(() => _kind = value),
        );
        final states = DropdownButton<_DownloadFilter>(
          value: _filter,
          isExpanded: constraints.maxWidth < 620,
          items: const [
            DropdownMenuItem(value: _DownloadFilter.all, child: Text('全部状态')),
            DropdownMenuItem(
              value: _DownloadFilter.running,
              child: Text('下载中'),
            ),
            DropdownMenuItem(
              value: _DownloadFilter.pending,
              child: Text('待续传'),
            ),
            DropdownMenuItem(value: _DownloadFilter.saved, child: Text('已保存')),
          ],
          onChanged: (value) =>
              setState(() => _filter = value ?? _DownloadFilter.all),
        );
        if (constraints.maxWidth >= 620) {
          return Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [kinds, states],
          );
        }
        // On phones keep both filters on a single row so they never wrap into
        // a second line above the list.
        return Row(
          children: [
            Expanded(child: kinds),
            const SizedBox(width: 8),
            Expanded(child: states),
          ],
        );
      },
    ),
  );

  Widget _tile(_DownloadItem item) {
    final book = item.entry.book;
    final task = _manager.active(book);
    final busy = _busyIds.contains(book.id);
    final count = item.saved.length;
    final plan = item.plan;
    final canResume =
        task == null && plan != null && item.entry.chapters.isNotEmpty;
    final planned = plan == null
        ? const <String>{}
        : plan.chapterIds?.toSet() ??
              item.entry.chapters
                  .skip(plan.fullBook ? 0 : plan.first - 1)
                  .take(
                    plan.fullBook
                        ? item.entry.chapters.length
                        : plan.last - plan.first + 1,
                  )
                  .map((chapter) => chapter.id)
                  .toSet();
    final savedInPlan = item.saved.intersection(planned).length;
    final status = task != null
        ? task.preparation ??
              '下载中 ${task.finished}/${task.total} · 已离线 $count 章'
        : plan != null
        ? '待续传 · 计划 $savedInPlan/${planned.length} 章 · 全书离线 $count 章'
        : count > 0
        ? '已离线 $count 章'
        : '待重试';
    return ListTile(
      leading: Icon(switch (book.kind) {
        BookKind.text => Icons.menu_book_outlined,
        BookKind.comic => Icons.auto_stories_outlined,
        BookKind.audio => Icons.headphones_outlined,
      }),
      title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(status, maxLines: 2, overflow: TextOverflow.ellipsis),
          if (task?.aggregationProgress case final progress?) Text(progress),
          if (task?.aggregationNotice case final notice?) Text(notice),
          if (item.blocked.isNotEmpty)
            Text('过滤跳过 ${item.blocked.length} 章，可在管理菜单复核'),
          if ((task?.failedChapters.length ?? item.failed.length) > 0)
            Text(
              '下载失败 ${task?.failedChapters.length ?? item.failed.length} 章，可在管理菜单重试',
            ),
          if (task != null && task.total > 0)
            LinearProgressIndicator(value: task.finished / task.total),
        ],
      ),
      onTap: () => _open(book),
      trailing: PopupMenuButton<String>(
        tooltip: '管理下载',
        enabled: !busy,
        onSelected: (action) {
          switch (action) {
            case 'failures':
              unawaited(_failureReport(item));
            case 'blocked':
              unawaited(_blockedReport(item));
            case 'pause':
              task?.pause();
            case 'resume' || 'resume_fallback':
              if (item.plan case final plan?) {
                _manager.start(
                  book,
                  item.entry.chapters,
                  action == 'resume_fallback' ? plan.withFallback() : plan,
                );
              }
            case 'remove':
              unawaited(_removePlan(book));
            case 'delete':
              unawaited(_deleteOffline(book));
          }
        },
        itemBuilder: (_) => [
          if (item.failed.isNotEmpty)
            const PopupMenuItem(value: 'failures', child: Text('失败章节与重试')),
          if (item.blocked.isNotEmpty)
            const PopupMenuItem(value: 'blocked', child: Text('过滤原因与章节复核')),
          if (task != null)
            const PopupMenuItem(value: 'pause', child: Text('暂停')),
          if (canResume)
            const PopupMenuItem(value: 'resume', child: Text('继续下载')),
          if (canResume &&
              !plan.fallback &&
              book.kind == BookKind.text &&
              book.sourceId != 'local')
            const PopupMenuItem(value: 'resume_fallback', child: Text('换源续传')),
          if (item.plan != null)
            const PopupMenuItem(value: 'remove', child: Text('移除下载计划')),
          if (count > 0)
            const PopupMenuItem(value: 'delete', child: Text('删除离线内容')),
        ],
      ),
    );
  }
}
