part of 'books_repository.dart';

Uri? _bookAddress(String query) {
  final uri = Uri.tryParse(query);
  if (uri == null ||
      !uri.hasAuthority ||
      !const {'http', 'https'}.contains(uri.scheme)) {
    return null;
  }
  return legacyBookUri(uri);
}

/// Discovery always selects from the current, policy-filtered categories.
extension _BookRepositoryDiscovery on BooksRepository {
  Future<({List<Book> books, int failed})> _find(
    BookKind kind,
    String query,
    CancellationToken token, {
    String? sourceId,
    LegadoCategory? category,
    int page = 1,
    int? maxSources,
    Set<String>? sourceIds,
    String? preferredSource,
    String? excludedSource,
    bool skipQidian = false,
    bool favorites = false,
    BookSearchField field = BookSearchField.all,
    List<BookSourceEntry>? availableSources,
    void Function(BookSearchUpdate)? onProgress,
  }) async {
    await ensureSourceRiskLoaded();
    if (!kindAllowed(kind)) throw const ContentBlocked();
    if (query.isNotEmpty && !policy.textAllowed(query)) {
      throw const ContentBlocked();
    }
    final address = _bookAddress(query);
    final entries = (availableSources ?? await sources(kind, enabledOnly: true))
        .where((entry) {
          if (!entry.enabled ||
              !comicAccess.allowed(entry.source) ||
              entry.source.kind != kind ||
              !_currentSearchEntry(entry) ||
              (skipQidian && isQidianHost(entry.source.endpoint.host)) ||
              entry.source.id == excludedSource ||
              (sourceId != null && sourceId != entry.source.id) ||
              (sourceIds != null && !sourceIds.contains(entry.source.id))) {
            return false;
          }
          if (address != null) return entry.source.acceptsBookAddress(address);
          return entry.source.hasDiscovery ||
              (query.isNotEmpty && entry.source.hasSearch);
        })
        .toList();
    final prioritized = _prioritize(entries, preferredSource, favorites);
    final selected = maxSources == null
        ? prioritized
        : prioritized.take(maxSources).toList();
    token.check();
    onProgress?.call((
      sourceId: null,
      books: [],
      completed: 0,
      total: selected.length,
      failed: false,
      latencyMs: null,
    ));
    return _searchSources(
      selected,
      query,
      token,
      category,
      page,
      address,
      field,
      onProgress,
    );
  }

  Future<void> _checkFollowing(BookKind kind, CancellationToken token) async {
    await ensureSourceRiskLoaded();
    BookCatalogCapacityExceeded? capacityError;
    final entries = (await store.shelf()).where(
      (entry) =>
          entry.following && entry.book.kind == kind && bookAllowed(entry.book),
    );
    for (final entry in entries) {
      token.check();
      try {
        final fresh = await chapters(entry.book, token, refresh: true);
        token.check();
        if (fresh.isEmpty || !bookAllowed(entry.book)) continue;
        await store.updateFollowedChapters(entry.book, fresh);
      } on BookCatalogCapacityExceeded catch (error) {
        capacityError = error;
      } on Exception {
        token.check();
      }
    }
    if (capacityError != null) throw capacityError;
  }

  List<BookSourceEntry> _prioritize(
    Iterable<BookSourceEntry> entries,
    String? preferredSource,
    bool favorites,
  ) => [
    ...entries.where(
      (entry) =>
          entry.source.id == preferredSource && (!favorites || entry.favorite),
    ),
    ...entries.where(
      (entry) => entry.source.id != preferredSource && entry.favorite,
    ),
    if (!favorites)
      ...entries.where(
        (entry) => entry.source.id != preferredSource && !entry.favorite,
      ),
  ];

  bool _currentSearchEntry(BookSourceEntry snapshot) {
    final current = _sourceAccess.entry(snapshot.source.id);
    if (current == null || !current.enabled || !sourceEntryAllowed(current)) {
      return false;
    }
    return identical(current.source, snapshot.source) ||
        jsonEncode(current.source.toJson()) ==
            jsonEncode(snapshot.source.toJson());
  }

  Future<({List<Book> books, int failed})> _searchSources(
    List<BookSourceEntry> selected,
    String query,
    CancellationToken token,
    LegadoCategory? category,
    int page,
    Uri? address,
    BookSearchField field,
    void Function(BookSearchUpdate)? onProgress,
  ) async {
    final results = <String, List<Book>>{};
    final match = address == null && query.trim().isNotEmpty
        ? BookSearchQuery(query, field)
        : null;
    var failed = 0;
    var cursor = 0, completed = 0;
    Future<void> fetchSources() async {
      while (cursor < selected.length) {
        token.check();
        final entry = selected[cursor++];
        final source = entry.source;
        var books = <Book>[];
        var failure = false;
        int? latencyMs;
        try {
          if (_currentSearchEntry(entry) &&
              !await _blocked(source.id) &&
              _currentSearchEntry(entry)) {
            final watch = Stopwatch()..start();
            final found = await _booksWithDiscoveryPolicy(
              source,
              query,
              token,
              category: category,
              page: page,
              bookAddress: address,
            );
            latencyMs = watch.elapsedMilliseconds;
            if (_currentSearchEntry(entry) &&
                !await _blocked(source.id) &&
                _currentSearchEntry(entry)) {
              final allowEpisodeMatches =
                  source.kind == BookKind.audio &&
                  source.format == BookFormat.feed &&
                  field == BookSearchField.all;
              books = found
                  .where(
                    (book) =>
                        bookAllowed(book) &&
                        (match == null ||
                            allowEpisodeMatches ||
                            match.rank(book) != null),
                  )
                  .toList();
            }
          }
        } on Exception {
          failed++;
          failure = true;
        }
        token.check();
        results[source.id] = books;
        onProgress?.call((
          sourceId: source.id,
          books: books,
          completed: ++completed,
          total: selected.length,
          failed: failure,
          latencyMs: latencyMs,
        ));
      }
    }

    await Future.wait(
      List.generate(math.min(4, selected.length), (_) => fetchSources()),
    );
    token.check();
    return (
      books: selected
          .expand((entry) => results[entry.source.id] ?? const <Book>[])
          .where(bookAllowed)
          .toList(),
      failed: failed,
    );
  }

  Future<List<LegadoCategory>> _discoveryCategories(
    BookKind kind,
    String sourceId,
    CancellationToken cancellation,
  ) async {
    final source = await _enabledSource(kind, sourceId);
    final lease = _DiscoveryLease(this, source, cancellation);
    try {
      final selection = await _discoverySelection(source, null, lease);
      lease.check();
      return selection.allowed;
    } finally {
      lease.dispose();
    }
  }

  Future<BookDiscoveryPage> _discoverPage(
    BookKind kind,
    String sourceId,
    CancellationToken cancellation, {
    LegadoCategory? category,
    int page = 1,
    String? cursor,
  }) async {
    final source = await _enabledSource(kind, sourceId);
    final lease = _DiscoveryLease(this, source, cancellation);
    try {
      final issued = cursor == null ? null : _discoveryCursors[cursor];
      if (cursor != null &&
          (issued == null ||
              issued.sourceId != source.id ||
              issued.fingerprint != lease.fingerprint ||
              issued.page != page)) {
        throw const ContentBlocked('分类或分页已失效，请刷新');
      }
      final selection = await _discoverySelection(source, category, lease);
      lease.check();
      if (selection.empty) {
        if (cursor != null) throw const ContentBlocked('分类或分页已失效');
        return (books: <Book>[], next: null);
      }
      if (cursor == null &&
          policy.filterAdult &&
          !bookDiscoveryPageAllowed(
            source,
            selection.selected,
            selection.denied,
            page,
          )) {
        throw const ContentBlocked('该分页无法验证分类范围');
      }
      final scope = _discoveryScope(source, selection.selected, lease.revision);
      final actualCursor = cursor == null
          ? null
          : issued?.matching(scope, page);
      if (cursor != null && actualCursor == null) {
        throw const ContentBlocked('分类或分页已失效，请刷新');
      }
      if (actualCursor != null &&
          policy.filterAdult &&
          !bookDiscoveryNextAllowed(
            source,
            selection.selected,
            selection.denied,
            actualCursor,
            page,
          )) {
        throw const ContentBlocked('该分页无法验证分类范围');
      }
      final result = await client.discover(
        source,
        lease.token,
        category: selection.selected,
        page: page,
        cursor: actualCursor,
        allowDiscoveryNetworkExpansion: !policy.filterAdult,
      );
      lease.check();
      final next = result.next;
      final permitted =
          next != null &&
          (!policy.filterAdult ||
              bookDiscoveryNextAllowed(
                source,
                selection.selected,
                selection.denied,
                next,
                page + 1,
              ));
      return (
        books: result.books.where(bookAllowed).toList(),
        next: permitted
            ? _rememberDiscoveryCursor(source, scope, page + 1, next)
            : null,
      );
    } finally {
      lease.dispose();
    }
  }

  Future<List<Book>> _booksWithDiscoveryPolicy(
    BookSource source,
    String query,
    CancellationToken cancellation, {
    LegadoCategory? category,
    int page = 1,
    Uri? bookAddress,
    bool allowDisabled = false,
  }) async {
    final isDiscovery =
        bookAddress == null &&
        (query.isEmpty ||
            (source.format == BookFormat.html &&
                source.legado != null &&
                source.legado!.search.isEmpty));
    if (!isDiscovery &&
        category == null &&
        (bookAddress == null || !policy.filterAdult)) {
      return client.books(
        source,
        query,
        cancellation,
        page: page,
        bookAddress: bookAddress,
      );
    }
    final lease = _DiscoveryLease(
      this,
      source,
      cancellation,
      allowDisabled: allowDisabled,
    );
    try {
      final selection = await _discoverySelection(source, category, lease);
      lease.check();
      if (bookAddress != null &&
          bookDiscoveryCategoryDenied(
            source,
            LegadoCategory('', bookAddress.toString()),
            selection.denied,
          )) {
        throw const ContentBlocked('该地址可能属于受限分类');
      }
      if (bookAddress != null) {
        final result = await client.books(
          source,
          query,
          lease.token,
          bookAddress: bookAddress,
          allowDiscoveryNetworkExpansion: !policy.filterAdult,
        );
        lease.check();
        return result.where(bookAllowed).toList();
      }
      if (selection.empty) return [];
      if (isDiscovery &&
          policy.filterAdult &&
          !bookDiscoveryPageAllowed(
            source,
            selection.selected,
            selection.denied,
            page,
          )) {
        throw const ContentBlocked('该分页无法验证分类范围');
      }
      final List<Book> result;
      if (query.isEmpty && bookAddress == null) {
        result = (await client.discover(
          source,
          lease.token,
          category: selection.selected,
          page: page,
          allowDiscoveryNetworkExpansion: !policy.filterAdult,
        )).books;
      } else {
        result = await client.books(
          source,
          query,
          lease.token,
          category: selection.selected,
          page: page,
          bookAddress: bookAddress,
          allowDiscoveryNetworkExpansion: !policy.filterAdult,
        );
      }
      lease.check();
      return result.where(bookAllowed).toList();
    } finally {
      lease.dispose();
    }
  }

  Future<_DiscoverySelection> _discoverySelection(
    BookSource source,
    LegadoCategory? requested,
    _DiscoveryLease lease,
  ) async {
    lease.check();
    final denied = <LegadoCategory>[];
    final categories = await client.categories(
      source,
      lease.token,
      allowCategory: (category) => bookCategoryAllowed(policy, category),
      onDenied: denied.add,
      allowDiscoveryNetworkExpansion: !policy.filterAdult,
    );
    lease.check();
    denied.addAll(
      categories.where((category) => !bookCategoryAllowed(policy, category)),
    );
    final allowed = [
      for (final category in categories)
        if (bookCategoryAllowed(policy, category) &&
            !(policy.filterAdult &&
                denied.isNotEmpty &&
                _globalDiscoveryCategory(source, category)) &&
            !bookDiscoveryCategoryDenied(source, category, denied))
          category,
    ];
    LegadoCategory? selected;
    if (requested != null) {
      selected = allowed
          .where((item) => _sameCategory(item, requested))
          .firstOrNull;
      if (selected == null) throw const ContentBlocked('该分类已不可用');
    } else {
      selected = allowed.firstOrNull;
    }
    // A null category is only a default for genuinely category-less sources.
    // Legado otherwise asks its client for the unfiltered list a second time.
    final empty =
        categories.isNotEmpty && allowed.isEmpty ||
        (categories.isEmpty &&
            source.format == BookFormat.html &&
            source.legado != null);
    return _DiscoverySelection(allowed, selected, empty, denied);
  }

  void _discoveryPolicyChanged() {
    final snapshot = bookSitePolicySnapshot(policy);
    if (snapshot == _discoveryPolicySnapshot) return;
    _discoveryPolicySnapshot = snapshot;
    _invalidateDiscovery();
  }

  void _discoveryRiskChanged() => _invalidateDiscovery();

  void _invalidateDiscovery() {
    _discoveryRevision++;
    _discoveryCursors.clear();
    for (final token in _discoveryTokens.toList()) {
      token.cancel();
    }
  }

  String _rememberDiscoveryCursor(
    BookSource source,
    String scope,
    int page,
    String cursor,
  ) {
    final key = sha256
        .convert(utf8.encode(jsonEncode([scope, page, cursor])))
        .toString();
    if (!_discoveryCursors.containsKey(key) &&
        _discoveryCursors.length >= 128) {
      _discoveryCursors.remove(_discoveryCursors.keys.first);
    }
    _discoveryCursors[key] = _DiscoveryCursor(
      source.id,
      bookSourceCheckFingerprint(source),
      scope,
      page,
      cursor,
    );
    return key;
  }
}

bool _globalDiscoveryCategory(BookSource source, LegadoCategory category) {
  if (source.format == BookFormat.shuyin && category.address == '0') {
    return true;
  }
  return const {
    '全部',
    '所有',
    '聚合',
    '全部分类',
    '所有分类',
    '全部作品',
    '所有作品',
  }.contains(category.title.trim());
}

bool _sameCategory(LegadoCategory a, LegadoCategory b) =>
    a.title == b.title && a.group == b.group && a.address == b.address;

String _discoveryScope(
  BookSource source,
  LegadoCategory? category,
  int revision,
) => jsonEncode([
  source.id,
  bookSourceCheckFingerprint(source),
  category?.title,
  category?.group,
  category?.address,
  revision,
]);

final class _DiscoverySelection {
  const _DiscoverySelection(
    this.allowed,
    this.selected,
    this.empty,
    this.denied,
  );
  final List<LegadoCategory> allowed;
  final List<LegadoCategory> denied;
  final LegadoCategory? selected;
  final bool empty;
}

final class _DiscoveryCursor {
  const _DiscoveryCursor(
    this.sourceId,
    this.fingerprint,
    this.scope,
    this.page,
    this.cursor,
  );
  final String sourceId, fingerprint, scope, cursor;
  final int page;
  String? matching(String expected, int expectedPage) =>
      scope == expected && page == expectedPage ? cursor : null;
}

final class _DiscoveryLease {
  _DiscoveryLease(
    this.books,
    this.source,
    CancellationToken cancellation, {
    this.allowDisabled = false,
  }) : revision = books._discoveryRevision,
       fingerprint = bookSourceCheckFingerprint(source) {
    _unlink = cancellation.listen(token.cancel);
    books._discoveryTokens.add(token);
  }

  final BooksRepository books;
  final BookSource source;
  final bool allowDisabled;
  final int revision;
  final String fingerprint;
  final token = CancellationToken();
  late final void Function() _unlink;

  void check() {
    token.check();
    final current = books._sourceAccess.entry(source.id);
    if (books._evidenceClosing ||
        books._evidenceMutations != 0 ||
        !books.sourceRisksReady ||
        revision != books._discoveryRevision ||
        !books.sourceAllowed(source) ||
        (current == null && !allowDisabled) ||
        (current != null &&
            ((!allowDisabled && !current.enabled) ||
                !books.sourceEntryAllowed(current) ||
                bookSourceCheckFingerprint(current.source) != fingerprint))) {
      throw const RequestCancelled();
    }
  }

  void dispose() {
    _unlink();
    books._discoveryTokens.remove(token);
  }
}
