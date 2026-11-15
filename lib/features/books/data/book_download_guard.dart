import '../../supervision/application/content_policy.dart';
import '../../supervision/domain/supervision_rules.dart';
import '../domain/book.dart';
import 'book_download_evidence.dart';
import 'book_source_risk_store.dart';
import 'book_store.dart';

typedef BookDownloadLease = ({int generation, int policy});

/// Checks both the requested work and the source that supplied its bytes.
final class BookDownloadGuard {
  BookDownloadGuard({
    required this.store,
    required this.risks,
    required this.policy,
    required this.sources,
    required this.verified,
    required this.epochs,
    required this.ready,
    required this.bookAllowed,
    required this.entryAllowed,
    required this.generation,
    required this.ensureReady,
  }) {
    policy.addListener(_policyChanged);
  }

  final BookStore store;
  final BookSourceRiskStore risks;
  final ContentPolicy policy;
  final Map<String, BookSourceEntry> sources;
  final Map<String, BookSource> verified;
  final Map<String, int> epochs;
  final bool Function() ready;
  final bool Function(Book) bookAllowed;
  final bool Function(BookSourceEntry) entryAllowed;
  final int Function() generation;
  final Future<void> Function() ensureReady;
  int _policyRevision = 0;

  void _policyChanged() => _policyRevision++;
  BookDownloadLease lease() =>
      (generation: generation(), policy: _policyRevision);

  void _requireLease(BookDownloadLease? expected) {
    if (expected != null && expected != lease()) throw const ContentBlocked();
  }

  bool allowed(BookDownloadEvidence evidence) {
    if (!ready()) return false;
    return _sideAllowed(
          evidence.target,
          evidence.targetChapter,
          evidence.targetFingerprint,
          evidence.targetEpoch,
        ) &&
        _sideAllowed(
          evidence.origin,
          evidence.originChapter,
          evidence.originFingerprint,
          evidence.originEpoch,
        );
  }

  bool _sideAllowed(
    Book book,
    BookChapter chapter,
    String fingerprint,
    int epoch,
  ) {
    final entry = sources[book.sourceId];
    return entry != null &&
        entry.source.kind == book.kind &&
        epochs[book.sourceId] == epoch &&
        epoch > 0 &&
        bookDownloadSourceFingerprint(entry.source) == fingerprint &&
        entryAllowed(entry) &&
        bookAllowed(book) &&
        policy.textAllowed(chapter.title);
  }

  Future<BookDownloadEvidence> capture(
    Book target,
    BookChapter targetChapter,
    Book origin,
    BookChapter originChapter,
  ) async {
    await ensureReady();
    final expected = lease();
    late BookDownloadEvidence evidence;
    await store.db.atomic(() async {
      _requireLease(expected);
      final targetEntry = await store.source(
        verified[target.sourceId],
        target.sourceId,
      );
      final originEntry = await store.source(
        verified[origin.sourceId],
        origin.sourceId,
      );
      if (targetEntry == null || originEntry == null || !originEntry.enabled) {
        throw const ContentBlocked();
      }
      final targetFingerprint = bookDownloadSourceFingerprint(
        targetEntry.source,
      );
      final originFingerprint = bookDownloadSourceFingerprint(
        originEntry.source,
      );
      final targetEpoch = await store.ensureContentEpoch(
        target.sourceId,
        targetFingerprint,
      );
      final originEpoch = await store.ensureContentEpoch(
        origin.sourceId,
        originFingerprint,
      );
      evidence = BookDownloadEvidence(
        target: target,
        targetChapter: targetChapter,
        targetFingerprint: targetFingerprint,
        targetEpoch: targetEpoch,
        origin: origin,
        originChapter: originChapter,
        originFingerprint: originFingerprint,
        originEpoch: originEpoch,
      );
      await _validatePersistent(evidence, expected, checkSnapshot: false);
    }, tables: {'app_meta'});
    _requireLease(expected);
    epochs[target.sourceId] = evidence.targetEpoch;
    epochs[origin.sourceId] = evidence.originEpoch;
    if (!allowed(evidence)) throw const ContentBlocked();
    return evidence;
  }

  Future<void> validate(
    BookDownloadEvidence evidence, {
    BookDownloadLease? expected,
  }) async {
    await ensureReady();
    final current = expected ?? lease();
    await store.db.atomic(() => _validatePersistent(evidence, current));
    _requireLease(current);
    if (!allowed(evidence)) throw const ContentBlocked();
  }

  Future<void> _validatePersistent(
    BookDownloadEvidence evidence,
    BookDownloadLease expected, {
    bool checkSnapshot = true,
  }) async {
    _requireLease(expected);
    if (!ready() || (checkSnapshot && !allowed(evidence))) {
      throw const ContentBlocked();
    }
    final blocked = await store.blockedSources();
    final assessments = await risks.all();
    for (final side in [
      (
        evidence.target,
        evidence.targetChapter,
        evidence.targetFingerprint,
        evidence.targetEpoch,
      ),
      (
        evidence.origin,
        evidence.originChapter,
        evidence.originFingerprint,
        evidence.originEpoch,
      ),
    ]) {
      final (book, chapter, fingerprint, epoch) = side;
      final entry = await store.source(verified[book.sourceId], book.sourceId);
      if (entry == null ||
          entry.source.kind != book.kind ||
          bookDownloadSourceFingerprint(entry.source) != fingerprint ||
          await store.contentEpoch(book.sourceId) != epoch ||
          blocked.containsKey(book.sourceId) ||
          !entryAllowed(entry) ||
          !bookAllowed(book) ||
          !policy.textAllowed(chapter.title) ||
          _persistedRestriction(entry.source, book, assessments.values)) {
        throw const ContentBlocked();
      }
    }
    _requireLease(expected);
    if (!ready() || (checkSnapshot && !allowed(evidence))) {
      throw const ContentBlocked();
    }
  }

  bool _persistedRestriction(
    BookSource source,
    Book book,
    Iterable<BookSourceAssessment> assessments,
  ) {
    final hosts = {
      source.endpoint.host.toLowerCase(),
      book.uri.host.toLowerCase(),
      ...source.mediaHosts.map((host) => host.toLowerCase()),
    };
    for (final risk in assessments) {
      final sameId = risk.sourceId == source.id;
      final sameHost = hosts.contains(risk.host);
      if ((sameId && risk.quarantined) || (sameHost && risk.quarantinedHost)) {
        return true;
      }
      if (policy.filterAdult &&
          ((sameId && risk.adult) || (sameHost && risk.adultHost))) {
        return true;
      }
    }
    return false;
  }

  void dispose() => policy.removeListener(_policyChanged);
}
