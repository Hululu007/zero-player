import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../supervision/presentation/sensitive_action.dart';

import '../../../app/app_services.dart';
import '../../../core/network/cancellation_token.dart';
import '../../../core/network/document_client.dart';
import '../../../core/network/source_certificate.dart';
import 'book_certificate_dialog.dart';
import '../../../core/platform/protected_book_export.dart';
import '../../supervision/domain/supervision_rules.dart';
import '../data/book_offline_export.dart';
import '../data/book_catalog_rebuild.dart';
import 'book_rebuild_dialog.dart';
import '../data/books_repository.dart';
import '../data/book_download_coordinator.dart';
import '../data/book_shelf_lists.dart';
import '../domain/book.dart';
import 'book_reader_page.dart';
import 'book_page_route.dart';
import 'books_page.dart';
import 'rich_reader_page.dart';
import 'book_cover.dart';
import 'book_edition_panel.dart';
import 'book_links.dart';
import 'audiobook_player_page.dart';
import 'book_download_dialog.dart';
import 'book_source_favorite.dart';
import 'book_text_policy_dialog.dart';
import 'book_blocked_chapters_dialog.dart';
import 'book_vault_dialogs.dart';
import 'book_vault_gate.dart';
import '../data/book_store.dart';
import '../data/book_site_check.dart';

part 'book_detail_catalog.dart';

final class BookDetailPage extends StatelessWidget {
  const BookDetailPage({
    super.key,
    required this.services,
    required this.initial,
    this.onSearchAuthor,
    this.onSearchTitle,
    this.onSourceFavorite,
  });
  final AppServices services;
  final Book initial;
  final ValueChanged<String>? onSearchAuthor;
  final ValueChanged<Book>? onSearchTitle;
  final void Function(String id, bool favorite)? onSourceFavorite;

  @override
  Widget build(BuildContext context) => BookVaultGate(
    store: services.books.store,
    bookId: initial.id,
    builder: (_) => _BookDetailContent(
      services: services,
      initial: initial,
      onSearchAuthor: onSearchAuthor,
      onSearchTitle: onSearchTitle,
      onSourceFavorite: onSourceFavorite,
    ),
  );
}

final class _BookDetailContent extends StatefulWidget {
  const _BookDetailContent({
    required this.services,
    required this.initial,
    this.onSearchAuthor,
    this.onSearchTitle,
    this.onSourceFavorite,
  });
  final AppServices services;
  final Book initial;
  final ValueChanged<String>? onSearchAuthor;
  final ValueChanged<Book>? onSearchTitle;
  final void Function(String id, bool favorite)? onSourceFavorite;

  @override
  State<_BookDetailContent> createState() => _BookDetailPageState();
}

final class _BookDetailPageState extends State<_BookDetailContent> {
  late Book _book = widget.initial;
  List<BookChapter> _chapters = [];
  List<BookChapter> _rebuilt = [];
  bool _showOriginalCatalog = false;
  List<BookChapter> get _readerCatalog =>
      !_showOriginalCatalog && _rebuilt.isNotEmpty ? _rebuilt : _chapters;
  Set<String> _saved = {};
  String? _last, _error;
  SourceCertificateFailure? _certificateError, _temporaryCertificate;
  String _chapterQuery = '';
  bool _favorite = false, _busy = false, _offline = false;
  bool _openingReader = false, _choosingDownload = false;
  bool _checkingDetails = false, _detailsBlocked = false;
  bool _policyReloadPending = false, _policyReloadScheduled = false;
  bool _reverse = false, _expanded = false, _following = false;
  double _position = 0;
  int _catalogOmitted = 0;
  DateTime? _chapterUpdatedAt;
  BookDownloadPlan? _plan;
  BookSourceEntry? _channel;
  bool _sourceUnavailable = false;
  bool _initialPositionApplied = false;
  bool _mutatingChannel = false;
  int _catalogPage = 0;

  void _updateCatalog(VoidCallback change) => setState(change);
  final _catalogScroll = ScrollController();
  final _catalogHeader = GlobalKey();
  static const _chapterExtent = 58.0;
  final _filter = TextEditingController();
  BookDownloadTask? _downloadTask;
  int _downloadGeneration = 0;
  CancellationToken? _token;
  late String _policySnapshot;
  BooksRepository get _books => widget.services.books;
  bool get _audio => _book.kind == BookKind.audio;
  bool get _comic => _book.kind == BookKind.comic;
  bool get _local => _book.sourceId == 'local';
  bool get _pageBookAllowed =>
      !_checkingDetails && !_detailsBlocked && _books.bookAllowed(_book);

  @override
  void initState() {
    super.initState();
    _policySnapshot = bookSitePolicySnapshot(_books.policy);
    _books.policy.addListener(_contentPolicyChanged);
    _books.sourceConfigurationChanges.addListener(_policyChanged);
    _books.bookPolicyChanges.addListener(_bookPolicyChanged);
    _downloadTask = widget.services.bookDownloads.active(_book);
    _downloadTask?.addListener(_downloadChanged);
    _saved.addAll(_downloadTask?.savedChapterIds ?? const {});
    _run(_load);
  }

  @override
  void dispose() {
    _token?.cancel();
    _downloadTask?.removeListener(_downloadChanged);
    _books.policy.removeListener(_contentPolicyChanged);
    _books.sourceConfigurationChanges.removeListener(_policyChanged);
    _books.bookPolicyChanges.removeListener(_bookPolicyChanged);
    _catalogScroll.dispose();
    _filter.dispose();
    super.dispose();
  }

  void _contentPolicyChanged() {
    final next = bookSitePolicySnapshot(_books.policy);
    final changed = next != _policySnapshot;
    _policySnapshot = next;
    // Pending detail observations still revoke on every policy notification.
    if (!changed && !_checkingDetails && _books.bookAllowed(_book)) return;
    _policyChanged();
  }

  void _policyChanged() {
    _token?.cancel();
    if (!mounted) return;
    if (!_local) {
      if (!_books.bookAllowed(_book)) _downloadTask?.pause();
      _policyReloadPending = true;
      setState(() => _checkingDetails = true);
      _queuePolicyReload();
    } else {
      setState(() {});
    }
  }

  void _bookPolicyChanged() {
    if (mounted) setState(() {});
  }

  void _queuePolicyReload() {
    if (!mounted ||
        _busy ||
        _mutatingChannel ||
        !_policyReloadPending ||
        _policyReloadScheduled) {
      return;
    }
    _policyReloadScheduled = true;
    scheduleMicrotask(() {
      _policyReloadScheduled = false;
      if (!mounted || _busy || !_policyReloadPending) return;
      _policyReloadPending = false;
      unawaited(_run(_load));
    });
  }

  void _attachDownloadTask(BookDownloadTask? task) {
    if (identical(_downloadTask, task)) return;
    _downloadGeneration++;
    _downloadTask?.removeListener(_downloadChanged);
    _downloadTask = task;
    task?.addListener(_downloadChanged);
    if (task != null) _saved.addAll(task.savedChapterIds);
    if (mounted) setState(() {});
  }

  void _downloadChanged() {
    final task = _downloadTask;
    if (task == null || !mounted) return;
    if (task.status == BookDownloadStatus.running) {
      setState(() {
        _saved.addAll(task.savedChapterIds);
        if (_chapters.length != task.chapters.length) {
          _chapters = List.of(task.chapters);
        }
      });
      return;
    }
    _attachDownloadTask(null);
    unawaited(_finishDownload(task));
  }

  Future<void> _finishDownload(BookDownloadTask task) async {
    final generation = _downloadGeneration;
    try {
      final saved = task.book.kind == BookKind.audio
          ? await _books.savedAudio(task.book)
          : task.book.kind == BookKind.comic
          ? await _books.store.savedImages(task.book)
          : await _books.store.savedText(task.book);
      final plan = BookDownloadPlan.fromJson(
        await _books.store.readBookValue(
          task.book,
          'books_download:${task.book.id}',
        ),
      );
      if (!mounted ||
          _book.id != task.book.id ||
          generation != _downloadGeneration) {
        return;
      }
      setState(() {
        _saved = saved;
        _chapters = List.of(task.chapters);
        _plan = plan;
      });
    } on Exception {
      if (mounted &&
          _book.id == task.book.id &&
          generation == _downloadGeneration) {
        _toast('下载状态读取失败，请刷新目录');
      }
      return;
    }
    switch (task.status) {
      case BookDownloadStatus.completed:
      case BookDownloadStatus.partial:
        _toast(
          '已保存 ${task.total - task.failures} 章，过滤跳过 ${task.blockedChapters.length} 章，其他失败 ${task.failures - task.blockedChapters.length} 章${task.failures > 0 ? '；可继续下载重试' : ''}'
          '${task.missingChapterIds.isEmpty ? '' : '。目录缺少 ${task.missingChapterIds.length} 个目标章节，计划已保留'}'
          '${task.aggregationNotice == null ? '' : '。${task.aggregationNotice}'}',
        );
        if (task.blockedChapters.isNotEmpty && mounted) {
          await showBlockedChaptersDialog(
            context,
            chapters: [
              for (final (index, chapter) in task.chapters.indexed)
                if (task.blockedChapters[chapter.id] case final block?)
                  (
                    position: index + 1,
                    reason: block.supervised ? '监管关键词命中' : '成人正文规则命中',
                    review: () => reviewBlockedChapter(context, _books, block),
                  ),
            ],
            replacements: () => showBookTextReplacements(context, _books),
          );
        }
      case BookDownloadStatus.paused:
        _toast(task.error ?? '下载已暂停');
      case BookDownloadStatus.failed:
        _toast(task.error ?? '下载未完成');
      case BookDownloadStatus.running:
        break;
    }
  }

  void _toast(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _run(Future<void> Function(CancellationToken) action) async {
    if (_busy) return;
    final token = _token = CancellationToken();
    setState(() {
      _busy = true;
      _error = null;
      _certificateError = null;
    });
    try {
      await action(token);
    } on BookExportCancelled {
      return;
    } on BookExportCleanupFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on BookExportInterrupted catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on FormatException catch (error) {
      if (mounted && !token.isCancelled) setState(() => _error = error.message);
    } on RemoteFailure catch (error) {
      if (mounted && !token.isCancelled) setState(() => _error = error.message);
    } on SourceCertificateFailure catch (error) {
      if (mounted && !token.isCancelled) {
        setState(() {
          _certificateError = error;
          _temporaryCertificate = null;
          _error = error.message;
        });
      }
    } catch (_) {
      if (mounted && !token.isCancelled) {
        setState(() => _error = '操作未完成，请检查来源或内容权限');
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          if (token.isCancelled && !_policyReloadPending) {
            _checkingDetails = false;
          }
        });
        _queuePolicyReload();
      }
    }
  }

  Future<void> _load(CancellationToken token, {bool refresh = false}) async {
    // Detail policy must settle before showing cached titles or starting a
    // chapter request. Local metadata can be read while it settles.
    final book = _book;
    final (allowed, existing, rawPlan) = await (
      _loadDetails(token),
      _books.store.entry(book),
      _books.store.readBookValue(book, 'books_download:${book.id}'),
    ).wait;
    if (!allowed || !mounted || token.isCancelled) return;
    final rebuilt = await BookCatalogRebuild(_books).catalog(book);
    if (!mounted || token.isCancelled) return;
    Object? catalogError;
    final (channel, chapters) = await (
      _local
          ? Future<BookSourceEntry?>.value()
          : _books.sourceEntry(book.kind, book.sourceId),
      _books
          .withTemporarySourceCertificate(
            _book.sourceId,
            _temporaryCertificate,
            () => _books.chapters(_book, token, refresh: refresh),
          )
          .onError((Exception error, _) {
            catalogError = error;
            return <BookChapter>[];
          }),
    ).wait;
    if (!mounted || token.isCancelled || !_pageBookAllowed) return;
    setState(() {
      _channel = channel;
      _rebuilt = rebuilt;
      _chapters = chapters.isEmpty ? existing?.chapters ?? [] : chapters;
      _last = existing?.last;
      _favorite = existing?.favorite ?? false;
      _following = existing?.following ?? false;
      _position = existing?.position ?? 0;
      _chapterUpdatedAt = existing?.chapterUpdatedAt;
      _catalogOmitted = existing?.catalogOmitted ?? 0;
      _plan = BookDownloadPlan.fromJson(rawPlan);
      _sourceUnavailable =
          !_local && (chapters.isEmpty || channel?.enabled != true);
    });
    if (!_initialPositionApplied && _chapters.isNotEmpty) {
      _initialPositionApplied = true;
      if (_last != null) _jumpToCurrent();
    }
    _attachDownloadTask(widget.services.bookDownloads.active(_book));
    final saved = _audio
        ? await _books.savedAudio(_book)
        : _comic
        ? await _books.store.savedImages(_book)
        : await _books.store.savedText(_book);
    if (!mounted || token.isCancelled) return;
    setState(
      () => _saved = saved..addAll(_downloadTask?.savedChapterIds ?? const {}),
    );
    if (refresh && chapters.isNotEmpty && existing != null) {
      token.check();
      if (existing.following) {
        await _books.store.updateFollowedChapters(_book, chapters);
      } else {
        await _books.store.updateShelfChapters(_book, chapters);
      }
      final savedCatalog = await _books.store.entry(_book);
      if (mounted && !token.isCancelled) {
        setState(() => _catalogOmitted = savedCatalog?.catalogOmitted ?? 0);
      }
    }
    if (catalogError case final Object error) throw error;
  }

  Future<bool> _loadDetails(CancellationToken token) async {
    if (_local) return true;
    if (mounted) setState(() => _checkingDetails = true);
    try {
      final details = await _books.withTemporarySourceCertificate(
        _book.sourceId,
        _temporaryCertificate,
        () => _books.details(_book, token),
      );
      token.check();
      if (!mounted) return false;
      setState(() {
        _book = details;
        _checkingDetails = false;
        _detailsBlocked = false;
      });
      return true;
    } on ContentBlocked {
      if (!mounted || token.isCancelled) return false;
      _downloadTask?.pause();
      setState(() {
        _checkingDetails = false;
        _detailsBlocked = true;
        _chapters = [];
        _rebuilt = [];
        _saved = {};
        _last = null;
        _plan = null;
      });
      return false;
    } on SourceCertificateFailure {
      if (mounted && !token.isCancelled) {
        setState(() => _checkingDetails = false);
      }
      rethrow;
    } on Exception {
      token.check();
      if (!mounted) return false;
      setState(() => _checkingDetails = false);
      // An ordinary network or parsing failure can use an existing offline
      // copy, but cannot undo an earlier explicit content-policy rejection.
      return !_detailsBlocked && _books.bookAllowed(_book);
    } catch (_) {
      if (mounted && !token.isCancelled) {
        setState(() => _checkingDetails = false);
      }
      rethrow;
    }
  }

  Future<void> _loadAfterCertificateConfirmation(
    SourceCertificateFailure failure,
  ) async {
    final book = _book;
    if (!await confirmBookCertificate(context, failure) ||
        !mounted ||
        _book.id != book.id ||
        !_books.canConfirmCertificate(book.sourceId, failure)) {
      return;
    }
    _temporaryCertificate = failure;
    await _run((token) => _load(token, refresh: true));
  }

  void _requirePageBook(Book book, [BookChapter? chapter]) {
    if (!_pageBookAllowed || _book.id != book.id) throw const ContentBlocked();
    if (chapter == null) {
      if (!_books.bookAllowed(book)) throw const ContentBlocked();
    } else {
      _books.requireBook(book, chapter);
    }
  }

  Future<void> _open(BookChapter chapter) async {
    if (_openingReader) return;
    _openingReader = true;
    final book = _book;
    Future<void> Function()? releaseDocument;
    try {
      _requirePageBook(book, chapter);
      if (_following) await _books.store.saveBook(book, clearUpdates: true);
      if (!mounted) return;
      final chapters = _readerCatalog
          .where((c) => _books.policy.textAllowed(c.title))
          .toList();
      Widget? reader;
      if (_local) {
        for (final extension in ['epub', 'pdf']) {
          final file = _books.documentFile(book, extension);
          if (await file.exists()) {
            releaseDocument = await _books.localBooks.holdDocument?.call(
              book,
              file,
            );
            reader = RichReaderPage(
              repository: _books,
              book: book,
              file: file,
              initial: chapter,
              platform: widget.services.platform,
            );
            break;
          }
        }
      }
      if (!mounted) return;
      _requirePageBook(book, chapter);
      reader ??= _audio
          ? AudiobookPlayerPage(
              services: widget.services,
              book: book,
              chapters: chapters,
              initial: chapter,
            )
          : BookReaderPage(
              repository: _books,
              book: book,
              chapters: chapters,
              initial: chapter,
              temporaryCertificate: _temporaryCertificate,
              platform: widget.services.platform,
            );
      final route = BookPageRoute<void>(
        builder: (_) => BookVaultGate(
          store: _books.store,
          bookId: book.id,
          builder: (_) => reader!,
        ),
      );
      await Navigator.of(context, rootNavigator: true).push(route);
      await route.completed;
      if (!mounted || _book.id != book.id || !_pageBookAllowed) return;
      final updated = await _books.store.entry(book);
      if (!mounted ||
          _book.id != book.id ||
          !_pageBookAllowed ||
          updated == null) {
        return;
      }
      setState(() {
        _last = updated.last;
        _position = updated.position;
        _favorite = updated.favorite;
        _following = updated.following;
      });
    } on FormatException catch (error) {
      _toast(error.message);
    } on Exception {
      _toast('无法打开电子书，请重试');
    } finally {
      _openingReader = false;
      await releaseDocument?.call();
    }
  }

  Future<void> _removeLocal() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除本地电子书'),
        content: const Text('删除旧书库的记录和阅读数据。图书库仍在使用的副本及阅读数据会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await _run((_) async {
      await _books.removeLocalBook(_book);
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> _exportOffline() => _run((token) async {
    final book = _book;
    final count = await BookOfflineExport(_books).save(
      book,
      _readerCatalog,
      token,
      visible: () => mounted && identical(_book, book) && _pageBookAllowed,
    );
    if (mounted) _toast('已导出 $count 章');
  });

  Future<void> _rebuildOffline() async {
    final book = _book;
    final rebuild = BookCatalogRebuild(_books);
    List<String> rules = [defaultChapterRule];
    await _run((token) async {
      rules = await rebuild.rules(book);
      token.check();
    });
    if (!mounted ||
        _book.id != book.id ||
        !_pageBookAllowed ||
        _busy ||
        _error != null) {
      return;
    }
    final selected = await showChapterRebuildRules(context, rules);
    if (!mounted || selected == null || _book.id != book.id) return;
    await _run((token) async {
      final entry = await _books.store.entry(book);
      if (entry == null) throw const FormatException('没有已下载的书架记录');
      final catalog = await rebuild.rebuild(
        entry,
        selected,
        token,
        available: () =>
            mounted &&
            _book.id == book.id &&
            _pageBookAllowed &&
            widget.services.bookDownloads.active(book) == null,
      );
      if (mounted) {
        setState(() {
          _rebuilt = catalog;
          _showOriginalCatalog = false;
          _catalogPage = 0;
        });
        _toast('已重建 ${catalog.length} 章');
      }
    });
  }

  Future<void> _changeSource() async {
    if (!_pageBookAllowed || _busy) return;
    final book = _book;
    final chosen = await showDialog<BookEdition>(
      context: context,
      useRootNavigator: false,
      builder: (context) => AlertDialog(
        title: const Text('选择其他可用渠道'),
        scrollable: true,
        content: SizedBox(
          width: 480,
          child: BookEditionPanel(
            repository: _books,
            book: book,
            busy: false,
            initialScan: true,
            includeCurrent: false,
            onSelected: (edition) => Navigator.pop(context, edition),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (!mounted ||
        chosen == null ||
        _book.id != book.id ||
        !_pageBookAllowed) {
      return;
    }
    await _run((token) => _switchEdition(chosen, token));
  }

  Future<void> _disableCurrentSource() async {
    final entry = _channel;
    if (entry == null || !entry.enabled || !_pageBookAllowed || _busy) return;
    final book = _book;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('停用当前渠道？'),
        content: Text('「${entry.source.name}」将从在线浏览和搜索中停用。之后可在渠道管理重新启用。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('停用并查找其他渠道'),
          ),
        ],
      ),
    );
    if (!mounted ||
        confirmed != true ||
        _book.id != book.id ||
        !_pageBookAllowed ||
        _busy) {
      return;
    }
    var changed = false;
    _mutatingChannel = true;
    try {
      await _run((_) async {
        changed = await runSensitive(
          context,
          widget.services.supervision,
          SensitiveOperation.channels,
          () => _books.setSourcesEnabled(book.kind, {book.sourceId}, false),
        );
        if (changed) await widget.services.bookDownloads.pause(book);
      });
    } finally {
      _mutatingChannel = false;
    }
    if (!mounted) return;
    if (!changed || _book.id != book.id) {
      _queuePolicyReload();
      return;
    }
    _policyReloadPending = false;
    await _run(_load);
    if (mounted && _book.id == book.id) await _changeSource();
  }

  Future<void> _switchEdition(
    BookEdition chosen,
    CancellationToken token,
  ) async {
    _requirePageBook(_book);
    final candidate = await _checkedEdition(chosen.book, token);
    token.check();
    if (!mounted) return;
    _requirePageBook(_book);
    final last = _chapters.where((chapter) => chapter.id == _last).firstOrNull;
    final next = last == null
        ? null
        : _books.matchingChapter(chosen.chapters, last);
    await _saveEdition(candidate, chosen.chapters, next, token);
    if (!mounted || token.isCancelled) return;
    setState(() {
      _book = candidate;
      _initialPositionApplied = false;
      _catalogPage = 0;
      _chapters = [];
      _rebuilt = [];
      _showOriginalCatalog = false;
      _plan = null;
      _chapterQuery = '';
      _filter.clear();
    });
    _attachDownloadTask(widget.services.bookDownloads.active(_book));
    await _load(token);
  }

  Future<void> _saveEdition(
    Book candidate,
    List<BookChapter> chapters,
    BookChapter? next,
    CancellationToken token,
  ) async {
    final store = _books.store;
    final before = _book;
    final private = await store.isPrivateBook(before.id);
    await store.db.atomic(() async {
      token.check();
      _requirePageBook(before);
      final candidatePrivate = await store.isPrivateBook(candidate.id);
      if (candidatePrivate && !private) {
        throw const FormatException('该版本在私密书架，请从私密书架打开');
      }
      if (private && !candidatePrivate) {
        if (await store.entry(candidate) != null) {
          throw const FormatException('该版本已在公开书架，可先移入私密书架后再切换');
        }
        await store.moveToVault(candidate);
      }
      if (!_favorite && next == null) return;
      final previous = await store.entry(before);
      token.check();
      await store.saveBook(
        candidate,
        chapters: chapters,
        preserveCatalog: true,
        favorite: _favorite ? true : null,
        last: next,
        position: next != null && !_audio ? previous?.position : null,
        clearPosition: next != null && _audio,
      );
      token.check();
    }, tables: {'app_meta'});
  }

  Future<Book> _checkedEdition(Book candidate, CancellationToken token) async {
    try {
      return await _books.details(candidate, token);
    } on ContentBlocked {
      rethrow;
    } on Exception {
      token.check();
      if (!_books.bookAllowed(candidate)) throw const ContentBlocked();
      return candidate;
    }
  }

  Future<void> _chooseDownload() async {
    if (!_pageBookAllowed || _choosingDownload) return;
    _choosingDownload = true;
    try {
      final book = _book;
      if (_catalogOmitted > 0 && !_local && !_sourceUnavailable) {
        await _run((token) async {
          final fresh = await _books.chapters(book, token, refresh: true);
          if (mounted &&
              !token.isCancelled &&
              identical(_book, book) &&
              fresh.isNotEmpty) {
            setState(() {
              _chapters = fresh;
              _catalogOmitted = 0;
            });
          }
        });
        if (!mounted || !identical(_book, book) || _catalogOmitted > 0) return;
      }
      final privateBook = await _books.store.isPrivateBook(book.id);
      final publicLists = await BookShelfLists(_books.store, book.kind).load();
      final privateLists = _books.store.vault.unlocked
          ? await BookShelfLists(_books.store, book.kind, private: true).load()
          : const <ShelfList>[];
      if (!mounted) return;
      final selection = await showBookDownloadDialog(
        context,
        _chapters.length,
        allowAggregateLatest: !_audio && !_comic,
        allowFallback: !_comic,
        publicLists: publicLists,
        privateLists: privateLists,
        loadPrivateLists: () async {
          if (!await ensureVaultAccess(context, _books.store) || !mounted) {
            return null;
          }
          return BookShelfLists(_books.store, book.kind, private: true).load();
        },
        initialSpace: privateBook
            ? BookShelfSpace.private
            : BookShelfSpace.public,
      );
      if (selection == null) return;
      if (!mounted || !identical(_book, book) || !_pageBookAllowed) return;
      if (!await _applyDownloadTarget(book, selection.target) || !mounted) {
        return;
      }
      if (!mounted || !identical(_book, book) || !_pageBookAllowed) return;
      await _download(selection.plan);
    } on Exception {
      _toast('下载设置未完成，请重试');
    } finally {
      _choosingDownload = false;
    }
  }

  Future<bool> _applyDownloadTarget(
    Book book,
    BookDownloadTarget target,
  ) async {
    final store = _books.store;
    try {
      if (target.isPrivate &&
          (!await ensureVaultAccess(context, store) || !mounted)) {
        return false;
      }
      await widget.services.bookDownloads.pause(book);
      if (!mounted || !identical(_book, book) || !_pageBookAllowed) {
        return false;
      }
      await store.saveDownloadTarget(
        book,
        private: target.isPrivate,
        chapters: _chapters.isEmpty ? null : _chapters,
        listId: target.listId,
      );
      if (mounted) setState(() => _favorite = true);
      return true;
    } on FormatException catch (error) {
      _toast(error.message);
      return false;
    } on Exception {
      _toast('无法保存到所选书架，请重试');
      return false;
    }
  }

  List<Widget> _downloadIndicators() {
    final task = _downloadTask;
    return [
      if (_busy || task != null)
        LinearProgressIndicator(
          value: task != null && task.total > 0
              ? task.finished / task.total
              : null,
        ),
      if (task?.preparation case final preparation?) Text(preparation),
      if (task?.aggregationProgress case final progress?) Text(progress),
      if (task?.aggregationNotice case final notice?) Text(notice),
    ];
  }

  Widget _downloadActions() => Wrap(
    spacing: 6,
    children: [
      if (_plan case final BookDownloadPlan plan)
        FilledButton.tonal(
          onPressed: _busy || _downloadTask != null
              ? null
              : () => _download(plan),
          child: const Text('继续下载'),
        ),
      if (_plan case final plan?
          when !plan.fallback && !_local && !_audio && !_comic)
        TextButton(
          onPressed: _busy || _downloadTask != null
              ? null
              : () => _download(plan.withFallback()),
          child: const Text('换源续传'),
        ),
      OutlinedButton(
        onPressed: _busy || _downloadTask != null ? null : _chooseDownload,
        child: const Text('离线下载'),
      ),
    ],
  );

  Future<void> _download(BookDownloadPlan plan, {bool keepPlan = true}) async {
    if (_busy || _downloadTask != null || !_pageBookAllowed) return;
    final task = widget.services.bookDownloads.start(
      _book,
      _chapters,
      plan,
      keepPlan: keepPlan,
    );
    _attachDownloadTask(task);
    if (keepPlan) setState(() => _plan = plan);
  }

  Future<void> _toggleFollowing() => _run((_) async {
    _requirePageBook(_book);
    await _books.store.saveBook(
      _book,
      chapters: _chapters,
      following: !_following,
      preserveCatalog: true,
    );
    if (mounted) setState(() => _following = !_following);
  });

  void _browseSource(String id) {
    final kind = _book.kind;
    Navigator.of(context).push(
      BookPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('渠道发现')),
          body: BooksPage(
            services: widget.services,
            kind: kind,
            discoverySourceId: id,
          ),
        ),
      ),
    );
  }

  Widget _workActions() => PopupMenuButton<String>(
    tooltip: '作品操作',
    enabled: !_busy,
    onSelected: (value) {
      if (!_pageBookAllowed) return;
      switch (value) {
        case 'copyBook':
          copyBookLink(context, _book.uri);
        case 'browseSource':
          if (_channel case final entry? when entry.enabled) {
            _browseSource(entry.source.id);
          }
        case 'copySource':
          final source = _channel?.source;
          if (source != null) copyBookLink(context, source.endpoint);
        case 'source':
          _changeSource();
        case 'disableSource':
          _disableCurrentSource();
        case 'refresh':
          _run((token) => _load(token, refresh: true));
      }
    },
    itemBuilder: (_) => [
      const PopupMenuItem(value: 'copyBook', child: Text('复制书籍网页链接')),
      if (_channel?.enabled == true)
        const PopupMenuItem(value: 'browseSource', child: Text('查看此渠道其他作品')),
      if (_channel != null)
        const PopupMenuItem(value: 'copySource', child: Text('复制渠道链接')),
      if (_channel?.enabled == true)
        const PopupMenuItem(value: 'disableSource', child: Text('停用当前渠道')),
      const PopupMenuItem(value: 'source', child: Text('换源')),
      const PopupMenuItem(value: 'refresh', child: Text('刷新目录')),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final last = _readerCatalog
        .where(
          (chapter) =>
              chapter.id == _last && _books.policy.textAllowed(chapter.title),
        )
        .firstOrNull;
    final first = _readerCatalog
        .where((chapter) => _books.policy.textAllowed(chapter.title))
        .firstOrNull;
    final visible = _visibleChapters;
    final page = _currentCatalogPage(visible.length);
    final pageChapters = visible
        .skip(page * _catalogPageSize)
        .take(_catalogPageSize)
        .toList();
    return Scaffold(
      appBar: _appBar(last != null, page, visible.length),
      floatingActionButton:
          !_checkingDetails && _pageBookAllowed && _chapters.isNotEmpty
          ? FloatingActionButton.small(
              heroTag: null,
              tooltip: '目录回到开头',
              onPressed: () => _locateChapter((_) => true),
              child: const Icon(Icons.vertical_align_top),
            )
          : null,
      body: _checkingDetails
          ? const Center(child: CircularProgressIndicator())
          : !_pageBookAllowed
          ? const Center(child: Text('当前内容策略限制访问此作品'))
          : CustomScrollView(
              controller: _catalogScroll,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    key: _catalogHeader,
                    children: [
                      ..._downloadIndicators(),
                      _summary(last, first),
                      if (!_local && !_audio && !_comic)
                        BookEditionPanel(
                          repository: _books,
                          book: _book,
                          busy: _busy,
                          onSelected: (edition) =>
                              _run((token) => _switchEdition(edition, token)),
                        ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Expanded(child: Text(_error!)),
                              TextButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () => _run(
                                        (token) => _load(token, refresh: true),
                                      ),
                                icon: const Icon(Icons.refresh),
                                label: const Text('重试加载'),
                              ),
                              if (_certificateError case final failure?
                                  when _books.canConfirmCertificate(
                                    _book.sourceId,
                                    failure,
                                  ))
                                TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _loadAfterCertificateConfirmation(
                                          failure,
                                        ),
                                  child: const Text('临时加载'),
                                ),
                            ],
                          ),
                        ),
                      if (_sourceUnavailable && !_busy) _sourceHelp(),
                      _directoryToolbar(),
                    ],
                  ),
                ),
                if (visible.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Text(
                        _busy
                            ? '正在读取目录…'
                            : _offline
                            ? '暂无离线章节'
                            : '暂无匹配章节',
                      ),
                    ),
                  )
                else
                  SliverFixedExtentList.builder(
                    itemExtent: _chapterExtent,
                    itemCount: pageChapters.length,
                    itemBuilder: (_, index) => _chapter(pageChapters[index]),
                  ),
                if (pageChapters.isNotEmpty)
                  const SliverToBoxAdapter(child: SizedBox(height: 64)),
              ],
            ),
    );
  }

  AppBar _appBar(bool hasLast, int page, int visibleCount) => AppBar(
    bottom: _pageBookAllowed && _chapters.isNotEmpty
        ? PreferredSize(
            preferredSize: const Size.fromHeight(48),
            child: _catalogNavigation(hasLast, page, visibleCount),
          )
        : null,
    title: Text(
      _pageBookAllowed ? _book.title : '书籍详情',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    actions: [
      if (_local && _pageBookAllowed)
        IconButton(
          tooltip: '移除本地电子书',
          onPressed: _busy ? null : _removeLocal,
          icon: const Icon(Icons.delete_outline),
        ),
      if (_busy || _downloadTask != null)
        IconButton(
          tooltip: _downloadTask != null ? '暂停下载' : '取消当前操作',
          onPressed: () {
            if (_downloadTask case final task?) {
              task.pause();
            } else {
              _token?.cancel();
            }
          },
          icon: const Icon(Icons.stop_circle_outlined),
        ),
      if (_pageBookAllowed && _chapters.isNotEmpty)
        IconButton(
          tooltip: '回到作品简介',
          onPressed: () => _scrollCatalogTo(0, immediate: true),
          icon: const Icon(Icons.info_outline),
        ),
      if (_pageBookAllowed && _channel != null)
        BookSourceFavorite(
          key: ValueKey(_channel!.source.id),
          repository: _books,
          entry: _channel!,
          onChanged: (value) {
            final entry = _channel;
            if (entry == null) return;
            setState(() => _channel = entry.withFavorite(value));
            widget.onSourceFavorite?.call(entry.source.id, value);
          },
        ),
      if (!_local && _pageBookAllowed && _channel?.enabled == true)
        IconButton(
          tooltip: '停用当前渠道',
          onPressed: _busy ? null : _disableCurrentSource,
          icon: const Icon(Icons.link_off),
        ),
      if (!_local && _pageBookAllowed) _workActions(),
    ],
  );

  Widget _sourceHelp() => ListTile(
    leading: const Icon(Icons.link_off),
    title: const Text('当前渠道暂不可用'),
    subtitle: const Text('可以换源继续阅读，或重试目录。'),
    trailing: TextButton(
      onPressed: widget.onSearchTitle == null
          ? _changeSource
          : () => widget.onSearchTitle!(_book),
      child: const Text('查找其他渠道'),
    ),
  );

  Widget _directoryToolbar() => Padding(
    padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(child: Text('目录 · ${_readerCatalog.length} 章')),
            TextButton.icon(
              icon: const Icon(Icons.sort),
              onPressed: () => setState(() {
                _reverse = !_reverse;
                _catalogPage = 0;
              }),
              label: Text(_reverse ? '倒序' : '正序'),
            ),
          ],
        ),
        if (_rebuilt.isNotEmpty)
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('重建目录')),
              ButtonSegment(value: true, label: Text('原目录')),
            ],
            selected: {_showOriginalCatalog},
            onSelectionChanged: (selected) => setState(() {
              _showOriginalCatalog = selected.single;
              _catalogPage = 0;
            }),
          ),
        if (_catalogOmitted > 0 && identical(_readerCatalog, _chapters))
          const Text('本地仅保留部分目录。可刷新目录重新加载；离线下载覆盖当前目录中的章节。'),
        if (_readerCatalog.length > 10)
          TextField(
            controller: _filter,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: '筛选章节',
              isDense: true,
            ),
            onChanged: (value) => setState(() {
              _chapterQuery = value.trim().toLowerCase();
              _catalogPage = 0;
            }),
          ),
      ],
    ),
  );

  Widget _summary(BookChapter? last, BookChapter? first) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _bookHeading(),
        if (_book.description.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            _book.description,
            maxLines: _expanded ? null : 3,
            overflow: _expanded ? null : TextOverflow.ellipsis,
          ),
          TextButton(
            onPressed: () => setState(() => _expanded = !_expanded),
            child: Text(_expanded ? '收起简介' : '展开简介'),
          ),
        ],
        if (_chapters.isNotEmpty || _book.latestChapter.isNotEmpty)
          Text(
            '最近章节  ${_book.latestChapter.isNotEmpty ? _book.latestChapter : _chapters.last.title}',
          ),
        if (last != null)
          Text(
            '当前进度  ${last.title}${_audio ? '' : ' · ${(_position.clamp(0, 1) * 100).round()}%'}',
          ),
        if (_book.rankLabel.isNotEmpty) Text('排行榜  第 ${_book.rankLabel} 名'),
        if (_book.updatedLabel.isNotEmpty) Text('更新时间  ${_book.updatedLabel}'),
        if (_book.updatedLabel.isEmpty && _chapterUpdatedAt != null)
          Text(
            '发现更新  ${MaterialLocalizations.of(context).formatShortDate(_chapterUpdatedAt!)}',
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (first != null)
              FilledButton.icon(
                onPressed: _busy ? null : () => _open(last ?? first),
                icon: Icon(_audio ? Icons.play_arrow : Icons.menu_book),
                label: Text(
                  last == null
                      ? (_audio ? '开始听书' : '开始阅读')
                      : '继续${_audio ? '听书' : '阅读'}',
                ),
              ),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run((token) async {
                      _requirePageBook(_book);
                      token.check();
                      await _books.store.saveBook(
                        _book,
                        chapters: _local || _chapters.isEmpty
                            ? null
                            : _chapters,
                        favorite: !_favorite,
                        preserveCatalog: true,
                      );
                      if (mounted) {
                        setState(() => _favorite = !_favorite);
                      }
                    }),
              icon: Icon(_favorite ? Icons.bookmark : Icons.bookmark_outline),
              label: Text(_favorite ? '已收藏' : '收藏'),
            ),
            FilterChip(
              label: const Text('仅离线'),
              selected: _offline,
              onSelected: (value) => setState(() => _offline = value),
            ),
            if (!_local)
              FilterChip(
                label: Text(_following ? '追更中' : '追更'),
                selected: _following,
                onSelected: _busy || _chapters.isEmpty
                    ? null
                    : (_) => _toggleFollowing(),
              ),
            if (!_local && _chapters.isNotEmpty) _downloadActions(),
            ..._storageActions(),
          ],
        ),
      ],
    ),
  );

  List<Widget> _storageActions() => [
    if (!_audio &&
        _saved.isNotEmpty &&
        (!_local || _book.documentFormat == 'txt'))
      OutlinedButton.icon(
        onPressed: _busy ? null : _exportOffline,
        icon: const Icon(Icons.file_download_outlined),
        label: Text(_comic ? '导出离线漫画' : '导出离线章节'),
      ),
    if (!_audio &&
        !_comic &&
        _saved.isNotEmpty &&
        (!_local || _book.documentFormat == 'txt'))
      OutlinedButton.icon(
        onPressed: _busy || _downloadTask != null ? null : _rebuildOffline,
        icon: const Icon(Icons.format_list_numbered),
        label: const Text('重建离线目录'),
      ),
    if (!_local && !_audio)
      TextButton.icon(
        onPressed: _busy
            ? null
            : () => _run((_) async {
                await _books.store.clearReadingCache(_book);
                _toast('已清理本书阅读缓存；离线下载保留');
              }),
        icon: const Icon(Icons.cleaning_services_outlined),
        label: const Text('清理阅读缓存'),
      ),
  ];

  Widget _bookHeading() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 64,
        height: 90,
        child: BookCover(book: _book, repository: _books),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_book.title, style: Theme.of(context).textTheme.titleLarge),
            if (_book.author.isNotEmpty)
              if (widget.onSearchAuthor != null)
                TextButton(
                  onPressed: () => widget.onSearchAuthor!(_book.author),
                  child: Text(_book.author),
                )
              else
                Text(_book.author),
            Text(
              [
                _book.category,
                _local ? '本地电子书' : _channel?.source.name ?? _book.uri.host,
                if (_chapters.isNotEmpty) '${_chapters.length} 章',
                if (_book.wordCount.isNotEmpty) '字数 ${_book.wordCount}',
              ].where((x) => x.isNotEmpty).join(' · '),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _chapter(BookChapter chapter) {
    final saved = _saved.contains(chapter.id);
    return ListTile(
      title: Text(chapter.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      selected: chapter.id == _last,
      onTap: _busy ? null : () => _open(chapter),
      trailing: _local || isRebuiltBookChapter(chapter)
          ? null
          : IconButton(
              tooltip: saved ? '删除离线章节' : '下载章节',
              icon: Icon(saved ? Icons.download_done : Icons.download_outlined),
              onPressed: _busy || _downloadTask != null
                  ? null
                  : saved
                  ? () => _run((token) async {
                      _requirePageBook(_book, chapter);
                      token.check();
                      if (_audio) {
                        await _books.removeSavedAudio(_book, chapter: chapter);
                      } else if (_comic) {
                        await _books.store.deleteImages(_book, chapter);
                      } else {
                        await _books.store.deleteText(_book, chapter);
                      }
                      if (mounted) {
                        setState(() {
                          _saved.remove(chapter.id);
                          _rebuilt = [];
                        });
                      }
                    })
                  : () {
                      final index = _chapters.indexOf(chapter) + 1;
                      _download(
                        BookDownloadPlan(index, index, false),
                        keepPlan: false,
                      );
                    },
            ),
    );
  }
}
