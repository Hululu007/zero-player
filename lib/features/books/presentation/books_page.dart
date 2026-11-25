import '../data/book_catalog_window.dart';
import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../app/app_services.dart';
import '../../../core/network/cancellation_token.dart';
import '../data/book_store.dart';
import '../data/book_source_groups.dart';
import '../domain/book.dart';
import '../domain/book_search.dart';
import 'book_shelf_view.dart';
import 'book_detail_page.dart';
import 'book_download_management_page.dart';
import 'book_discovery_view.dart';
import '../data/qidian_catalog.dart';
import 'book_page_route.dart';
import 'book_search_page.dart';
import 'book_sources_page.dart';
import 'book_vault_dialogs.dart';
import 'private_shelf_page.dart';
import 'book_vault_gate.dart';

final class BooksPage extends StatefulWidget {
  const BooksPage({
    super.key,
    required this.services,
    required this.kind,
    this.initialTab = 0,
    this.libraryMode,
    this.discoverySourceId,
    this.onOpenModule,
  });
  final AppServices services;
  final BookKind kind;
  final int initialTab;
  final String? libraryMode;
  final String? discoverySourceId;
  final ValueChanged<BookKind>? onOpenModule;

  @override
  State<BooksPage> createState() => _BooksPageState();
}

final class _BooksPageState extends State<BooksPage> {
  List<BookSourceEntry>? _sources;
  List<BookSourceGroup> _sourceGroups = const [];
  List<BookShelfEntry> _shelf = [];
  late int _tab = widget.initialTab;
  int _reloadSequence = 0;
  String? _error;
  CancellationToken? _followToken;
  bool _checking = false;
  bool _active = true;
  bool _openingBook = false;
  Set<String> _downloadIds = {};
  late var _policy = _policyState;

  AppServices get _services => widget.services;
  Object get _policyState => (
    _services.contentPolicy.filterAdult,
    _services.supervision.enabled,
    _services.supervision.corrupted,
    _services.supervision.rules,
  );

  @override
  void initState() {
    super.initState();
    _policy = _policyState;
    _services.contentPolicy.addListener(_policyChanged);
    _services.books.sourceRiskChanges.addListener(_sourceRiskChanged);
    _downloadIds = _services.bookDownloads.activeTasks
        .map((task) => task.book.id)
        .toSet();
    _services.bookDownloads.addListener(_downloadsChanged);
    unawaited(_reload());
  }

  void _downloadsChanged() {
    if (!mounted) return;
    final ids = _services.bookDownloads.activeTasks
        .map((task) => task.book.id)
        .toSet();
    if (ids.length == _downloadIds.length && _downloadIds.containsAll(ids)) {
      return;
    }
    _downloadIds = ids;
    unawaited(_reloadShelf());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TickerMode.valuesOf(context).enabled;
    if (active && !_active) unawaited(_reload());
    _active = active;
  }

  void _policyChanged() {
    final policy = _policyState;
    if (_policy == policy) {
      // A backup restore can change stored channels without changing policy.
      // The source comparison in _reload preserves the discovery view.
      if (_active) unawaited(_reload());
      return;
    }
    _policy = policy;
    _followToken?.cancel();
    setState(() {
      _sources = null;
      _shelf = [];
    });
    unawaited(_reload());
  }

  void _sourceRiskChanged() {
    _followToken?.cancel();
    if (!mounted) return;
    setState(() {
      _sources = null;
      _shelf = _visibleShelf(_shelf);
    });
    if (_active) unawaited(_reload());
  }

  List<BookShelfEntry> _visibleShelf(List<BookShelfEntry> entries) => entries
      .where(
        (entry) =>
            entry.book.kind == widget.kind &&
            (widget.libraryMode != 'history' || entry.last != null) &&
            _services.books.bookAllowed(entry.book),
      )
      .toList();

  Future<void> _reload() async {
    final sequence = ++_reloadSequence;
    try {
      final sources = await _services.books.sources(
        widget.kind,
        enabledOnly: true,
      );
      final groups = await BookSourceGroups(
        _services.books.store,
        widget.kind,
      ).load();
      final shelf = await _readShelf();
      if (!mounted || sequence != _reloadSequence) return;
      setState(() {
        if (_sources == null ||
            !sameBookDiscoverySources(
              sources,
              _sources!,
              includeFavorites: true,
            )) {
          _sources = sources;
        }
        _shelf = _visibleShelf(shelf);
        _sourceGroups = groups;
        _error = null;
      });
      unawaited(_checkFollowing());
      unawaited(_seedCatalog());
    } on Exception {
      if (mounted && sequence == _reloadSequence) {
        setState(() => _error = '无法打开书库');
      }
    }
  }

  Future<void> _seedCatalog() async {
    try {
      await _services.books.ensureCatalog();
    } on Exception {
      // Source management retries the import and can display the error.
    }
  }

  Future<List<BookShelfEntry>> _readShelf() async {
    await _services.books.ensureSourceRiskLoaded();
    final shelf = _visibleShelf(await _services.books.store.shelf());
    if (widget.libraryMode != 'downloads') return shelf;
    final downloaded = <BookShelfEntry>[];
    for (final entry in shelf) {
      final saved = entry.book.kind == BookKind.audio
          ? await _services.books.savedAudio(entry.book)
          : entry.book.kind == BookKind.comic
          ? await _services.books.store.savedImages(entry.book)
          : await _services.books.store.savedText(entry.book);
      if (saved.isNotEmpty) downloaded.add(entry);
    }
    return downloaded;
  }

  Future<void> _reloadShelf() async {
    final shelf = await _readShelf();
    if (mounted) setState(() => _shelf = _visibleShelf(shelf));
  }

  Future<void> _checkFollowing() async {
    if (_checking || !_shelf.any((entry) => entry.following)) return;
    final token = _followToken = CancellationToken();
    setState(() => _checking = true);
    try {
      await _services.books.checkFollowing(widget.kind, token);
      if (mounted && !token.isCancelled) await _reloadShelf();
    } on BookCatalogCapacityExceeded catch (error) {
      if (mounted && !token.isCancelled) {
        await _reloadShelf();
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$error')));
        }
      }
    } on Exception {
      // A temporary failure leaves the cached catalog and update badges intact.
    } finally {
      if (mounted && identical(_followToken, token)) {
        setState(() => _checking = false);
      }
    }
  }

  Future<void> _checkShelfUpdates(List<BookShelfEntry> entries) async {
    _followToken?.cancel();
    final token = _followToken = CancellationToken();
    setState(() => _checking = true);
    try {
      await _services.books.checkShelfUpdates(entries, token);
      if (mounted && !token.isCancelled) await _reloadShelf();
    } on BookCatalogCapacityExceeded catch (error) {
      if (mounted && !token.isCancelled) {
        await _reloadShelf();
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$error')));
        }
      }
    } on Exception {
      // Leave cached entries visible if one or more sources fail.
    } finally {
      if (mounted && identical(_followToken, token)) {
        setState(() => _checking = false);
      }
    }
  }

  Future<void> _openDownloads() async {
    await Navigator.of(context).push(
      BookPageRoute<void>(
        builder: (_) => BookDownloadManagementPage(
          services: _services,
          initialKind: widget.kind,
        ),
      ),
    );
    if (mounted) await _reloadShelf();
  }

  Future<void> _openPrivateShelf() async {
    final store = _services.books.store;
    if (!await ensureVaultAccess(context, store, reauthenticate: true) ||
        !mounted) {
      return;
    }
    await Navigator.of(context).push(
      BookPageRoute<void>(
        builder: (_) => BookVaultGate(
          store: store,
          private: true,
          builder: (_) =>
              PrivateShelfPage(services: _services, kind: widget.kind),
        ),
      ),
    );
    if (mounted) await _reloadShelf();
  }

  void _followChanged() {
    unawaited(
      _reloadShelf().then((_) {
        if (mounted) return _checkFollowing();
      }),
    );
  }

  Future<void> _searchBook(Book book, {bool direct = false}) {
    if (book.sourceId == qidianRecommendationId) {
      if (!_services.books.qidian.allows(book)) return Future.value();
      return _search(
        book.title,
        field: BookSearchField.title,
        skipQidian: true,
      );
    }
    if (!_services.books.bookAllowed(book)) return Future.value();
    return direct
        ? _open(book)
        : _search(book.title, preferred: book, field: BookSearchField.title);
  }

  Future<void> _search(
    String query, {
    Book? preferred,
    BookSearchField field = BookSearchField.all,
    String? sourceId,
    String? sourceGroupId,
    bool favorites = false,
    String? excludedSource,
    bool skipQidian = false,
  }) async {
    await Navigator.of(context).push(
      BookPageRoute<void>(
        builder: (_) => BookSearchPage(
          repository: _services.books,
          kind: widget.kind,
          query: query,
          preferred: preferred,
          field: field,
          sourceId: sourceId,
          sourceGroupId: sourceGroupId,
          favoritesOnly: favorites,
          excludedSource: excludedSource,
          skipQidian: skipQidian,
          onSourceFavorite: _sourceFavoriteChanged,
          onOpen: _open,
        ),
      ),
    );
  }

  Future<void> _open(Book book) async {
    if (!mounted || !_services.books.bookAllowed(book)) return;
    await Navigator.of(context).push(_detailRoute(book));
    if (!mounted) return;
    await _reloadShelf();
    if (mounted) unawaited(_checkFollowing());
  }

  BookPageRoute<void> _detailRoute(Book book) => BookPageRoute<void>(
    builder: (_) => BookDetailPage(
      services: _services,
      initial: book,
      onSearchAuthor: (author) =>
          _search(bookAuthorName(author), field: BookSearchField.author),
      onSearchTitle: (book) => _search(
        book.title,
        field: BookSearchField.title,
        excludedSource: book.sourceId,
      ),
      onSourceFavorite: _sourceFavoriteChanged,
    ),
  );

  void _sourceFavoriteChanged(String id, bool favorite) {
    final sources = _sources;
    if (sources == null || !mounted) return;
    setState(
      () => _sources = [
        for (final entry in sources)
          entry.source.id == id ? entry.withFavorite(favorite) : entry,
      ],
    );
  }

  Future<void> _manageSources() async {
    await Navigator.of(context).push(
      BookPageRoute<void>(
        builder: (_) => BookSourcesPage(services: _services, kind: widget.kind),
      ),
    );
    if (mounted) await _reload();
  }

  Future<void> _import() async {
    if (_openingBook) return;
    _openingBook = true;
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: '电子书',
            extensions: ['txt', 'epub', 'pdf'],
            mimeTypes: [
              'text/plain',
              'application/epub+zip',
              'application/pdf',
            ],
          ),
        ],
      );
      if (file == null || !mounted) return;
      final book = await _services.books.importLocal(File(file.path));
      if (mounted) await _open(book);
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法导入，请检查 TXT、EPUB 或 PDF 的格式、大小和内容权限。')),
        );
      }
    } finally {
      _openingBook = false;
    }
  }

  @override
  void dispose() {
    _followToken?.cancel();
    _services.bookDownloads.removeListener(_downloadsChanged);
    _services.contentPolicy.removeListener(_policyChanged);
    _services.books.sourceRiskChanges.removeListener(_sourceRiskChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_services.books.kindAllowed(widget.kind)) {
      return const Center(child: Text('当前内容策略限制访问此模块'));
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1400),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            Expanded(
              child: _error != null
                  ? Center(
                      child: TextButton.icon(
                        onPressed: _reload,
                        icon: const Icon(Icons.refresh),
                        label: Text('$_error，重试'),
                      ),
                    )
                  : IndexedStack(
                      index: _tab,
                      children: [
                        BookDiscoveryView(
                          repository: _services.books,
                          kind: widget.kind,
                          sources: _sources,
                          sourceGroups: _sourceGroups,
                          initialSourceId: widget.discoverySourceId,
                          active: _tab == 0,
                          onOpen: _searchBook,
                          onSearch: (query, sourceId, favorites) => _search(
                            query,
                            sourceId: sourceId,
                            favorites: favorites,
                          ),
                          onGroupSearch:
                              (query, groupId, favorites, {preferred}) =>
                                  _search(
                                    query,
                                    sourceGroupId: groupId,
                                    favorites: favorites,
                                    preferred: preferred,
                                    field: preferred == null
                                        ? BookSearchField.all
                                        : BookSearchField.title,
                                  ),
                          onSourceFavorite: _sourceFavoriteChanged,
                          onManage: _manageSources,
                        ),
                        BookShelfView(
                          historyMode: widget.libraryMode == 'history',
                          repository: _services.books,
                          kind: widget.kind,
                          entries: _shelf,
                          onOpen: _open,
                          checking: _checking,
                          onRefresh: _checkFollowing,
                          onCheckUpdates: _checkShelfUpdates,
                          onFollowChanged: _followChanged,
                          onOpenPrivate: _openPrivateShelf,
                          downloads: _services.bookDownloads,
                          pauseDownload: _services.bookDownloads.pause,
                          cancelDownload: (book) =>
                              _services.bookDownloads.removePlan(book),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _readingActions() => [
    IconButton(
      tooltip: '导入 EPUB / PDF / TXT',
      icon: const Icon(Icons.upload_file_outlined),
      onPressed: _import,
    ),
    if (_services.books.kindAllowed(BookKind.comic))
      IconButton(
        tooltip: '网络漫画',
        icon: const Icon(Icons.collections_bookmark_outlined),
        onPressed: () => _openModule(BookKind.comic),
      ),
    if (_services.books.kindAllowed(BookKind.audio))
      IconButton(
        tooltip: '网络听书',
        icon: const Icon(Icons.headphones_outlined),
        onPressed: () => _openModule(BookKind.audio),
      ),
  ];

  void _openModule(BookKind kind) {
    if (!_services.books.kindAllowed(kind)) return;
    if (widget.onOpenModule case final open?) {
      open(kind);
      return;
    }
    Navigator.of(context).push(
      BookPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(kind == BookKind.comic ? '网络漫画' : '听书')),
          body: BooksPage(services: _services, kind: kind),
        ),
      ),
    );
  }

  String get _moduleTitle => switch (widget.kind) {
    BookKind.text => '网络小说',
    BookKind.comic => '网络漫画',
    BookKind.audio => '听书',
  };

  Widget _header() => LayoutBuilder(
    builder: (context, constraints) {
      final theme = Theme.of(context);
      final compact = constraints.maxWidth < 620;
      final title = Text(
        _moduleTitle,
        style: theme.textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      );
      final tabs = SegmentedButton<int>(
        segments: [
          ButtonSegment(
            value: 0,
            label: const Text('发现'),
            icon: compact ? null : const Icon(Icons.explore_outlined),
          ),
          ButtonSegment(
            value: 1,
            label: const Text('书架'),
            icon: compact
                ? null
                : const Icon(Icons.collections_bookmark_outlined),
          ),
        ],
        selected: {_tab},
        showSelectedIcon: false,
        onSelectionChanged: (value) {
          setState(() => _tab = value.first);
          if (_tab == 1) unawaited(_checkFollowing());
        },
      );
      final sourceButton = IconButton(
        tooltip: '源管理',
        onPressed: _manageSources,
        icon: const Icon(Icons.tune),
      );
      final downloadButton = IconButton(
        tooltip: '书籍下载管理',
        onPressed: _openDownloads,
        icon: const Icon(Icons.download_outlined),
      );
      final readingActions =
          widget.kind == BookKind.text &&
              widget.libraryMode == null &&
              widget.discoverySourceId == null
          ? _readingActions()
          : const <Widget>[];
      return Padding(
        padding: EdgeInsets.fromLTRB(
          compact ? 12 : 26,
          compact ? 4 : 12,
          compact ? 12 : 26,
          compact ? 4 : 8,
        ),
        child:
            compact && readingActions.isNotEmpty && widget.onOpenModule == null
            ? Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  tabs,
                  ...readingActions,
                  downloadButton,
                  sourceButton,
                ],
              )
            : compact
            ? Row(
                children: [
                  Expanded(
                    child: Align(alignment: Alignment.centerLeft, child: tabs),
                  ),
                  ...readingActions,
                  if (widget.onOpenModule == null) ...[
                    downloadButton,
                    sourceButton,
                  ],
                ],
              )
            : Row(
                children: [
                  title,
                  const SizedBox(width: 24),
                  tabs,
                  const Spacer(),
                  ...readingActions,
                  if (widget.onOpenModule == null) downloadButton,
                  if (widget.onOpenModule == null)
                    OutlinedButton.icon(
                      onPressed: _manageSources,
                      icon: const Icon(Icons.tune),
                      label: const Text('源管理'),
                    ),
                ],
              ),
      );
    },
  );
}
