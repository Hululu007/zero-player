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

  Future<void> _refreshChangedSources() async {
    _riskGeneration++;
    _riskLoaded = false;
    _sourceRiskChanges.value++;
    try {
      await refreshSourceRisks();
    } finally {
      _sourceRiskChanges.value++;
    }
  }
}
