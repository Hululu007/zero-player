part of 'books_repository.dart';

const _prefix = 'books_site_check:';

Future<BookSiteInspection> _runSiteInspection(
  Future<BookSiteInspection> Function() inspect,
  CancellationToken token,
) async {
  try {
    return await inspect();
  } on RequestCancelled {
    rethrow;
  } on FormatException {
    token.check();
    return const BookSiteInspection(BookSiteFinding.unsupported);
  } on Exception {
    token.check();
    return const BookSiteInspection(BookSiteFinding.networkError);
  }
}

Future<BookSiteCheck?> _readSiteCheck(
  BookStore store,
  String key,
  BookSource source, {
  required String? revision,
}) async {
  try {
    return BookSiteCheck.fromJson(
      await store.read(key),
      source,
      currentRevision: revision,
      requireRevision: true,
    );
  } on FormatException {
    return null;
  } on TypeError {
    return null;
  }
}

/// Read check metadata and all generation tokens in one database snapshot.
Future<Map<String, BookSiteCheck>> _loadSiteChecks(
  BookStore store,
  List<BookSourceEntry> entries,
  String prefix,
) async {
  final sources = {for (final entry in entries) entry.source.id: entry.source};
  final rows = await store.db.rows(
    'SELECT key,value FROM app_meta WHERE key GLOB ? OR key GLOB ?',
    ['$prefix*', '${BookSiteRevisions.prefix}*'],
  );
  final revisions = <String, String>{};
  for (final row in rows) {
    final key = row['key'];
    if (key is! String || !key.startsWith(BookSiteRevisions.prefix)) continue;
    final token = BookSiteRevisions.decode(row['value']);
    if (token != null) {
      revisions[key.substring(BookSiteRevisions.prefix.length)] = token;
    }
  }
  final result = <String, BookSiteCheck>{};
  for (final row in rows) {
    final key = row['key'];
    if (key is! String || !key.startsWith(prefix)) continue;
    final id = key.substring(prefix.length);
    final source = sources[id];
    if (source == null) continue;
    try {
      final check = BookSiteCheck.fromJson(
        jsonDecode(row['value'] as String),
        source,
        currentRevision: revisions[id],
        requireRevision: true,
      );
      if (check != null) result[id] = check;
    } on FormatException {
      // Keep damaged metadata untouched; it is not evidence of a site check.
    } on TypeError {
      // A restored or older entry may have an unexpected value.
    }
  }
  return result;
}

final class BookSiteCheckSummary {
  const BookSiteCheckSummary({
    required this.checked,
    required this.skipped,
    required this.failed,
    required this.quarantined,
    required this.adult,
  });
  final int checked, skipped, failed, quarantined, adult;
}

/// Homepage-only checks. Results never change source enable/favorite settings.
/// Risk markers are monotonic and are changed by the repository separately.
final class BookSiteChecks {
  BookSiteChecks(
    this.books, {
    Future<BookSiteInspection> Function(BookSource, CancellationToken)? inspect,
  }) : _inspect =
           inspect ?? BookSiteInspector(books.client.network.http).inspect;
  final BooksRepository books;
  final Future<BookSiteInspection> Function(BookSource, CancellationToken)
  _inspect;
  bool _running = false;

  Future<Map<String, BookSiteCheck>> load(List<BookSourceEntry> entries) async {
    await books.ensureSiteObservations();
    return _loadSiteChecks(books.store, entries, _prefix);
  }

  Future<BookSiteCheckSummary> run(
    List<BookSourceEntry> entries,
    CancellationToken cancellation, {
    bool enabledOnly = false,
    void Function(int processed, int total)? onProgress,
  }) async {
    if (_running) throw const FormatException('书源网页抽查正在进行，请稍后再试');
    final lease = _acquireSiteScanLease(
      books,
      cancellation,
      useCallerToken: true,
    );
    _running = true;
    try {
      return await _runBatch(
        entries,
        lease.token,
        enabledOnly: enabledOnly,
        onProgress: onProgress,
      );
    } finally {
      _running = false;
      lease.release(books);
    }
  }

  Future<BookSiteCheckSummary> _runBatch(
    List<BookSourceEntry> entries,
    CancellationToken token, {
    required bool enabledOnly,
    void Function(int processed, int total)? onProgress,
  }) async {
    var next = 0, checked = 0, skipped = 0, failed = 0;
    var processed = 0, quarantined = 0, adult = 0;
    final policySnapshot = bookSitePolicySnapshot(books.policy);
    final configurationSnapshot = books.sourceConfigurationRevision;
    final hostResults = <String, Future<BookSiteInspection>>{};
    final hostMarks = <String, Future<bool>>{};
    var revisions = <String, String>{};
    Future<void> worker() async {
      try {
        while (next < entries.length) {
          token.check();
          final entry = entries[next++];
          try {
            final check = await _check(
              entry,
              token,
              hostResults,
              hostMarks,
              enabledOnly,
              policySnapshot,
              configurationSnapshot,
              revisions[entry.source.id]!,
            );
            if (check == null) {
              skipped++;
            } else {
              if (check.needsRetry) {
                failed++;
              } else {
                checked++;
              }
              if (check.inspection.gamblingRisk) quarantined++;
              if (check.inspection.adultRisk) adult++;
            }
          } on RequestCancelled {
            rethrow;
          } on Exception {
            // A changed/deleted source or a failed write must not prevent other
            // sites from being checked. A revoked policy still cancels all.
            _checkPolicy(token, policySnapshot);
            failed++;
          }
          onProgress?.call(++processed, entries.length);
        }
      } catch (_) {
        token.cancel();
        rethrow;
      }
    }

    // The current snapshot can return to its original value while a request
    // is in flight. Latch cancellation on the first effective policy change;
    // an ordinary risk refresh has the same snapshot and keeps the batch alive.
    void policyChanged() {
      if (bookSitePolicySnapshot(books.policy) != policySnapshot) {
        token.cancel();
      }
    }

    books.policy.addListener(policyChanged);
    try {
      _checkPolicy(token, policySnapshot);
      await books.ensureSiteObservations();
      _checkPolicy(token, policySnapshot);
      revisions = await books.store.siteRevisions.ensure(
        entries.map((entry) => entry.source.id).toSet(),
      );
      _checkPolicy(token, policySnapshot);
      await Future.wait(
        List.generate(entries.length.clamp(0, 3), (_) => worker()),
      );
      _checkPolicy(token, policySnapshot);
      return BookSiteCheckSummary(
        checked: checked,
        skipped: skipped,
        failed: failed,
        quarantined: quarantined,
        adult: adult,
      );
    } finally {
      books.policy.removeListener(policyChanged);
    }
  }

  Future<BookSiteCheck?> _check(
    BookSourceEntry entry,
    CancellationToken token,
    Map<String, Future<BookSiteInspection>> hostResults,
    Map<String, Future<bool>> hostMarks,
    bool enabledOnly,
    String policySnapshot,
    int configurationSnapshot,
    String siteRevision,
  ) async {
    _checkPolicy(token, policySnapshot);
    if (!_configurationCurrent(configurationSnapshot)) return null;
    var current = await books.sourceEntry(entry.source.kind, entry.source.id);
    _checkPolicy(token, policySnapshot);
    if (!_configurationCurrent(configurationSnapshot) ||
        !_sameSource(current, entry, enabledOnly)) {
      return null;
    }
    if (await books.store.siteRevisions.get(entry.source.id) != siteRevision) {
      return null;
    }
    _checkPolicy(token, policySnapshot);
    final inspection = await hostResults.putIfAbsent(
      entry.source.endpoint.host,
      () => _runSiteInspection(() => _inspect(entry.source, token), token),
    );
    _checkPolicy(token, policySnapshot);
    current = await books.sourceEntry(entry.source.kind, entry.source.id);
    _checkPolicy(token, policySnapshot);
    if (!_configurationCurrent(configurationSnapshot) ||
        !_sameSource(current, entry, enabledOnly)) {
      return null;
    }
    if (inspection.gamblingRisk || inspection.adultRisk) {
      final marked = await _markHost(
        entry,
        inspection,
        token,
        hostMarks,
        enabledOnly,
        policySnapshot,
        configurationSnapshot,
        siteRevision,
      );
      if (!marked) return null;
    }
    _checkPolicy(token, policySnapshot);
    try {
      final saved = await books.store.db.atomic(() async {
        _checkPolicy(token, policySnapshot);
        final current = await books.store.source(
          books._verifiedSources[entry.source.id],
          entry.source.id,
        );
        _checkPolicy(token, policySnapshot);
        if (!_configurationCurrent(configurationSnapshot) ||
            !_sameSource(current, entry, enabledOnly) ||
            !books.policy.textAllowed('', category: current!.group) ||
            (await books.store.blockedSources()).containsKey(entry.source.id)) {
          return null;
        }
        _checkPolicy(token, policySnapshot);
        if (await books.store.siteRevisions.get(entry.source.id) !=
            siteRevision) {
          throw const _StaleSiteCheck();
        }
        final previous = await _readSiteCheck(
          books.store,
          '$_prefix${entry.source.id}',
          entry.source,
          revision: siteRevision,
        );
        final check = BookSiteCheck.after(
          inspection,
          DateTime.now(),
          entry.source,
          previous,
          siteRevision: siteRevision,
        );
        _checkPolicy(token, policySnapshot);
        await books.store.write('$_prefix${entry.source.id}', check.toJson());
        await _recordObservedSiteSource(books.store, entry.source);
        _checkPolicy(token, policySnapshot);
        if (!_configurationCurrent(configurationSnapshot) ||
            await books.store.siteRevisions.get(entry.source.id) !=
                siteRevision) {
          throw const _StaleSiteCheck();
        }
        return check;
      }, tables: {'app_meta'});
      return saved;
    } on _StaleSiteCheck {
      return null;
    }
  }

  Future<bool> _markHost(
    BookSourceEntry entry,
    BookSiteInspection inspection,
    CancellationToken token,
    Map<String, Future<bool>> hostMarks,
    bool enabledOnly,
    String policySnapshot,
    int configurationSnapshot,
    String siteRevision,
  ) async {
    final host = entry.source.endpoint.host;
    while (true) {
      _checkPolicy(token, policySnapshot);
      if (!_configurationCurrent(configurationSnapshot)) return false;
      final running = hostMarks[host];
      if (running != null) {
        final marked = await running;
        if (marked) return true;
        if (identical(hostMarks[host], running)) hostMarks.remove(host);
        continue;
      }
      final pending = _commitSiteRisk(
        entry,
        inspection,
        token,
        enabledOnly,
        policySnapshot,
        configurationSnapshot,
        siteRevision,
      );
      hostMarks[host] = pending;
      try {
        final marked = await pending;
        if (!marked && identical(hostMarks[host], pending)) {
          hostMarks.remove(host);
        }
        return marked;
      } catch (_) {
        if (identical(hostMarks[host], pending)) hostMarks.remove(host);
        rethrow;
      }
    }
  }

  Future<bool> _commitSiteRisk(
    BookSourceEntry entry,
    BookSiteInspection inspection,
    CancellationToken token,
    bool enabledOnly,
    String policySnapshot,
    int configurationSnapshot,
    String siteRevision,
  ) => books._withEvidenceMutation(() async {
    _checkPolicy(token, policySnapshot);
    books._requireSubscriptionAccess();
    BookSourceAssessment? assessment;
    try {
      await books.store.db.atomic(() async {
        Future<void> requireCurrent() async {
          _checkPolicy(token, policySnapshot);
          books._requireSubscriptionAccess();
          if (!_configurationCurrent(configurationSnapshot)) {
            throw const _StaleSiteCheck();
          }
          final current = await books.store.source(
            books._verifiedSources[entry.source.id],
            entry.source.id,
          );
          final blocked = await books.store.blockedSources();
          final revision = await books.store.siteRevisions.get(entry.source.id);
          _checkPolicy(token, policySnapshot);
          books._requireSubscriptionAccess();
          if (!_configurationCurrent(configurationSnapshot) ||
              !_sameSource(current, entry, enabledOnly) ||
              revision != siteRevision ||
              !books._sourceEntryAllowed(current!) ||
              blocked.containsKey(entry.source.id)) {
            throw const _StaleSiteCheck();
          }
        }

        await requireCurrent();
        assessment = await books._addSourceAssessment(
          entry.source,
          adult: inspection.adultRisk,
          quarantine: inspection.gamblingRisk,
          rootPageEvidence: true,
        );
        final afterWrite = books.afterSiteRiskWriteForTesting;
        if (afterWrite != null) await afterWrite();
        // Cancellation through this final in-transaction check rolls back the
        // write. Once asynchronous COMMIT begins, it cannot be guaranteed to
        // undo the write; a successful commit must still be published below.
        await requireCurrent();
      }, tables: {'app_meta'});
    } on _StaleSiteCheck {
      return false;
    }
    final afterCommit = books.afterSiteRiskCommitForTesting;
    try {
      if (afterCommit != null) await afterCommit();
    } finally {
      // Publish before the mutation-complete notification, even if a caller
      // cancels immediately after the transaction has committed.
      books._rememberAssessment(assessment!);
      books.policy.refresh();
    }
    return true;
  });

  bool _configurationCurrent(int expected) =>
      books.sourceConfigurationRevision == expected &&
      !books.sourceConfigurationChanging;

  void _checkPolicy(CancellationToken token, String expected) {
    token.check();
    if (books.sourceRisksSuspended) throw const RequestCancelled();
    books.policy.supervision.require(SensitiveOperation.channels);
    if (bookSitePolicySnapshot(books.policy) != expected) {
      throw const RequestCancelled();
    }
  }

  bool _sameSource(
    BookSourceEntry? current,
    BookSourceEntry original,
    bool enabledOnly,
  ) =>
      current != null &&
      (!enabledOnly || current.enabled) &&
      bookSourceCheckFingerprint(current.source) ==
          bookSourceCheckFingerprint(original.source);
}

final class _StaleSiteCheck implements Exception {
  const _StaleSiteCheck();
}
