part of 'books_repository.dart';

const _supervisedCheckPrefix = 'books_supervised_site_check:';
const _siteCheckPrefix = 'books_site_check:';

/// This entry point selects its own eligible built-ins and performs its own
/// bounded HTTP requests. Callers cannot submit HTML or inspection results.
extension BookSupervisedSiteScan on BooksRepository {
  Future<void> checkSupervisedBuiltinSites(
    CancellationToken cancellation,
  ) async {
    if (_evidenceClosing) throw StateError('书源服务正在关闭');
    if (_supervisedScans.isNotEmpty) {
      throw const FormatException('书源网页抽查正在进行，请稍后再试');
    }
    final token = CancellationToken();
    final done = Completer<void>();
    final unlink = cancellation.listen(token.cancel);
    final run = _SupervisedSiteRun(
      this,
      token,
      bookSitePolicySnapshot(policy),
      _sourceConfigurationRevision,
    );
    _supervisedScans.add(token);
    _supervisedScanDone.add(done);
    final cancelIfChanged = run._cancelIfChanged;
    _sourceRiskChanges.addListener(cancelIfChanged);
    policy.addListener(cancelIfChanged);
    policy.settings.addListener(cancelIfChanged);
    try {
      run._requireCurrent();
      await ensureSiteObservations();
      run._requireCurrent();
      await ensureSourceRiskLoaded();
      run._requireCurrent();
      final selected = await run._selectDue();
      await run._runWorkers(selected);
      run._requireCurrent();
    } finally {
      _sourceRiskChanges.removeListener(cancelIfChanged);
      policy.removeListener(cancelIfChanged);
      policy.settings.removeListener(cancelIfChanged);
      unlink();
      _supervisedScans.remove(token);
      _supervisedScanDone.remove(done);
      done.complete();
    }
  }

  Future<BookSourceEntry?> _supervisedCurrentSource(
    BookSourceEntry original,
  ) async {
    final verified = _verifiedSources[original.source.id];
    if (verified == null ||
        !verified.builtin ||
        verified.kind != BookKind.text ||
        bookSourceCheckFingerprint(verified) !=
            bookSourceCheckFingerprint(original.source)) {
      return null;
    }
    final current = await store.source(verified, verified.id);
    if (current == null ||
        !current.enabled ||
        !_sourceEntryAllowed(current) ||
        (await store.blockedSources()).containsKey(verified.id)) {
      return null;
    }
    return current;
  }
}

final class _SupervisedSiteRun {
  const _SupervisedSiteRun(
    this.books,
    this.token,
    this.expectedPolicy,
    this.expectedConfiguration,
  );

  final BooksRepository books;
  final CancellationToken token;
  final String expectedPolicy;
  final int expectedConfiguration;

  bool get _allowed =>
      !books._evidenceClosing &&
      !books._riskSuspended &&
      books.policy.supervision.enabled &&
      !books.policy.supervision.corrupted &&
      books.policy.settings.value.backgroundProbe &&
      bookSitePolicySnapshot(books.policy) == expectedPolicy &&
      books._sourceConfigurationRevision == expectedConfiguration &&
      books._sourceConfigurationMutations == 0;

  void _requireCurrent() {
    token.check();
    if (!_allowed) throw const RequestCancelled();
  }

  void _cancelIfChanged() {
    if (!_allowed) token.cancel();
  }

  Future<List<({BookSourceEntry entry, String revision})>> _selectDue() async {
    final available = await books.sources(BookKind.text, enabledOnly: true);
    _requireCurrent();
    final eligible = available
        .where(
          (entry) =>
              entry.source.builtin &&
              books._verifiedSources[entry.source.id] != null,
        )
        .toList();
    final revisions = await books.store.siteRevisions.ensure(
      eligible.map((entry) => entry.source.id).toSet(),
    );
    _requireCurrent();
    final saved = await _loadSiteChecks(
      books.store,
      eligible,
      _supervisedCheckPrefix,
    );
    _requireCurrent();
    final now = DateTime.now();
    final due = <({BookSourceEntry entry, String revision, int dueAt})>[];
    for (final entry in eligible) {
      _requireCurrent();
      final previous = saved[entry.source.id];
      if (previous == null || previous.isDue(now)) {
        due.add((
          entry: entry,
          revision: revisions[entry.source.id]!,
          dueAt: previous?.nextDue.millisecondsSinceEpoch ?? 0,
        ));
      }
    }
    due.sort((a, b) => a.dueAt.compareTo(b.dueAt));
    final hosts = <String>{};
    return due
        .where((item) => hosts.add(item.entry.source.endpoint.host))
        .take(20)
        .map((item) => (entry: item.entry, revision: item.revision))
        .toList();
  }

  Future<void> _runWorkers(
    List<({BookSourceEntry entry, String revision})> selected,
  ) async {
    var next = 0;
    Future<void> worker() async {
      try {
        while (next < selected.length) {
          _requireCurrent();
          final selectedSource = selected[next++];
          try {
            await _inspectOne(selectedSource.entry, selectedSource.revision);
          } on RequestCancelled {
            rethrow;
          } on Exception {
            // An unavailable source or failed write must not stop the rest.
            _requireCurrent();
          }
        }
      } catch (_) {
        token.cancel();
        rethrow;
      }
    }

    await Future.wait(
      List.generate(selected.length.clamp(0, 3), (_) => worker()),
    );
  }

  Future<void> _inspectOne(BookSourceEntry entry, String siteRevision) async {
    final current = await books._supervisedCurrentSource(entry);
    final revision = await books.store.siteRevisions.get(entry.source.id);
    _requireCurrent();
    if (current == null || revision != siteRevision) return;
    // No injectable parser or caller-provided finding can reach the privileged
    // write: the repository uses its own HTTP client.
    final inspection = await _runSiteInspection(
      () => BookSiteInspector(books._http).inspect(current.source, token),
      token,
    );
    _requireCurrent();

    Future<void> persist() async {
      BookSourceAssessment? assessment;
      final committed = await books.store.db.atomic(() async {
        _requireCurrent();
        final latest = await books._supervisedCurrentSource(entry);
        final currentRevision = await books.store.siteRevisions.get(
          entry.source.id,
        );
        _requireCurrent();
        if (latest == null || currentRevision != siteRevision) return false;
        if (inspection.gamblingRisk || inspection.adultRisk) {
          assessment = await books._addSourceAssessment(
            latest.source,
            adult: inspection.adultRisk,
            quarantine: inspection.gamblingRisk,
            rootPageEvidence: true,
          );
        }
        _requireCurrent();
        final previous = await _readSiteCheck(
          books.store,
          '$_supervisedCheckPrefix${latest.source.id}',
          latest.source,
          revision: siteRevision,
        );
        // A manual full sample may have cleared an older supervised clue.
        final shared = await _readSiteCheck(
          books.store,
          '$_siteCheckPrefix${latest.source.id}',
          latest.source,
          revision: siteRevision,
        );
        _requireCurrent();
        final check = BookSiteCheck.after(
          inspection,
          DateTime.now(),
          latest.source,
          previous,
          scriptHistoryPrevious: shared,
          siteRevision: siteRevision,
        );
        _requireCurrent();
        await books.store.write(
          '$_supervisedCheckPrefix${latest.source.id}',
          check.toJson(),
        );
        await books.store.write(
          '$_siteCheckPrefix${latest.source.id}',
          check.toJson(),
        );
        await _recordObservedSiteSource(books.store, latest.source);
        _requireCurrent();
        if (await books.store.siteRevisions.get(entry.source.id) !=
            siteRevision) {
          throw const _StaleSiteCheck();
        }
        return true;
      }, tables: {'app_meta'});
      if (committed && assessment != null) {
        books._rememberAssessment(assessment!);
        books.policy.refresh();
      }
    }

    if (inspection.gamblingRisk || inspection.adultRisk) {
      await books._withEvidenceMutation(persist);
    } else {
      await persist();
    }
    _requireCurrent();
  }
}
