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
      final evidence = _bookPolicy.reviewableEvidence(book.id);
      if (book.sourceId == 'local' || evidence == null || !bookAllowed(book)) {
        continue;
      }
      result.add(
        BookPolicyReviewEntry(
          book: book,
          revision: evidence.revision,
          digest: evidence.snapshotDigest,
          sourceRevision: _sourceConfigurationRevision,
          policyRevision: _bookPolicy.policyRevision,
          observationSequence: _bookPolicy.observationSequence(book.id),
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
      return !_bookPolicy.reviewing(entry.book.id);
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
    final review = _bookPolicy.startReview(id);
    final done = Completer<void>();
    _pendingEvidenceMutations.add(done);
    try {
      afterBookPolicyReviewRegistrationForTesting?.call();
      review.notifyStarted();
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
      _sourceAccess.invalidate();
      review.publish(cleared);
    } finally {
      review.close();
      _pendingEvidenceMutations.remove(done);
      done.complete();
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
    if (_evidenceMutations != 0 ||
        _sourceConfigurationMutations != 0 ||
        entry.sourceRevision != _sourceConfigurationRevision ||
        entry.policyRevision != _bookPolicy.policyRevision ||
        !_bookPolicy.matchesReview(entry) ||
        !bookAllowed(entry.book)) {
      throw const FormatException('作品、来源或风险证据已变化，请重新复核');
    }
  }
}
