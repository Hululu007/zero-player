part of 'books_repository.dart';

extension _BookRepositoryMutations on BooksRepository {
  Future<T> _withEvidenceMutation<T>(
    Future<T> Function() action, {
    bool sourceConfiguration = false,
  }) async {
    if (_evidenceClosing) throw StateError('书源服务正在关闭');
    final done = Completer<void>();
    _pendingEvidenceMutations.add(done);
    _evidenceMutations++;
    if (sourceConfiguration) {
      _sourceConfigurationRevision++;
      _sourceConfigurationMutations++;
    }
    _sourceRiskChanges.value++;
    try {
      final before = beforeEvidenceMutationForTesting;
      if (before != null) await before();
      return await action();
    } finally {
      if (sourceConfiguration) _sourceConfigurationMutations--;
      _evidenceMutations--;
      _sourceRiskChanges.value++;
      _pendingEvidenceMutations.remove(done);
      done.complete();
    }
  }

  Future<void> _authorizeAndEnableComics(List<BookSource> selection) =>
      _withEvidenceMutation(() async {
        await ensureSourceRiskLoaded();
        final ids = {for (final source in selection) source.id};
        final fingerprints = {
          for (final source in selection)
            source.id: bookDownloadSourceFingerprint(source),
        };
        await comicAccess.approveAll(
          selection.where((source) => !comicAccess.allowed(source)),
          validateEnablement: () async {
            final current = (await sources(
              BookKind.comic,
            )).where((entry) => ids.contains(entry.source.id)).toList();
            if (current.length != ids.length ||
                current.any(
                  (entry) =>
                      bookDownloadSourceFingerprint(entry.source) !=
                      fingerprints[entry.source.id],
                )) {
              throw const FormatException('所选漫画渠道已变化，请刷新后重试');
            }
            return ids;
          },
        );
        await _refreshChangedSources();
      }, sourceConfiguration: true);

  Future<void> _refreshChangedSources() async {
    _sourceAccess.invalidate(unload: true);
    _sourceRiskChanges.value++;
    try {
      await refreshSourceRisks();
    } finally {
      _sourceRiskChanges.value++;
    }
  }

  Future<void> _clearSourceRisk(BookSourceRiskEntry entry) async {
    _requireSubscriptionAccess();
    await ensureSourceRiskLoaded();
    late BookSourceAssessment cleared;
    await store.db.atomic(() async {
      _requireSubscriptionAccess();
      final current = await riskStore.getRecord(
        entry.recordKey ?? entry.sourceId,
      );
      if (current == null ||
          current.sourceId != entry.sourceId ||
          current.host != entry.host ||
          current.version != entry.version ||
          (!current.adult && !current.quarantined)) {
        throw const FormatException('风险记录已变化，请刷新后复核');
      }
      if (current.key != current.sourceId &&
          current.key !=
              BookSourceRiskStore.hostKey(current.sourceId, current.host)) {
        // The host of a damaged secondary record cannot be reconstructed from
        // its hash. Do not report a successful clear that would reappear after
        // restart or discard evidence for an unknown host.
        throw const FormatException(
          '风险记录已损坏，相关来源暂不可用；普通备份不包含书源风险记录，请保留数据并从完整数据库备份恢复',
        );
      }
      final sourceEntry = await store.source(
        _verifiedSources[entry.sourceId],
        entry.sourceId,
      );
      final assessments = await riskStore.all();
      void requireReviewAllowed() {
        _requireSubscriptionAccess();
        final source = sourceEntry?.source;
        final hosts = [current.host, if (source != null) ...source.mediaHosts];
        if (source != null) hosts.add(source.endpoint.host);
        final adultRestricted =
            current.adult ||
            (source != null &&
                (adultBookSource(source) ||
                    adultBookLabels(source.name, sourceEntry!.group))) ||
            hosts.any((host) => adultBookHost(host) || knownAdultHost(host)) ||
            assessments.values.any(
              (risk) =>
                  (risk.sourceId == entry.sourceId && risk.adult) ||
                  (risk.adultHost && hosts.contains(risk.host)),
            );
        if (BookSourceAccess.fixedRisk(entry.sourceId, current.host, source) ||
            (policy.filterAdult && adultRestricted) ||
            !policy.textAllowed(
              '${source?.name ?? current.name} ${current.host}',
              category: sourceEntry?.group ?? '',
            )) {
          throw const ContentBlocked();
        }
      }

      requireReviewAllowed();
      // Retain a revision tombstone so an old review cannot clear a finding
      // that was later rediscovered after an earlier assessment was cleared.
      cleared = BookSourceAssessment(
        sourceId: current.sourceId,
        name: current.name,
        host: current.host,
        adult: false,
        quarantined: false,
        adultHost: false,
        quarantinedHost: false,
        version: current.version + 1,
        recordKey: current.key,
      );
      await riskStore.write(cleared);
      requireReviewAllowed();
    }, tables: {'app_meta'});
    _sourceAccess.rememberAssessment(cleared);
    policy.refresh();
  }
}
