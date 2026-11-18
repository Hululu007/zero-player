import 'package:flutter/foundation.dart';

import '../../../core/network/cancellation_token.dart';
import '../../supervision/application/content_policy.dart';
import '../application/book_category_policy.dart';
import '../domain/book.dart';
import 'book_policy_evidence.dart';

/// Owns work observations, pending/committed evidence and review locks.
/// Source leases, authorization and shutdown draining belong to the caller.
final class BookPolicyTracker {
  BookPolicyTracker({required this.policy, required this.store}) {
    policy.addListener(_policyChanged);
  }

  final ContentPolicy policy;
  final BookPolicyEvidenceStore store;
  final _evidence = <String, BookPolicyEvidence>{};
  final _pending = <String, Map<Object, BookPolicyEvidence>>{};
  final _observations = <String, Set<BookPolicyObservation>>{};
  final _observationGenerations = <String, int>{};
  final _sequences = <String, int>{};
  final _reviews = <String, BookPolicyReviewLease>{};
  final _changes = ValueNotifier<int>(0);
  final _observationChanges = ValueNotifier<int>(0);
  int _generation = 0, _policyRevision = 0;
  bool _closing = false;

  Listenable get changes => _changes;
  Listenable get observationChanges => _observationChanges;
  int get generation => _generation;
  int get policyRevision => _policyRevision;
  int observationSequence(String id) => _sequences[id] ?? 0;
  int pendingCount(String id) => _pending[id]?.length ?? 0;
  bool reviewing(String id) => _reviews.containsKey(id);
  bool _busy(String id) =>
      (_observations[id]?.isNotEmpty ?? false) || pendingCount(id) != 0;

  void _policyChanged() => _policyRevision++;

  void _changed() {
    _generation++;
    if (!_closing) _changes.value++;
  }

  void mergeLoaded(Map<String, BookPolicyEvidence> snapshot) {
    for (final entry in snapshot.entries) {
      _evidence.update(
        entry.key,
        (current) => current.mergeLoadedSnapshot(entry.value),
        ifAbsent: () => entry.value,
      );
    }
  }

  static ({String category, String text, String stableText}) _metadata(
    Book book,
  ) => (
    category: book.category,
    text:
        '${book.title} ${book.author} ${book.description} ${book.category} '
        '${book.latestChapter} ${book.updatedLabel} ${book.rankLabel} ${book.uri.host}',
    stableText:
        '${book.title} ${book.author} ${book.description} ${book.category}',
  );

  bool metadataAllowed(Book book) {
    final metadata = _metadata(book);
    return bookCategoryTextAllowed(policy, metadata.category) &&
        policy.textAllowed(metadata.text);
  }

  bool allows(Book book) =>
      metadataAllowed(book) &&
      !(_pending[book.id]?.values.any((value) => value.blocks(policy)) ??
          false) &&
      !(_evidence[book.id]?.blocks(policy) ?? false);

  BookPolicyObservation startObservation(String id) {
    if (_closing || reviewing(id)) throw const RequestCancelled();
    _sequences[id] = observationSequence(id) + 1;
    final observation = BookPolicyObservation._(
      this,
      id,
      _observationGenerations[id] ?? 0,
    );
    _observations.putIfAbsent(id, () => {}).add(observation);
    _observationChanges.value++;
    return observation;
  }

  void _requireObservation(BookPolicyObservation observation) {
    if (observation._closed ||
        reviewing(observation._id) ||
        (_observationGenerations[observation._id] ?? 0) !=
            observation._generation) {
      throw const RequestCancelled();
    }
  }

  void _finishObservation(BookPolicyObservation observation) {
    final active = _observations[observation._id]!;
    active.remove(observation);
    if (active.isEmpty) _observations.remove(observation._id);
    if (!_closing) _observationChanges.value++;
  }

  Future<void> rememberMetadata(
    Book original,
    Book details, {
    required bool Function(Book) bookAllowed,
    required void Function() authorize,
    Future<void> Function()? afterCommit,
  }) async {
    if (original.id != details.id || original.sourceId != details.sourceId) {
      return;
    }
    if (reviewing(original.id)) throw const RequestCancelled();
    final wasAllowed = bookAllowed(original);
    final metadata = _metadata(details);
    final evidence = BookPolicyEvidence.observe(
      policy,
      category: metadata.category,
      text: metadata.text,
      stableText: metadata.stableText,
    );
    final operation = Object();
    _pending.putIfAbsent(original.id, () => {})[operation] = evidence;
    if (wasAllowed && !bookAllowed(original)) _changed();
    try {
      final persisted = await store.merge(
        original.id,
        evidence,
        authorize,
        afterCommit: afterCommit,
      );
      _retain(original.id, persisted);
      authorize();
    } catch (_) {
      // Keep valid evidence after a storage failure. Superseded or cancelled
      // source responses are discarded by their source/observation lease.
      try {
        authorize();
        _retain(original.id, evidence);
      } catch (_) {
        // Only this operation's pending evidence is removed below.
      }
      rethrow;
    } finally {
      final wasBlocked = !bookAllowed(original);
      final pending = _pending[original.id]!;
      pending.remove(operation);
      if (pending.isEmpty) _pending.remove(original.id);
      if (wasBlocked && bookAllowed(original) && !_closing) _changed();
    }
  }

  void _retain(String id, BookPolicyEvidence evidence) {
    if (evidence.isEmpty) return;
    _evidence.update(
      id,
      (current) => current.merge(evidence),
      ifAbsent: () => evidence,
    );
  }

  BookPolicyEvidence? reviewableEvidence(String id) {
    final evidence = _evidence[id];
    return !reviewing(id) &&
            !_busy(id) &&
            evidence != null &&
            !evidence.uncertain &&
            evidence.adult
        ? evidence
        : null;
  }

  bool matchesReview(BookPolicyReviewEntry entry) {
    final evidence = _evidence[entry.book.id];
    return !_busy(entry.book.id) &&
        entry.observationSequence == observationSequence(entry.book.id) &&
        evidence != null &&
        !evidence.uncertain &&
        evidence.adult &&
        evidence.revision == entry.revision &&
        evidence.snapshotDigest == entry.digest;
  }

  BookPolicyReviewLease startReview(String id) {
    if (_closing || reviewing(id) || _busy(id)) {
      throw const FormatException('作品正在观察或复核，请稍后重试');
    }
    final lease = BookPolicyReviewLease._(this, id);
    _reviews[id] = lease;
    _observationGenerations[id] = (_observationGenerations[id] ?? 0) + 1;
    return lease;
  }

  void _publishReview(BookPolicyReviewLease lease, BookPolicyEvidence cleared) {
    if (!identical(_reviews[lease._id], lease)) {
      throw StateError('作品复核未登记');
    }
    _evidence[lease._id] = cleared;
  }

  void _finishReview(BookPolicyReviewLease lease) {
    _reviews.remove(lease._id);
    _changed();
  }

  /// Stop new work before the caller drains existing requests and reviews.
  void beginClose() => _closing = true;

  void dispose() {
    beginClose();
    policy.removeListener(_policyChanged);
    _observationChanges.dispose();
    _changes.dispose();
  }
}

/// One observation owns one registration; repeated close cannot finish a peer.
final class BookPolicyObservation {
  BookPolicyObservation._(this._owner, this._id, this._generation);
  final BookPolicyTracker _owner;
  final String _id;
  final int _generation;
  bool _closed = false;

  void check() => _owner._requireObservation(this);

  void close() {
    if (_closed) return;
    _closed = true;
    _owner._finishObservation(this);
  }
}

/// Publication is allowed during shutdown for a review already committed.
final class BookPolicyReviewLease {
  BookPolicyReviewLease._(this._owner, this._id);
  final BookPolicyTracker _owner;
  final String _id;
  bool _closed = false;

  void notifyStarted() {
    if (_closed) throw StateError('作品复核已结束');
    _owner._changed();
  }

  void publish(BookPolicyEvidence cleared) =>
      _owner._publishReview(this, cleared);

  void close() {
    if (_closed) return;
    _closed = true;
    _owner._finishReview(this);
  }
}
