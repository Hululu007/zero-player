import 'dart:async';
import 'dart:convert';

import '../../../core/network/cancellation_token.dart';
import '../data/publication_http.dart';
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
});

final class PublicationDiscovery {
  PublicationDiscovery(this.store, this.http, this.allowed);
  final PublicationStore store;
  final PublicationHttp http;
  final bool Function(String) allowed;
  final _operations = <String, CancellationToken>{};
  final _searches = <CancellationToken>{};
  final _sourceSearches = <String, Set<CancellationToken>>{};
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
        if (row['spec'] is String)
          _status(
            PublicationSource.configure(
              jsonDecode(row['spec'] as String) as Map,
              id: row['id'] as String,
            ),
            row,
          ),
    ];
    return [
      ...sources.where((item) => item.favorite),
      ...sources.where((item) => !item.favorite),
    ];
  }

  PublicationSourceStatus _status(
    PublicationSource source,
    Map<String, Object?>? row,
  ) {
    final enabled =
        !source.restricted &&
        (row == null ? source.enabledByDefault : row['enabled'] == 1);
    final problem = row?['failure'] == null
        ? null
        : PublicationProblem.values.byName(row!['failure'] as String);
    final hasSnapshot =
        source.kind == PublicationSourceKind.snapshot &&
        row?['revision'] != null;
    return (
      source: source,
      enabled: enabled,
      paused: enabled && !hasSnapshot && _sourceUnavailable(problem),
      favorite: row?['favorite'] == 1,
      problem: problem,
      checked: row?['checked'] as int?,
      synced: row?['synced'] as int?,
      revision: row?['revision'] as String?,
      hasSnapshot: hasSnapshot,
    );
  }

  Future<void> setEnabled(PublicationSource source, bool enabled) async {
    await store.initialize();
    if (source.restricted || !allowed(source.name)) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
    await store.db.write(
      'INSERT INTO publication_source_settings(id,enabled) VALUES(?,?) '
      'ON CONFLICT(id) DO UPDATE SET enabled=excluded.enabled',
      [source.id, enabled ? 1 : 0],
    );
    if (!enabled) _cancelSource(source.id);
  }

  Future<void> setFavorite(PublicationSource source, bool favorite) async {
    await store.initialize();
    if (source.restricted || !allowed(source.name)) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
    await store.db.write(
      'INSERT INTO publication_source_settings(id,enabled,favorite) VALUES(?,?,?) '
      'ON CONFLICT(id) DO UPDATE SET favorite=excluded.favorite',
      [source.id, source.enabledByDefault ? 1 : 0, favorite ? 1 : 0],
    );
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
    if (id == null && available.length >= 32) {
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
    if (!source.configurable || !allowed(source.name)) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
    await store.initialize();
    await store.db.atomic(() async {
      await store.db.write(
        'DELETE FROM publication_source_settings WHERE id=?',
        [source.id],
      );
      await store.db.write('DELETE FROM publication_catalog WHERE source=?', [
        source.id,
      ]);
    }, tables: {'publication_source_settings', 'publication_catalog'});
    _cancelSource(source.id);
  }

  Stream<PublicationSearchUpdate> search(
    String raw,
    CancellationToken token, {
    int maxPages = 3,
  }) async* {
    final query = publicationLabel(raw, max: 160);
    if (_closed || !allowed(query)) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
    _searches.add(token);
    try {
      final enabled = (await sources()).where(_mayUse).toList();
      final updates = StreamController<PublicationSearchUpdate>();
      var index = 0;
      Future<void> worker() async {
        while (!token.isCancelled && !_closed && index < enabled.length) {
          final source = enabled[index++].source;
          final result = await _searchSource(
            source,
            query,
            token,
            maxPages.clamp(1, 5),
          );
          if (result != null && !token.isCancelled) updates.add(result);
        }
      }

      unawaited(
        Future.wait(List.generate(3, (_) => worker()))
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
    int maxPages,
  ) async {
    final active = _sourceSearches.putIfAbsent(source.id, () => {});
    final token = CancellationToken();
    active.add(token);
    final detach = parent.listen(token.cancel);
    try {
      if (!await _canSearch(source, token)) return null;
      List<PublicationEdition> editions = const [];
      PublicationProblem? problem;
      try {
        editions = await _query(source, query, token, maxPages: maxPages);
      } on RequestCancelled {
        return null;
      } catch (error) {
        problem = _problem(error);
      }
      if (!await _canSearch(source, token)) return null;
      return (
        source: source,
        editions: editions
            .where((row) => allowed('${row.title} ${row.author}'))
            .toList(),
        problem: problem,
      );
    } finally {
      detach();
      active.remove(token);
      if (active.isEmpty) _sourceSearches.remove(source.id);
    }
  }

  Future<bool> _canSearch(
    PublicationSource source,
    CancellationToken token,
  ) async {
    if (token.isCancelled) return false;
    final current = await enabledSource(source.id);
    return !token.isCancelled &&
        current != null &&
        current.sameConfiguration(source);
  }

  Future<bool> isEnabled(String id) async =>
      id == 'manual' || await enabledSource(id) != null;

  Future<PublicationSource?> enabledSource(String id) async {
    final entry = await _sourceStatus(id);
    return entry != null && _mayUse(entry) ? entry.source : null;
  }

  Future<PublicationSourceStatus?> _sourceStatus(String id) async =>
      (await sources()).where((item) => item.source.id == id).firstOrNull;

  bool _mayUse(PublicationSourceStatus item) =>
      item.enabled &&
      !item.paused &&
      allowed('${item.source.name} ${item.source.endpoint.host}');

  Future<void> checkDue() =>
      _checkingDue ??= _checkDue().whenComplete(() => _checkingDue = null);

  Future<void> _checkDue() async {
    final before = publicationNow() - const Duration(hours: 24).inMilliseconds;
    for (final item in await sources()) {
      if (_closed) return;
      if (_mayUse(item) && (item.checked ?? 0) < before) {
        await check(item.source);
      }
    }
  }

  Future<void> check(PublicationSource requested) async {
    if (_closed || _operations.containsKey(requested.id)) return;
    final current = await _sourceStatus(requested.id);
    if (current == null ||
        !current.enabled ||
        _closed ||
        _operations.containsKey(requested.id)) {
      return;
    }
    final source = current.source;
    if (source.restricted ||
        !allowed('${source.name} ${source.endpoint.host}')) {
      return;
    }
    final token = _operations[source.id] = CancellationToken();
    PublicationProblem? failure;
    try {
      if (source.kind == PublicationSourceKind.snapshot) {
        await _sync(source, token);
      } else if (source.kind == PublicationSourceKind.releases) {
        final response = await http.open(
          pinnedPublication(source).candidates.first.link,
          token,
          range: 'bytes=0-3',
          scope: (uri) => restrictPinnedPublication(source, uri),
        );
        try {
          if (response.response.statusCode != 206 &&
              response.response.statusCode != 200) {
            throw publicationHttpFailure(response);
          }
          if (response.response.headers.contentType?.mimeType == 'text/html') {
            throw const PublicationFailure(PublicationProblem.invalid);
          }
        } finally {
          await discardPublicationResponse(response);
        }
      } else {
        await _query(
          source,
          source.kind == PublicationSourceKind.openTextbooks
              ? 'Think Python'
              : '',
          token,
          maxPages: 1,
        );
      }
    } on RequestCancelled {
      return;
    } catch (error) {
      failure = _problem(error);
    } finally {
      _operations.remove(source.id);
    }
    if (token.isCancelled || _closed || !allowed(source.name)) return;
    if (source.configurable) {
      await store.db.write(
        'UPDATE publication_source_settings SET failure=?,checked=? '
        'WHERE id=? AND enabled=1 AND spec=?',
        [
          failure?.name,
          publicationNow(),
          source.id,
          jsonEncode(source.toSpec()),
        ],
      );
    } else {
      await store.db.write(
        'INSERT INTO publication_source_settings(id,enabled,failure,checked) VALUES(?,1,?,?) '
        'ON CONFLICT(id) DO UPDATE SET failure=excluded.failure,checked=excluded.checked '
        'WHERE enabled=1',
        [source.id, failure?.name, publicationNow()],
      );
    }
    if (_sourceUnavailable(failure) &&
        (await _sourceStatus(source.id))?.paused == true) {
      _cancelSourceSearches(source.id);
    }
  }

  Future<List<PublicationEdition>> _query(
    PublicationSource source,
    String query,
    CancellationToken token, {
    int maxPages = 3,
  }) async {
    if (source.kind == PublicationSourceKind.releases) {
      final edition = pinnedPublication(source);
      return [if (edition.matches(query)) edition];
    }
    if (source.kind == PublicationSourceKind.snapshot) {
      return _snapshot(source, query);
    }
    final found = <String, PublicationEdition>{};
    final visited = <Uri>{};
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
              source.pageParameter: '$page',
            },
          );
      if (!visited.add(uri)) break;
      final data = await http.text(uri, token, scope: source.restrict);
      final rows = source.kind == PublicationSourceKind.openTextbooks
          ? openTextbookRows(source, data)
          : configuredPublicationRows(source, data, maxRows: 100, base: uri);
      if (rows.isEmpty) break;
      final before = found.length;
      final matches = rows.where(
        (row) =>
            row.matches(query) &&
            allowed('${row.title} ${row.author}') &&
            !found.containsKey(row.id),
      );
      final limit = source.rule == null
          ? rows.length
          : source.rule!.detail.isNotEmpty
          ? 8
          : 20;
      final resolved = await Future.wait([
        for (final row in matches.take(limit))
          _resolveDetails(source, row, token),
      ]);
      for (final row in resolved) {
        found.putIfAbsent(row.id, () => row);
      }
      if (found.length >= (source.rule == null ? 20 : 60) ||
          (query.isEmpty && source.rule == null) ||
          (page > 1 && before == found.length)) {
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
      final data = await http.text(page, token, scope: source.restrict);
      token.check();
      return row.withCandidates(configuredDetailCandidates(source, data, page));
    } on RequestCancelled {
      rethrow;
    } on Exception {
      return row;
    }
  }

  Future<List<PublicationEdition>> _snapshot(
    PublicationSource source,
    String query,
  ) async {
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
    return rows
        .map(
          (row) => PublicationEdition.fromJson(
            jsonDecode(row['data'] as String) as Map,
            includePublishedAccess: true,
          ),
        )
        .toList();
  }

  Future<void> _sync(PublicationSource source, CancellationToken token) async {
    final raw = await http.text(
      source.endpoint,
      token,
      maxBytes: 4 << 20,
      scope: source.restrict,
    );
    final revision = publicationId('catalog:2\n$raw');
    final editions = configuredPublicationRows(source, raw);
    if (editions.isEmpty) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
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

  void _cancelSource(String id) {
    _operations[id]?.cancel();
    _cancelSourceSearches(id);
  }

  void _cancelSourceSearches(String id) {
    for (final token in _sourceSearches[id] ?? const <CancellationToken>{}) {
      token.cancel();
    }
  }

  PublicationProblem _problem(Object error) => switch (error) {
    PublicationFailure(:final problem) => problem,
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
  }

  void close() {
    _closed = true;
    cancel();
  }
}
