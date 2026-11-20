import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/network/cancellation_token.dart';
import '../data/book_store.dart';
import '../data/books_repository.dart';
import '../domain/book.dart';
import '../domain/book_search.dart';
import 'book_cover.dart';
import 'book_links.dart';
import 'book_source_favorite.dart';

final _bookUpdateDate = RegExp(
  r'(20\d{2})[-/年.](\d{1,2})[-/月.](\d{1,2})(?:日)?(?:\s+(\d{1,2}):(\d{2}))?',
);
final _bookChapterNumber = RegExp(r'第\s*(\d+)\s*[章节回话]');

int compareBookChapterFreshness(Book a, Book b) {
  int date(String value) {
    final match = _bookUpdateDate.firstMatch(value);
    if (match == null) return 0;
    return int.parse(match[1]!) * 100000000 +
        int.parse(match[2]!) * 1000000 +
        int.parse(match[3]!) * 10000 +
        (int.tryParse(match[4] ?? '') ?? 0) * 100 +
        (int.tryParse(match[5] ?? '') ?? 0);
  }

  final dates = date(b.updatedLabel).compareTo(date(a.updatedLabel));
  if (dates != 0) return dates;
  int chapter(String value) {
    final match = _bookChapterNumber.firstMatch(value);
    return int.tryParse(match?[1] ?? '') ?? 0;
  }

  return chapter(b.latestChapter).compareTo(chapter(a.latestChapter));
}

class BookSearchPage extends StatefulWidget {
  const BookSearchPage({
    super.key,
    required this.repository,
    required this.kind,
    required this.query,
    required this.onOpen,
    this.preferred,
    this.field = BookSearchField.all,
    this.sourceId,
    this.favoritesOnly = false,
    this.excludedSource,
    this.skipQidian = false,
    this.onSourceFavorite,
    this.onSearchStarted,
    this.beforeSourceSnapshotForTesting,
  });

  final BooksRepository repository;
  final BookKind kind;
  final String query;
  final Book? preferred;
  final BookSearchField field;
  final String? sourceId;
  final bool favoritesOnly;
  final String? excludedSource;
  final bool skipQidian;
  final void Function(String id, bool favorite)? onSourceFavorite;
  final Future<void> Function(Book) onOpen;
  @visibleForTesting
  final VoidCallback? onSearchStarted;
  @visibleForTesting
  final VoidCallback? beforeSourceSnapshotForTesting;

  @override
  State<BookSearchPage> createState() => _BookSearchPageState();
}

class _BookSearchPageState extends State<BookSearchPage> {
  final _results = <String, Book>{};
  Timer? _progressRefresh;
  final _sources = <String, BookSourceEntry>{};
  final _latencies = <String, int>{};
  final _failedSources = <String>{};
  final _certificateFailures = <String>{};
  late final _input = TextEditingController(text: widget.query);
  late String _query = widget.query;
  late BookSearchField _field = widget.field;
  late bool _scoped = widget.sourceId != null || widget.favoritesOnly;
  CancellationToken? _token;
  bool _busy = false;
  int _done = 0, _total = 0;
  bool _retrying = false;
  bool _cancelled = false;
  bool _metadataStale = false;
  bool _searchStarted = false;
  bool _restartPending = false;
  int _policyRevision = 0;
  Set<String>? _runningRetry;
  String? _error;
  Book? get _preferred => _query == widget.query && _field == widget.field
      ? widget.preferred
      : null;

  @override
  void initState() {
    super.initState();
    widget.repository.policy.addListener(_policyChanged);
    widget.repository.sourceRiskChanges.addListener(_policyChanged);
    if (!widget.repository.policy.textAllowed(_input.text)) _input.clear();
    unawaited(_load());
  }

  void _policyChanged() {
    if (!mounted) return;
    final revision = ++_policyRevision;
    final pendingStart = _busy && !_searchStarted;
    _token?.cancel();
    if (!widget.repository.policy.textAllowed(_input.text)) _input.clear();
    setState(() {
      _metadataStale = true;
      _restartPending = pendingStart;
      if (_busy && !pendingStart) {
        _busy = false;
        _retrying = false;
        _cancelled = true;
      }
    });
    _updates.value++;
    unawaited(_refreshPolicySources(revision));
  }

  Future<void> _refreshPolicySources(int revision) async {
    if (widget.repository.sourceRiskMutationPending) return;
    final previous = Map<String, BookSourceEntry>.of(_sources);
    try {
      final current = await widget.repository.sources(
        widget.kind,
        enabledOnly: true,
      );
      if (!mounted ||
          revision != _policyRevision ||
          widget.repository.sourceRiskMutationPending) {
        return;
      }
      final allowed = <String, BookSourceEntry>{};
      for (final entry in current) {
        final old = previous[entry.source.id];
        if (old != null && sameBookDiscoverySources([old], [entry])) {
          allowed[entry.source.id] = entry;
        }
      }
      final restart = _restartPending;
      final retry = _runningRetry == null
          ? null
          : Set<String>.of(_runningRetry!);
      setState(() {
        _sources
          ..clear()
          ..addAll(allowed);
        _metadataStale = false;
        if (restart &&
            (!widget.repository.policy.textAllowed(_query) ||
                !widget.repository.kindAllowed(widget.kind))) {
          _restartPending = false;
          _busy = false;
          _retrying = false;
          _cancelled = true;
        }
      });
      _updates.value++;
      if (restart && _restartPending) {
        _restartPending = false;
        unawaited(_load(retry: retry));
      }
    } on Exception {
      // A suspended or unavailable policy snapshot stays hidden until the
      // next notification; no stale source metadata is exposed meanwhile.
    }
  }

  void _submit() {
    final query = _input.text.trim();
    if (query.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    _query = query;
    if (!widget.repository.policy.textAllowed(query)) _input.clear();
    unawaited(_load());
  }

  Future<void> _load({Set<String>? retry}) async {
    _policyRevision++;
    _token?.cancel();
    final token = _token = CancellationToken();
    final repository = widget.repository;
    final preferred = _preferred;
    setState(() {
      if (retry == null) {
        _results.clear();
        _sources.clear();
        _latencies.clear();
        _failedSources.clear();
        _certificateFailures.clear();
        _done = _total = 0;
      }
      _busy = true;
      _retrying = retry != null;
      _cancelled = false;
      _searchStarted = false;
      _restartPending = false;
      _runningRetry = retry == null ? null : Set.of(retry);
      _error = null;
    });
    _updates.value++;
    if (repository.sourceRiskMutationPending) {
      // Continue the explicit request only after the current mutation settles.
      _restartPending = true;
      return;
    }
    try {
      final availableSources = await _loadSources(
        token,
        preferred,
        retry: retry,
      );
      final retried = <String>{};
      await repository.find(
        widget.kind,
        _query,
        token,
        field: _field,
        sourceId: _scoped ? widget.sourceId : null,
        sourceIds: retry,
        favorites: _scoped && widget.favoritesOnly,
        preferredSource: preferred?.sourceId,
        excludedSource: widget.excludedSource,
        skipQidian: widget.skipQidian,
        availableSources: availableSources,
        onProgress: (update) {
          if (update.sourceId case final String id) retried.add(id);
          _update(update, token, retrying: retry != null);
        },
      );
      if (mounted && !token.isCancelled && retry != null) {
        setState(() {
          final removed = retry.difference(retried);
          _failedSources.removeAll(removed);
          _certificateFailures.removeAll(removed);
        });
      }
    } on FormatException catch (error) {
      if (mounted && !token.isCancelled) setState(() => _error = error.message);
    } on Exception {
      if (mounted && !token.isCancelled) setState(() => _error = '搜索未完成，请重试');
    } finally {
      if (mounted && identical(token, _token)) {
        _progressRefresh?.cancel();
        _progressRefresh = null;
        setState(() {
          if (!_restartPending) _busy = false;
        });
        _updates.value++;
      }
    }
  }

  Future<List<BookSourceEntry>> _loadSources(
    CancellationToken token,
    Book? preferred, {
    required Set<String>? retry,
  }) async {
    final repository = widget.repository;
    widget.beforeSourceSnapshotForTesting?.call();
    final sources = await repository.sources(widget.kind, enabledOnly: true);
    token.check();
    if (!mounted) return sources;
    setState(() {
      if (retry == null) {
        _sources
          ..clear()
          ..addEntries(
            sources.map((entry) => MapEntry(entry.source.id, entry)),
          );
      } else {
        final previous = Map<String, BookSourceEntry>.of(_sources);
        final retained = <String, BookSourceEntry>{};
        for (final entry in sources) {
          final id = entry.source.id;
          final old = previous[id];
          if (retry.contains(id)) {
            if (old == null || !sameBookDiscoverySources([old], [entry])) {
              _results.removeWhere((_, book) => book.sourceId == id);
            }
            retained[id] = entry;
          } else if (old != null && sameBookDiscoverySources([old], [entry])) {
            retained[id] = entry;
          }
        }
        _sources
          ..clear()
          ..addAll(retained);
        _results.removeWhere((_, book) => !_sources.containsKey(book.sourceId));
        _latencies.removeWhere((id, _) => !_sources.containsKey(id));
      }
      _metadataStale = false;
      if (retry == null &&
          preferred != null &&
          _sources.containsKey(preferred.sourceId) &&
          repository.bookAllowed(preferred)) {
        _results[preferred.id] = preferred;
      }
    });
    _updates.value++;
    return sources;
  }

  void _update(
    BookSearchUpdate update,
    CancellationToken token, {
    required bool retrying,
  }) {
    if (!mounted || token.isCancelled) return;
    if (update.sourceId == null) _searchStarted = true;
    if (!retrying) {
      _done = update.completed;
      _total = update.total;
    }
    final id = update.sourceId;
    if (id == null) {
      setState(() {});
      widget.onSearchStarted?.call();
      return;
    }
    if (update.failed) {
      _failedSources.add(id);
    } else {
      _failedSources.remove(id);
    }
    if (update.certificateFailed) {
      _certificateFailures.add(id);
    } else {
      _certificateFailures.remove(id);
    }
    final latency = update.latencyMs;
    if (latency != null) _latencies[id] = latency;
    for (final book in update.books) {
      _results[book.id] = book;
    }
    _progressRefresh ??= Timer(const Duration(milliseconds: 80), () {
      _progressRefresh = null;
      if (!mounted || !identical(token, _token) || token.isCancelled) return;
      setState(() {});
      _updates.value++;
    });
  }

  void _retryFailed() {
    if (_busy || _failedSources.isEmpty) return;
    unawaited(_load(retry: Set.of(_failedSources)));
  }

  void _cancelSearch() {
    _progressRefresh?.cancel();
    _progressRefresh = null;
    _token?.cancel();
    setState(() {
      _busy = false;
      _cancelled = true;
      _restartPending = false;
    });
  }

  int _compareSources(Book a, Book b) {
    final preferred = _preferred?.sourceId;
    if (preferred != null && a.sourceId == preferred) {
      return b.sourceId == preferred ? 0 : -1;
    }
    if (preferred != null && b.sourceId == preferred) return 1;
    final favorite = (_sources[b.sourceId]?.favorite == true ? 1 : 0).compareTo(
      _sources[a.sourceId]?.favorite == true ? 1 : 0,
    );
    if (favorite != 0) return favorite;
    final freshness = compareBookChapterFreshness(a, b);
    if (freshness != 0) return freshness;
    const unknownLatency = 1 << 30;
    final time = (_latencies[a.sourceId] ?? unknownLatency).compareTo(
      _latencies[b.sourceId] ?? unknownLatency,
    );
    return time != 0 ? time : a.id.compareTo(b.id);
  }

  List<List<Book>> _groups() {
    final groups = <String, List<Book>>{};
    final ranks = <String, int>{};
    final query = BookSearchQuery(_query, _field);
    for (final book in _results.values.where(_visibleBook)) {
      final title = book.title.trim();
      (groups[title] ??= []).add(book);
      final rank = query.rank(book) ?? 99;
      if (rank < (ranks[title] ?? 100)) ranks[title] = rank;
    }
    final titles = groups.keys.toList()
      ..sort((a, b) {
        final relevance = ranks[a]!.compareTo(ranks[b]!);
        if (relevance != 0) return relevance;
        return a.compareTo(b);
      });
    return titles.map((title) => groups[title]!).toList();
  }

  bool _visibleBook(Book book) {
    final repository = widget.repository;
    final entry = _sources[book.sourceId];
    return !_metadataStale &&
        repository.sourceRisksReady &&
        !repository.sourceRiskMutationPending &&
        repository.policy.textAllowed(_query) &&
        entry != null &&
        entry.enabled &&
        repository.sourceEntryAllowed(entry) &&
        repository.bookAllowed(book);
  }

  Future<void> _choose(List<Book> group) async {
    final title = group.first.title.trim();
    final book = await showDialog<Book>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: _updates,
        builder: (context, _) {
          final choices =
              _results.values
                  .where(
                    (book) => book.title.trim() == title && _visibleBook(book),
                  )
                  .toList()
                ..sort(_compareSources);
          return _sourceDialog(context, title, choices);
        },
      ),
    );
    if (!mounted || book == null || !_visibleBook(book)) {
      return;
    }
    await widget.onOpen(book);
    if (!mounted) return;
    final revision = ++_policyRevision;
    setState(() => _metadataStale = true);
    _updates.value++;
    await _refreshPolicySources(revision);
  }

  final _updates = ValueNotifier<int>(0);

  Widget _sourceDialog(
    BuildContext context,
    String title,
    List<Book> choices,
  ) => AlertDialog(
    title: Text(choices.isEmpty ? '选择来源' : title),
    content: SizedBox(
      width: 520,
      height: MediaQuery.sizeOf(context).height * .5,
      child: ListView.builder(
        itemCount: choices.length,
        itemBuilder: (_, index) {
          final book = choices[index];
          final entry = _sources[book.sourceId];
          final latency = _latencies[book.sourceId];
          return ListTile(
            title: Text(entry?.source.name ?? book.uri.host),
            subtitle: Text(
              [
                if (book.author.isNotEmpty) book.author,
                if (book.id == _preferred?.id) '当前渠道',
                book.latestChapter.isEmpty
                    ? '最新章节：渠道未提供'
                    : '最新章节：${book.latestChapter}',
                if (book.updatedLabel.isNotEmpty) '更新：${book.updatedLabel}',
                latency == null ? (_busy ? '等待搜索' : '无搜索耗时') : '$latency ms',
              ].join(' · '),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                BookLinkButton(label: '复制书籍网页链接', uri: book.uri),
                if (entry != null)
                  BookSourceFavorite(
                    key: ValueKey(book.id),
                    repository: widget.repository,
                    entry: entry,
                    onChanged: (value) {
                      setState(
                        () =>
                            _sources[book.sourceId] = entry.withFavorite(value),
                      );
                      _updates.value++;
                      widget.onSourceFavorite?.call(book.sourceId, value);
                    },
                  ),
              ],
            ),
            onTap: () => Navigator.pop(context, book),
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );

  @override
  void dispose() {
    _progressRefresh?.cancel();
    _token?.cancel();
    _input.dispose();
    _updates.dispose();
    widget.repository.policy.removeListener(_policyChanged);
    widget.repository.sourceRiskChanges.removeListener(_policyChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups();
    return Scaffold(
      appBar: AppBar(title: const Text('聚合搜索')),
      body: Column(
        children: [
          _toolbar(),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          _searchStatus(groups.length),
          Expanded(
            child: groups.isEmpty
                ? Center(child: Text(_emptyMessage()))
                : ListView.builder(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    itemCount: groups.length,
                    itemBuilder: (_, index) => _result(groups[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _searchStatus(int count) => ListTile(
    dense: true,
    subtitle: _certificateFailures.isEmpty
        ? null
        : Text('${_certificateFailures.length} 个渠道的 HTTPS 证书无法验证'),
    title: Text(
      _error ??
          (_busy && _retrying
              ? '正在重试失败渠道…'
              : '${_cancelled ? '已取消 · ' : ''}$_done / $_total 个渠道 · $count 部作品'
                    '${_failedSources.isEmpty ? '' : ' · ${_failedSources.length} 个渠道失败'}'),
    ),
    trailing: !_busy && _failedSources.isNotEmpty
        ? TextButton(onPressed: _retryFailed, child: const Text('重试失败渠道'))
        : null,
  );

  String _emptyMessage() {
    if (_busy) return '正在搜索…';
    if (_cancelled) return '搜索已取消';
    if (_error != null) return '搜索未完成';
    if (_total == 0) return '没有可用于此次搜索的启用渠道';
    if (_failedSources.length == _total) return '本次搜索的渠道均请求失败';
    return '没有符合条件的作品';
  }

  Widget _result(List<Book> group) {
    group.sort(_compareSources);
    final book = group.first;
    final knownLatest =
        group.where((item) => item.latestChapter.isNotEmpty).toList()
          ..sort(compareBookChapterFreshness);
    final freshest = knownLatest.firstOrNull ?? book;
    final freshestSource =
        _sources[freshest.sourceId]?.source.name ?? freshest.uri.host;
    final authors = group
        .map((book) => book.author)
        .where((name) => name.isNotEmpty)
        .toSet();
    return ListTile(
      key: ValueKey(book.title.trim()),
      leading: SizedBox(
        width: 38,
        height: 52,
        child: BookCover(book: book, repository: widget.repository),
      ),
      title: Text(book.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              if (authors.isNotEmpty) authors.join(' / '),
              '${group.map((book) => book.sourceId).toSet().length} 个渠道',
              if (group.any((book) => book.id == _preferred?.id)) '含当前渠道',
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            freshest.latestChapter.isEmpty
                ? '最新章节：渠道未提供'
                : '最新章节：${freshest.latestChapter}（$freshestSource）',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _choose(group),
    );
  }

  Widget _toolbar() => Padding(
    padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 620;
        final chips = <Widget>[
          for (final (field, label) in const [
            (BookSearchField.all, '全部'),
            (BookSearchField.title, '书名'),
            (BookSearchField.author, '作者'),
          ])
            ChoiceChip(
              label: Text(label),
              selected: _field == field,
              onSelected: (_) {
                if (_field == field) return;
                _field = field;
                _submit();
              },
            ),
          if (_scoped)
            InputChip(
              label: Text(widget.favoritesOnly ? '收藏渠道' : _scopeName()),
              onDeleted: () {
                setState(() => _scoped = false);
                _submit();
              },
            ),
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _submit(),
                    maxLength: 2048,
                    decoration: const InputDecoration(
                      hintText: '输入书名、作者或书籍链接',
                      counterText: '',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: _busy ? '取消搜索' : '搜索',
                  icon: Icon(_busy ? Icons.stop : Icons.search),
                  onPressed: _busy ? _cancelSearch : _submit,
                ),
              ],
            ),
            if (compact)
              // Keep the field chips on one scrolling row on phones instead of
              // letting them wrap into a taller block.
              SizedBox(
                height: 42,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: chips.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (_, index) => chips[index],
                ),
              )
            else
              Wrap(spacing: 6, children: chips),
          ],
        );
      },
    ),
  );

  String _scopeName() {
    final entry = _sources[widget.sourceId];
    if (_metadataStale ||
        widget.repository.sourceRiskMutationPending ||
        entry == null ||
        !widget.repository.policy.textAllowed(_query) ||
        !widget.repository.sourceEntryAllowed(entry)) {
      return '当前渠道';
    }
    return entry.source.name;
  }
}
