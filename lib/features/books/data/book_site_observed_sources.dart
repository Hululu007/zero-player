part of 'books_repository.dart';

const _siteObservedPrefix = 'books_site_observed_fingerprint:';
const _missingSiteSource = 'missing';

/// Increase when homepage or script-clue interpretation changes, so previous
/// samples are revisited without clearing their history or strong risk marks.
const bookSiteInspectionRevision = 1;

Map<String, Object> _siteObservedValue(String fingerprint) => {
  'fingerprint': fingerprint,
  'inspectionRevision': bookSiteInspectionRevision,
};

/// Keep the last effective source version without retaining old host data.
/// Call this inside the same transaction as the current sample write.
Future<void> _recordObservedSiteSource(BookStore store, BookSource source) =>
    store.db.customStatement(BookSiteRevisions.upsertSql, [
      '$_siteObservedPrefix${source.id}',
      jsonEncode(_siteObservedValue(bookSourceCheckFingerprint(source))),
    ]);

extension BookSiteSourceObservation on BooksRepository {
  /// Observe local configuration at startup and before exposing old checks.
  /// This performs no requests and does not execute source rules.
  Future<void> ensureSiteObservations() {
    if (_evidenceClosing || _riskSuspended) {
      return Future.error(const RequestCancelled());
    }
    final existing = _siteObservation;
    if (existing != null) return existing;
    final done = Completer<void>();
    _pendingEvidenceMutations.add(done);
    final pending = _observeSiteSources(done, _siteObservationRestoreRevision);
    _siteObservation = pending;
    // Failed initialization must not bless an old sample, and can be retried.
    unawaited(
      pending.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_siteObservation, pending)) _siteObservation = null;
        },
      ),
    );
    return pending;
  }

  void _requireSiteObservationAllowed(int restoreRevision) {
    // A normally closing repository waits for already registered observation
    // to commit; otherwise a quick exit could hide an intermediate version.
    if (_riskSuspended || restoreRevision != _siteObservationRestoreRevision) {
      throw const RequestCancelled();
    }
  }

  Future<void> _observeSiteSources(
    Completer<void> done,
    int restoreRevision,
  ) async {
    try {
      void requireAllowed() => _requireSiteObservationAllowed(restoreRevision);
      final observer = _SiteObservedSources(store);
      // New installations have no sample whose freshness could be inherited.
      // Avoid loading the catalog and creating asset work until it is needed.
      final tracked = await observer.hasTrackedSamples();
      requireAllowed();
      if (!tracked) return;
      final builtins = await _builtins;
      requireAllowed();
      await observer.observe(
        builtins,
        requireAllowed: requireAllowed,
        beforeTransaction: beforeSiteObservationTransactionForTesting,
        afterWrite: afterSiteObservationWriteForTesting,
      );
    } finally {
      _pendingEvidenceMutations.remove(done);
      done.complete();
    }
  }
}

final class _SiteObservedSources {
  const _SiteObservedSources(this.store);

  final BookStore store;

  Future<bool> hasTrackedSamples() async {
    final rows = await store.db.rows(
      'SELECT 1 FROM app_meta WHERE key GLOB ? OR key GLOB ? '
      'OR key GLOB ? LIMIT 1',
      [
        '$_siteCheckPrefix*',
        '$_supervisedCheckPrefix*',
        '$_siteObservedPrefix*',
      ],
    );
    return rows.isNotEmpty;
  }

  Future<void> observe(
    List<BookSource> builtins, {
    required void Function() requireAllowed,
    Future<void> Function()? beforeTransaction,
    Future<void> Function()? afterWrite,
  }) async {
    final pending = await _changes(builtins);
    requireAllowed();
    if (pending.isEmpty) return;
    if (beforeTransaction != null) await beforeTransaction();
    requireAllowed();
    var changed = false;
    await store.db.transaction(() async {
      requireAllowed();
      // Re-read under the write transaction: an import or delete may have
      // changed the effective source after the initial, read-only snapshot.
      final current = await _changes(builtins);
      requireAllowed();
      if (current.isEmpty) return;
      await store.db.batch((batch) {
        for (final entry in current.entries) {
          batch.customStatement(BookSiteRevisions.upsertSql, [
            BookSiteRevisions.key(entry.key),
            jsonEncode(BookSiteRevisions.newToken()),
          ]);
          batch.customStatement(BookSiteRevisions.upsertSql, [
            '$_siteObservedPrefix${entry.key}',
            jsonEncode(_siteObservedValue(entry.value)),
          ]);
        }
      });
      if (afterWrite != null) await afterWrite();
      requireAllowed();
      changed = true;
    });
    // A completed commit must always be published, including during shutdown.
    if (changed) store.db.changed(tables: {'app_meta'});
  }

  Future<Map<String, String>> _changes(List<BookSource> builtins) async {
    final rows = await store.db.rows(
      'SELECT key,value FROM app_meta WHERE key GLOB ? OR key GLOB ? '
      'OR key GLOB ? OR key GLOB ?',
      [
        '$_siteCheckPrefix*',
        '$_supervisedCheckPrefix*',
        '$_siteObservedPrefix*',
        '${BookSiteRevisions.prefix}*',
      ],
    );
    final tracked = <String>{};
    final observed = <String, String>{};
    final revisions = <String, String>{};
    for (final row in rows) {
      final key = row['key'];
      if (key is! String) continue;
      if (key.startsWith(_siteObservedPrefix)) {
        final id = key.substring(_siteObservedPrefix.length);
        tracked.add(id);
        final fingerprint = _decodeFingerprint(row['value']);
        if (fingerprint != null) observed[id] = fingerprint;
      } else if (key.startsWith(_siteCheckPrefix)) {
        tracked.add(key.substring(_siteCheckPrefix.length));
      } else if (key.startsWith(_supervisedCheckPrefix)) {
        tracked.add(key.substring(_supervisedCheckPrefix.length));
      } else if (key.startsWith(BookSiteRevisions.prefix)) {
        final revision = BookSiteRevisions.decode(row['value']);
        if (revision != null) {
          revisions[key.substring(BookSiteRevisions.prefix.length)] = revision;
        }
      }
    }
    if (tracked.isEmpty) return {};
    final sources = {
      for (final entry in await store.sources(builtins))
        entry.source.id: entry.source,
    };
    final result = <String, String>{};
    for (final id in tracked) {
      final source = sources[id];
      final fingerprint = source == null
          ? _missingSiteSource
          : bookSourceCheckFingerprint(source);
      if (observed[id] != fingerprint || !revisions.containsKey(id)) {
        result[id] = fingerprint;
      }
    }
    return result;
  }

  String? _decodeFingerprint(Object? raw) {
    if (raw is! String) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map ||
          value['inspectionRevision'] != bookSiteInspectionRevision) {
        return null;
      }
      final fingerprint = value['fingerprint'];
      return fingerprint is String &&
              (fingerprint == _missingSiteSource ||
                  RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint))
          ? fingerprint
          : null;
    } on FormatException {
      return null;
    }
  }
}
