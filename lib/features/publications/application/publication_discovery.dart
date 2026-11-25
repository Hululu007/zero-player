import 'dart:async';
import 'dart:convert';

import '../../../core/network/cancellation_token.dart';
import '../../../core/network/request_scheduler.dart';
import '../data/publication_catalogue.dart';
import '../data/publication_http.dart';
import '../data/publication_search_text.dart';
import '../data/publication_sources.dart';
import '../data/publication_store.dart';
import '../domain/publication.dart';

typedef PublicationSourceStatus = ({
  PublicationSource source,
  bool enabled,
  bool paused,
  bool favorite,
  PublicationProblem? problem,
  int? checked,
  int? synced,
  String? revision,
  bool hasSnapshot,
});
typedef PublicationSearchUpdate = ({
  PublicationSource source,
  List<PublicationEdition> editions,
  PublicationProblem? problem,
  bool complete,
});

const _configuredSourceLimit = 13;

final class PublicationDiscovery {
  PublicationDiscovery(this.store, this.http, this.allowed);
  final PublicationStore store;
  final PublicationHttp http;
  final bool Function(String) allowed;
  final _operations = <String, CancellationToken>{};
  final _checks = <String, Future<void>>{};
  final _searches = <CancellationToken>{};
  final _sourceRequests = <String, Set<CancellationToken>>{};
  final _catalogues = <String, PublicationCatalogue>{};
  Future<void>? _checkingDue;
  bool _closed = false;

  Future<List<PublicationSourceStatus>> sources() async {
    await store.initialize();
    final rows = {
      for (final row in await store.db.rows(
        'SELECT * FROM publication_source_settings',
      ))
        row['id']: row,
    };
    final sources = [
      for (final source in builtinPublicationSources)
        _status(source, rows[source.id]),
      for (final row in rows.values)
        if (_configuredSource(row) case final source?) _status(source, row),
    ];
    return [
      ...sources.where((item) => item.favorite),
      ...sources.where((item) => !item.favorite),
    ];
  }

  PublicationSource? _configuredSource(Map<String, Object?>? row) {
    if (row?['spec'] case final String spec) {
      try {
        return PublicationSource.configure(
          jsonDecode(spec) as Map,
          id: row!['id'] as String,
        );
      } on FormatException {
        return null;
      } on TypeError {
        return null;
      }
    }
    return null;
  }

  PublicationSourceStatus _status(
    PublicationSource source,
    Map<String, Object?>? row,
  ) {
    final enabled =
        !source.restricted &&
        (row == null ? source.enabledByDefault : row['enabled'] == 1);
    final problem = PublicationProblem.values
        .where((value) => value.name == row?['failure'])
        .firstOrNull;
    final hasSnapshot =
        source.kind == PublicationSourceKind.snapshot &&
        row?['revision'] != null;
    return (
      source: source,
      enabled: enabled,
      paused:
          enabled &&
          source.configurable &&
          !hasSnapshot &&
          _sourceUnavailable(problem),
      favorite: row?['favorite'] == 1,
      problem: problem,
      checked: row?['checked'] as int?,
      synced: row?['synced'] as int?,
      revision: row?['revision'] as String?,
      hasSnapshot: hasSnapshot,
    );
  }

  bool manageable(PublicationSource source) =>
      !_closed &&
      !source.restricted &&
      allowed('${source.name} ${source.endpoint.host}');

  Future<void> setEnabled(PublicationSource source, bool enabled) =>
      setEnabledBatch([source], enabled);

  Future<void> setEnabledBatch(
    Iterable<PublicationSource> sources,
    bool enabled,
  ) async {
    final selected = {for (final source in sources) source.id: source};
    if (selected.isEmpty) return;
    await store.initialize();
    await store.db.atomic(() async {
      void verify() {
        if (selected.values.any((source) => !manageable(source))) {
          throw const PublicationFailure(PublicationProblem.blocked);
        }
      }

      verify();
      store.db.beforeCommit(verify);
      for (final source in selected.values) {
        await _requireCurrentSource(source);
        if (source.configurable) {
          await store.db.write(
            'UPDATE publication_source_settings SET enabled=?, '
            'checked=CASE WHEN enabled=0 AND ?=1 AND revision IS NULL '
            'THEN NULL ELSE checked END WHERE id=? AND spec=?',
            [
              enabled ? 1 : 0,
              enabled && source.kind == PublicationSourceKind.snapshot ? 1 : 0,
              source.id,
              jsonEncode(source.toSpec()),
            ],
          );
        } else {
          await store.db.write(
            'INSERT INTO publication_source_settings(id,enabled) VALUES(?,?) '
            'ON CONFLICT(id) DO UPDATE SET enabled=excluded.enabled',
            [source.id, enabled ? 1 : 0],
          );
        }
      }
      if (!enabled) {
        store.db.afterCommit(() {
          for (final id in selected.keys) {
            _cancelSource(id);
          }
        });
      }
    }, tables: {'publication_source_settings'});
  }

  Future<void> setFavorite(PublicationSource source, bool favorite) async {
    await store.initialize();
    await store.db.atomic(() async {
      await _requireCurrentSource(source);
      store.db.beforeCommit(() => _requireManageableSource(source));
      await store.db.write(
        'INSERT INTO publication_source_settings(id,enabled,favorite) VALUES(?,?,?) '
        'ON CONFLICT(id) DO UPDATE SET favorite=excluded.favorite',
        [source.id, source.enabledByDefault ? 1 : 0, favorite ? 1 : 0],
      );
    }, tables: {'publication_source_settings'});
  }

  void _requireManageableSource(PublicationSource source) {
    if (!manageable(source)) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
  }

  Future<void> _requireCurrentSource(PublicationSource source) async {
    _requireManageableSource(source);
    final current = await _sourceStatus(source.id);
    if (current == null || !current.source.sameConfiguration(source)) {
      throw const FormatException('书源已更改，请刷新列表后重试');
    }
  }

  PublicationSource validateConfig(String raw, {String? id}) {
    if (raw.length > 32768) throw const FormatException('书源配置超过大小限制');
    final value = jsonDecode(raw);
    if (_closed ||
        value is! Map ||
        builtinPublicationSources.any((source) => source.id == id)) {
      throw const FormatException('书源配置无效');
    }
    final source = PublicationSource.configure(value, id: id);
    _requireRule(source);
    return source;
  }

  void _requireRule(PublicationSource source) {
    if (_closed || !allowed('${source.name} ${source.endpoint.host}')) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
  }

  List<PublicationEdition> preview(
    PublicationSource source,
    String sample, {
    String detail = '',
  }) {
    _requireRule(source);
    if (sample.length > 2 << 20 || detail.length > 2 << 20) {
      throw const FormatException('书源样本超过大小限制');
    }
    final base = _listingEndpoint(source, '');
    final rows = configuredPublicationRows(
      source,
      sample,
      maxRows: 500,
      base: base,
    ).where((row) => allowed('${row.title} ${row.author}')).take(8).toList();
    if (detail.isNotEmpty && rows.isNotEmpty && rows.first.page != null) {
      final first = rows.first;
      rows[0] = first.withCandidates([
        ...first.candidates,
        ...configuredDetailCandidates(source, detail, first.page!),
      ]);
    }
    return rows;
  }

  Future<void> saveConfig(String raw, {String? id}) async {
    final source = validateConfig(raw, id: id);
    if (!allowed('${source.name} ${source.endpoint.host}')) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
    final available = await sources();
    if (id == null &&
        available.where((item) => item.source.configurable).length >=
            _configuredSourceLimit) {
      throw const FormatException('已达到书源数量上限');
    }
    final changed = await store.db.atomic(() async {
      final spec = jsonEncode(source.toSpec());
      final old = available
          .where((item) => item.source.id == source.id)
          .firstOrNull;
      if (old != null && old.source.sameConfiguration(source)) return false;
      await store.db.write(
        'INSERT INTO publication_source_settings(id,enabled,spec) VALUES(?,0,?) '
        'ON CONFLICT(id) DO UPDATE SET spec=excluded.spec,failure=NULL,checked=NULL,synced=NULL,revision=NULL',
        [source.id, spec],
      );
      await store.db.write('DELETE FROM publication_catalog WHERE source=?', [
        source.id,
      ]);
      return true;
    }, tables: {'publication_source_settings', 'publication_catalog'});
    if (changed) _cancelSource(source.id);
  }

  Future<void> remove(PublicationSource source) async {
    if (!source.configurable) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
    await store.initialize();
    await store.db.atomic(() async {
      await _requireCurrentSource(source);
      store.db.beforeCommit(() => _requireManageableSource(source));
      await store.db.write(
        'DELETE FROM publication_source_settings WHERE id=?',
        [source.id],
      );
      await store.db.write('DELETE FROM publication_catalog WHERE source=?', [
        source.id,
      ]);
      store.db.afterCommit(() => _cancelSource(source.id));
    }, tables: {'publication_source_settings', 'publication_catalog'});
  }

  Stream<PublicationSearchUpdate> search(
    String raw,
    CancellationToken token, {
    int maxPages = 3,
    String? sourceId,
    Set<String>? sourceIds,
    bool favoritesOnly = false,
    bool progressive = false,
    PublicationSearchField field = PublicationSearchField.all,
  }) async* {
    final query = publicationSearchQuery(raw);
    if (_closed || !allowed(raw) || !allowed(query)) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
    _searches.add(token);
    try {
      final chinese = publicationHanText.hasMatch(query);
      final filter = field == PublicationSearchField.all || query.isEmpty
          ? null
          : PublicationFieldSearch(
              field,
              query,
              hanFold: chinese ? await publicationHanFold() : const {},
            );
      if (filter != null && !filter.valid) return;
      final term = filter?.isbn.isNotEmpty == true ? filter!.isbn : query;
      final available = await sources();
      final enabled = available
          .where(
            (item) =>
                (sourceId == null || item.source.id == sourceId) &&
                (sourceIds == null || sourceIds.contains(item.source.id)) &&
                (!favoritesOnly || item.favorite) &&
                !item.source.websiteOnly &&
                _mayUse(item),
          )
          .toList();
      token.check();
      if (sourceId != null && enabled.isEmpty && !token.isCancelled) {
        final entry = available
            .where((item) => item.source.id == sourceId)
            .firstOrNull;
        if (entry != null &&
            manageable(entry.source) &&
            !entry.source.websiteOnly) {
          yield (
            source: entry.source,
            editions: const [],
            problem: entry.problem ?? PublicationProblem.unsupported,
            complete: true,
          );
        }
        return;
      }
      final plan = sourceId == null && chinese
          ? [
              ...enabled.where((item) => item.favorite),
              ...enabled.where(
                (item) => !item.favorite && item.source.preferChineseSearch,
              ),
              ...enabled.where(
                (item) => !item.favorite && !item.source.preferChineseSearch,
              ),
            ]
          : enabled;
      final updates = StreamController<PublicationSearchUpdate>();
      var index = 0;
      Future<void> worker() async {
        while (!token.isCancelled && !_closed && index < plan.length) {
          final source = plan[index++].source;
          final result = await _searchSource(
            source,
            term,
            token,
            maxPages.clamp(1, 5),
            filter: filter,
            timeout: Duration(seconds: sourceId == null ? 24 : 44),
            onPartial: progressive ? updates.add : null,
          );
          if (result != null && !token.isCancelled) updates.add(result);
        }
      }

      unawaited(
        Future.wait(List.generate(plan.length.clamp(0, 6), (_) => worker()))
            .catchError((Object error, StackTrace stack) {
              updates.addError(error, stack);
              return <void>[];
            })
            .whenComplete(updates.close),
      );
      yield* updates.stream;
    } finally {
      token.cancel();
      _searches.remove(token);
    }
  }

  Future<PublicationSearchUpdate?> _searchSource(
    PublicationSource source,
    String query,
    CancellationToken parent,
    int maxPages, {
    required Duration timeout,
    required PublicationFieldSearch? filter,
    void Function(PublicationSearchUpdate)? onPartial,
  }) async {
    final active = _sourceRequests.putIfAbsent(source.id, () => {});
    final token = CancellationToken();
    active.add(token);
    final detach = parent.listen(token.cancel);
    try {
      if (!await _canSearch(source, token)) return null;
      List<PublicationEdition> visible(List<PublicationEdition> rows) => rows
          .where(
            (row) =>
                (filter?.matches(row) ?? true) &&
                allowed('${row.title} ${row.author}'),
          )
          .toList();
      List<PublicationEdition> editions = const [];
      PublicationProblem? problem;
      try {
        editions = await withPublicationRequestDeadline(
          token,
          timeout,
          (request) => _query(
            source,
            query,
            request,
            maxPages: maxPages,
            filter: filter,
            onProgress: (rows) async {
              request.check();
              editions = rows;
              if (onPartial == null || !await _canSearch(source, request)) {
                return;
              }
              onPartial((
                source: source,
                editions: visible(rows),
                problem: null,
                complete: false,
              ));
            },
          ),
        );
      } on RequestCancelled {
        return null;
      } catch (error) {
        problem = _problem(error);
      }
      if (!await _canSearch(source, token, allowPaused: problem != null)) {
        return null;
      }
      return (
        source: source,
        editions: visible(editions),
        problem: problem,
        complete: true,
      );
    } finally {
      detach();
      active.remove(token);
      if (active.isEmpty) _sourceRequests.remove(source.id);
    }
  }

  Future<bool> _canSearch(
    PublicationSource source,
    CancellationToken token, {
    bool allowPaused = false,
  }) async {
    if (token.isCancelled) return false;
    final current = await _sourceStatus(source.id);
    return !token.isCancelled &&
        current != null &&
        current.enabled &&
        (allowPaused || !current.paused) &&
        manageable(current.source) &&
        current.source.sameConfiguration(source);
  }

  Future<bool> isEnabled(String id) async =>
      id == 'manual' || await enabledSource(id) != null;

  Future<PublicationSource?> enabledSource(String id) async {
    final entry = await _sourceStatus(id);
    return entry != null && _mayUse(entry) ? entry.source : null;
  }

  Future<List<PublicationResource>> loadCatalogueResources(
    PublicationResource entry,
    CancellationToken parent,
  ) async {
    parent.check();
    final source = await enabledSource(entry.source);
    parent.check();
    if (source == null || _closed) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
    final catalogue = catalogueFor(source);
    if (!entry.lookupRequired || catalogue is! ResourcePublicationCatalogue) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final active = _sourceRequests.putIfAbsent(source.id, () => {});
    final token = CancellationToken();
    active.add(token);
    final detach = parent.listen(token.cancel);
    try {
      final resources = await catalogue.loadResources(entry.link, token);
      final usable = await _canSearch(source, token);
      token.check();
      if (!usable) throw const PublicationFailure(PublicationProblem.blocked);
      return resources;
    } finally {
      detach();
      active.remove(token);
      if (active.isEmpty) _sourceRequests.remove(source.id);
    }
  }

  Future<PublicationSourceStatus?> _sourceStatus(String id) async {
    await store.initialize();
    final row = (await store.db.rows(
      'SELECT * FROM publication_source_settings WHERE id=?',
      [id],
    )).firstOrNull;
    final builtin = builtinPublicationSources
        .where((item) => item.id == id)
        .firstOrNull;
    if (builtin != null) return _status(builtin, row);
    final source = _configuredSource(row);
    return source == null ? null : _status(source, row);
  }

  bool _mayUse(PublicationSourceStatus item) =>
      item.enabled && !item.paused && manageable(item.source);

  Future<void> checkDue() => _checkingDue ??= withRequestPriority(
    RequestPriority.background,
    _checkDue,
  ).whenComplete(() => _checkingDue = null);

  Future<void> _checkDue() async {
    final before = publicationNow() - const Duration(hours: 24).inMilliseconds;
    await checkBatch([
      for (final item in await sources())
        if (item.enabled &&
            !item.source.websiteOnly &&
            manageable(item.source) &&
            (item.checked ?? 0) < before)
          item.source,
    ], includeDisabled: false);
  }

  Future<void> checkBatch(
    Iterable<PublicationSource> sources, {
    bool includeDisabled = true,
  }) async {
    final selected = {
      for (final source in sources) source.id: source,
    }.values.toList();
    var next = 0;
    Future<void> worker() async {
      while (!_closed && next < selected.length) {
        await check(selected[next++], includeDisabled: includeDisabled);
      }
    }

    await Future.wait(
      List.generate(selected.length.clamp(0, 3), (_) => worker()),
    );
  }

  Future<void> check(
    PublicationSource requested, {
    bool includeDisabled = true,
  }) => _checks.putIfAbsent(
    requested.id,
    () => _check(requested, includeDisabled).whenComplete(() {
      _checks.remove(requested.id);
    }),
  );

  Future<void> _check(PublicationSource requested, bool includeDisabled) async {
    if (!manageable(requested) || requested.websiteOnly) return;
    final current = await _sourceStatus(requested.id);
    if (current == null ||
        !current.source.sameConfiguration(requested) ||
        (!current.enabled && !includeDisabled) ||
        !manageable(current.source)) {
      return;
    }
    final source = current.source;
    final token = _operations[source.id] = CancellationToken();
    PublicationProblem? failure;
    try {
      if (source.kind == PublicationSourceKind.snapshot) {
        final editions = await _readSnapshot(source, token);
        if (current.enabled) await _sync(source, editions, token);
      } else if (catalogueFor(source) case final catalogue?) {
        await catalogue.check(token);
      } else {
        await _query(source, '', token, maxPages: 1);
      }
    } on RequestCancelled {
      _operations.remove(source.id);
      return;
    } catch (error) {
      failure = _problem(error);
    }
    try {
      if (token.isCancelled || !manageable(source)) return;
      await _saveCheck(current, failure, token);
      if (source.kind != PublicationSourceKind.snapshot &&
          _sourceUnavailable(failure) &&
          (await _sourceStatus(source.id))?.paused == true) {
        _cancelSourceRequests(source.id);
      }
    } on RequestCancelled {
      return;
    } finally {
      _operations.remove(source.id);
    }
  }

  Future<void> _saveCheck(
    PublicationSourceStatus item,
    PublicationProblem? failure,
    CancellationToken token,
  ) => store.db.atomic(() async {
    final source = item.source;
    store.db.beforeCommit(token.check);
    final values = [failure?.name, publicationNow()];
    final enabled = item.enabled ? 1 : 0;
    if (source.configurable) {
      await store.db.write(
        'UPDATE publication_source_settings SET failure=?,checked=? '
        'WHERE id=? AND enabled=? AND spec=?',
        [...values, source.id, enabled, jsonEncode(source.toSpec())],
      );
    } else {
      await store.db.write(
        'INSERT INTO publication_source_settings(id,enabled,failure,checked) VALUES(?,?,?,?) '
        'ON CONFLICT(id) DO UPDATE SET failure=excluded.failure,checked=excluded.checked '
        'WHERE enabled=excluded.enabled',
        [source.id, enabled, ...values],
      );
    }
  }, tables: {'publication_source_settings'});

  Future<List<PublicationEdition>> _query(
    PublicationSource source,
    String query,
    CancellationToken token, {
    int maxPages = 3,
    PublicationFieldSearch? filter,
    Future<void> Function(List<PublicationEdition>)? onProgress,
  }) async {
    if (source.kind == PublicationSourceKind.snapshot) {
      final status = await _sourceStatus(source.id);
      if (status?.hasSnapshot != true) {
        await check(source, includeDisabled: false);
        token.check();
        final checked = await _sourceStatus(source.id);
        if (checked?.hasSnapshot != true && checked?.problem != null) {
          throw PublicationFailure(checked!.problem!);
        }
      }
      return _snapshot(source, query, filter);
    }
    if (catalogueFor(source) case final catalogue?) {
      if (catalogue is ProgressivePublicationCatalogue) {
        return catalogue.search(
          query,
          token,
          maxPages: maxPages,
          allowed: allowed,
          filter: filter,
          onProgress: onProgress,
        );
      }
      return catalogue.search(
        query,
        token,
        maxPages: maxPages,
        allowed: allowed,
        filter: filter,
      );
    }
    return _configuredSearch(
      source,
      query,
      token,
      maxPages,
      filter,
      onProgress,
    );
  }

  Future<List<PublicationEdition>> _configuredSearch(
    PublicationSource source,
    String query,
    CancellationToken token,
    int maxPages,
    PublicationFieldSearch? filter,
    Future<void> Function(List<PublicationEdition>)? onProgress,
  ) async {
    final found = <String, PublicationEdition>{};
    final visited = <Uri>{};
    final seenRows = <String>{};
    final endpoint = _listingEndpoint(source, query);
    Uri? next;
    for (var page = 1; page <= maxPages; page++) {
      final uri =
          next ??
          endpoint.replace(
            queryParameters: {
              ...endpoint.queryParameters,
              if (query.isNotEmpty || source.rule == null)
                source.parameter: query,
              if (source.rule?.next == null) source.pageParameter: '$page',
            },
          );
      if (!visited.add(uri)) break;
      final String data;
      try {
        data = await http.text(
          uri,
          token,
          scope: source.restrict,
          deadline: publicationCatalogueDeadline,
          allowGzip: true,
        );
      } on Exception catch (error) {
        token.check();
        if (found.isEmpty || !isPublicationNetworkFailure(error)) rethrow;
        break;
      }
      final rows = configuredPublicationRows(
        source,
        data,
        maxRows: 500,
        base: uri,
      );
      final fresh = rows.where((row) => seenRows.add(row.id)).toList();
      if (fresh.isEmpty && source.rule?.next == null) break;
      final matches = fresh.where(
        (row) =>
            row.matches(query, filter: filter) &&
            allowed('${row.title} ${row.author}') &&
            !found.containsKey(row.id),
      );
      final limit = source.rule == null
          ? rows.length
          : source.rule!.detail.isNotEmpty
          ? 8
          : 20;
      final batch = matches.take(limit).toList();
      if (batch.isNotEmpty) {
        for (final row in batch) {
          found[row.id] = row;
        }
        await onProgress?.call(found.values.toList());
        if (source.rule?.detail.isNotEmpty == true) {
          await Future.wait(
            batch.map((row) async {
              final resolved = await withRequestPriority(
                RequestPriority.background,
                () => _resolveDetails(source, row, token),
              );
              if (identical(row, resolved)) return;
              found[row.id] = resolved;
              await onProgress?.call(found.values.toList());
            }),
          );
        }
      }
      if (found.length >= (source.rule == null ? 20 : 60) ||
          (query.isEmpty && source.rule == null)) {
        break;
      }
      if (source.rule?.next != null) {
        next = configuredNextPage(source, data, uri);
        if (next == null) break;
      }
    }
    return found.values.toList();
  }

  Uri _listingEndpoint(PublicationSource source, String query) {
    final list = source.rule?.list;
    return query.isEmpty && list != null
        ? source.endpoint.resolve(list)
        : source.endpoint;
  }

  Future<PublicationEdition> _resolveDetails(
    PublicationSource source,
    PublicationEdition row,
    CancellationToken token,
  ) async {
    final page = row.page;
    if (page == null ||
        source.rule?.detail.isNotEmpty != true ||
        row.candidates.isNotEmpty) {
      return row;
    }
    try {
      final data = await http.text(
        page,
        token,
        scope: source.restrict,
        deadline: publicationCatalogueDeadline,
        allowGzip: true,
      );
      token.check();
      final candidates = configuredDetailCandidates(source, data, page);
      return candidates.isEmpty ? row : row.withCandidates(candidates);
    } on RequestCancelled {
      rethrow;
    } on Exception {
      return row;
    }
  }

  Future<List<PublicationEdition>> _snapshot(
    PublicationSource source,
    String query,
    PublicationFieldSearch? filter,
  ) async {
    if (filter != null) {
      // Match before limiting, including simplified/traditional variants and ISBNs.
      final rows = await store.db.rows(
        'SELECT data FROM publication_catalog WHERE source=?',
        [source.id],
      );
      return rows
          .map(_snapshotEdition)
          .where(
            (book) =>
                filter.matches(book) && allowed('${book.title} ${book.author}'),
          )
          .take(100)
          .toList();
    }
    final isbn = normalizedIsbn(query);
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .take(16)
        .toList();
    final condition = isbn.isNotEmpty
        ? ' AND isbn=?'
        : words.map((_) => ' AND instr(searchable,?)>0').join();
    final rows = await store.db.rows(
      'SELECT data FROM publication_catalog WHERE source=?$condition LIMIT 100',
      [source.id, if (isbn.isNotEmpty) isbn else ...words],
    );
    return rows.map(_snapshotEdition).toList();
  }

  PublicationEdition _snapshotEdition(Map<String, Object?> row) =>
      PublicationEdition.fromJson(
        jsonDecode(row['data'] as String) as Map,
        includePublishedAccess: true,
      );

  Future<({String revision, List<PublicationEdition> rows})> _readSnapshot(
    PublicationSource source,
    CancellationToken token,
  ) async {
    final raw = await http.text(
      source.endpoint,
      token,
      maxBytes: 4 << 20,
      scope: source.restrict,
      deadline: publicationCatalogueDeadline,
    );
    final revision = publicationId('catalog:2\n$raw');
    final editions = configuredPublicationRows(source, raw);
    if (editions.isEmpty) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    return (revision: revision, rows: editions);
  }

  Future<void> _sync(
    PublicationSource source,
    ({String revision, List<PublicationEdition> rows}) catalog,
    CancellationToken token,
  ) async {
    final (revision: revision, rows: editions) = catalog;
    await store.db.atomic(() async {
      final current = (await store.db.rows(
        'SELECT enabled,spec,revision FROM publication_source_settings WHERE id=?',
        [source.id],
      )).firstOrNull;
      token.check();
      if (current?['enabled'] != 1 ||
          current?['spec'] != jsonEncode(source.toSpec())) {
        return;
      }
      if (revision != current?['revision']) {
        await store.db.write('DELETE FROM publication_catalog WHERE source=?', [
          source.id,
        ]);
        for (final edition in editions) {
          token.check();
          await store.db.customStatement(
            'INSERT INTO publication_catalog VALUES(?,?,?,?,?)',
            [
              source.id,
              edition.id,
              edition.searchable,
              edition.isbn,
              jsonEncode(edition.toJson(includePublishedAccess: true)),
            ],
          );
        }
      }
      await store.db.write(
        'UPDATE publication_source_settings SET revision=?,synced=? WHERE id=?',
        [revision, publicationNow(), source.id],
      );
      store.db.beforeCommit(() {
        token.check();
        if (_closed || !allowed(source.name)) {
          throw const PublicationFailure(PublicationProblem.blocked);
        }
      });
    }, tables: {'publication_catalog', 'publication_source_settings'});
  }

  bool _sourceUnavailable(PublicationProblem? problem) =>
      problem == PublicationProblem.missing ||
      problem == PublicationProblem.invalid;

  PublicationCatalogue? catalogueFor(PublicationSource source) {
    final create = source.catalogue;
    return create == null
        ? null
        : _catalogues.putIfAbsent(source.id, () => create(http));
  }

  void _cancelSource(String id) {
    _catalogues.remove(id);
    _operations[id]?.cancel();
    _cancelSourceRequests(id);
  }

  void _cancelSourceRequests(String id) {
    for (final token in _sourceRequests[id] ?? const <CancellationToken>{}) {
      token.cancel();
    }
  }

  PublicationProblem _problem(Object error) => switch (error) {
    PublicationFailure(:final problem) => problem,
    TimeoutException() => PublicationProblem.timeout,
    FormatException() || TypeError() => PublicationProblem.invalid,
    _ => PublicationProblem.network,
  };

  void cancel() {
    for (final operation in _operations.values) {
      operation.cancel();
    }
    for (final search in _searches) {
      search.cancel();
    }
    for (final id in _sourceRequests.keys) {
      _cancelSourceRequests(id);
    }
  }

  void close() {
    _closed = true;
    _catalogues.clear();
    cancel();
  }
}
