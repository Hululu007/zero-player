part of 'books_repository.dart';

/// Reviews only saved works. Source, host, keyword and damaged-record
/// restrictions remain independent of this explicit adult-evidence review.
extension BookPolicyReview on BooksRepository {
  Future<List<BookPolicyReviewEntry>> bookPolicyReviewEntries() async {
    await policy.settings.prepareAuthorization?.call();
    _requireBookPolicyReview(requireReady: false);
    await ensureSourceRiskLoaded();
    final shelf = await store.shelf();
    _requireBookPolicyReview();
    final result = <BookPolicyReviewEntry>[];
    for (final saved in shelf) {
      final book = saved.book;
      final evidence = _bookPolicyEvidence[book.id];
      if (book.sourceId == 'local' ||
          evidence == null ||
          evidence.uncertain ||
          !evidence.adult ||
          _bookPolicyReviewing.contains(book.id) ||
          (_activeBookObservations[book.id] ?? 0) != 0 ||
          (_pendingBookPolicyEvidence[book.id]?.isNotEmpty ?? false) ||
          !bookAllowed(book)) {
        continue;
      }
      result.add(
        BookPolicyReviewEntry(
          book: book,
          revision: evidence.revision,
          digest: evidence.snapshotDigest,
          sourceRevision: _sourceConfigurationRevision,
          policyRevision: _bookReviewPolicyRevision,
          observationSequence: _bookObservationSequences[book.id] ?? 0,
        ),
      );
    }
    _requireBookPolicyReview();
    return result;
  }

  bool bookPolicyReviewEntryAllowed(BookPolicyReviewEntry entry) {
    try {
      _requireBookPolicyReview();
      _requireCurrentBookReview(entry);
      return !_bookPolicyReviewing.contains(entry.book.id);
    } on Exception {
      return false;
    }
  }

  Future<void> clearBookAdultEvidence(BookPolicyReviewEntry entry) async {
    await policy.settings.prepareAuthorization?.call();
    _requireBookPolicyReview(requireReady: false);
    await ensureSourceRiskLoaded();
    final beforeRegistration = beforeBookPolicyReviewRegistrationForTesting;
    if (beforeRegistration != null) await beforeRegistration();
    _requireBookPolicyReview();
    _requireCurrentBookReview(entry);
    final id = entry.book.id;
    if (!_bookPolicyReviewing.add(id)) {
      throw const FormatException('作品正在复核，请稍后重试');
    }
    final done = Completer<void>();
    _pendingEvidenceMutations.add(done);
    try {
      _bookObservationGenerations[id] =
          (_bookObservationGenerations[id] ?? 0) + 1;
      afterBookPolicyReviewRegistrationForTesting?.call();
      _bookPolicyGeneration++;
      _bookPolicyChanges.value++;
      void authorize() {
        _requireBookPolicyReview();
        _requireCurrentBookReview(entry);
      }

      var firstValidation = true;
      Future<void> validate() async {
        authorize();
        final current = await store.entry(entry.book);
        authorize();
        if (current == null ||
            jsonEncode(current.book.toJson()) !=
                jsonEncode(entry.book.toJson())) {
          throw const FormatException('书架作品已变化，请重新复核');
        }
        if (firstValidation) {
          firstValidation = false;
          final before = beforeBookPolicyReviewWriteForTesting;
          if (before != null) await before();
          authorize();
        }
      }

      final cleared = await _bookPolicyEvidenceStore.clearAdult(
        id: id,
        revision: entry.revision,
        digest: entry.digest,
        authorize: authorize,
        validate: validate,
        afterWrite: afterBookPolicyReviewWriteForTesting,
      );
      // Once committed, a later policy change does not undo the review. The
      // existing restriction stays in memory until the committed value lands.
      final after = afterBookPolicyReviewCommitForTesting;
      if (after != null) await after();
      // A concurrently loaded old source snapshot must not restore the
      // pre-review adult bit after the transaction has committed.
      _riskGeneration++;
      _bookPolicyEvidence[id] = cleared;
    } finally {
      _bookPolicyReviewing.remove(id);
      _pendingEvidenceMutations.remove(done);
      done.complete();
      _bookPolicyGeneration++;
      if (!_evidenceClosing) _bookPolicyChanges.value++;
    }
  }

  void _requireBookPolicyReview({bool requireReady = true}) {
    if (_evidenceClosing) throw const ContentBlocked();
    _requireSubscriptionAccess();
    policy.settings.authorizeAdultDisable?.call();
    if (policy.filterAdult || (requireReady && !sourceRisksReady)) {
      throw const ContentBlocked();
    }
  }

  void _requireCurrentBookReview(BookPolicyReviewEntry entry) {
    final evidence = _bookPolicyEvidence[entry.book.id];
    if (_evidenceMutations != 0 ||
        _sourceConfigurationMutations != 0 ||
        entry.sourceRevision != _sourceConfigurationRevision ||
        entry.policyRevision != _bookReviewPolicyRevision ||
        (_activeBookObservations[entry.book.id] ?? 0) != 0 ||
        entry.observationSequence !=
            (_bookObservationSequences[entry.book.id] ?? 0) ||
        (_pendingBookPolicyEvidence[entry.book.id]?.isNotEmpty ?? false) ||
        evidence == null ||
        evidence.uncertain ||
        !evidence.adult ||
        evidence.revision != entry.revision ||
        evidence.snapshotDigest != entry.digest ||
        !bookAllowed(entry.book)) {
      throw const FormatException('作品、来源或风险证据已变化，请重新复核');
    }
  }
}
