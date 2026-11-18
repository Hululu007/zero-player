import '../../../core/network/cancellation_token.dart';
import '../../supervision/application/content_policy.dart';
import '../../supervision/domain/supervision_rules.dart';
import '../domain/book.dart';
import '../domain/book_source_risk.dart';
import 'book_source_import_plan.dart';
import 'book_source_links.dart';
import 'book_source_risk_store.dart';
import 'book_store.dart';

typedef BookSourceImportResult = ({
  BookImportChanges changes,
  List<BookSourceAssessment> assessments,
  bool recoveredQuarantine,
});

/// Applies a plan within one transaction. Risk evidence is durable before its
/// rejected update can be reported; in-memory publication belongs to the caller
/// and occurs only after this transaction has committed.
final class BookSourceImporter {
  BookSourceImporter({
    required this.store,
    required this.policy,
    required this.sourceAllowed,
    required this.adultAssessed,
    required this.assessAdult,
  });

  final BookStore store;
  final ContentPolicy policy;
  final bool Function(BookSource) sourceAllowed;
  final bool Function(String) adultAssessed;
  final Future<BookSourceAssessment> Function(BookSource) assessAdult;

  Future<BookSourceImportResult> importSources(
    List<BookSource> incoming, {
    required List<BookSource> builtins,
    Uri? subscription,
    CancellationToken? token,
    bool fromCatalog = false,
    String? catalogRevision,
    bool? catalogAdultFilter,
  }) async {
    final subscriptionId = subscription == null
        ? null
        : bookSubscriptionId(subscription);
    final batch = _ImportBatch(
      this,
      token: token,
      automatic: subscription != null || fromCatalog,
      catalogAdultFilter: catalogAdultFilter,
      subscriptionId: subscriptionId,
      fromCatalog: fromCatalog,
    );
    return store.db.atomic<BookSourceImportResult>(() async {
      batch.requireAccess();
      final plan = BookSourceImportPlan(
        await store.sources(builtins),
        blockedIds: (await store.blockedSources()).keys.toSet(),
        blockedAliases: await store.blockedAliases(),
        subscriptionId: subscriptionId,
        fromCatalog: fromCatalog,
      );
      for (final candidate in incoming) {
        await batch.apply(plan, candidate);
      }
      if (batch.pending.isNotEmpty) await batch.flush();
      batch.requireAccess();
      if (catalogRevision != null) {
        await store.write('books_catalog_revision', catalogRevision);
      }
      final changes = plan.changes;
      final count = changes.added + changes.updated + changes.duplicates;
      if (subscription != null && count > 0) {
        await store.saveSubscription(
          BookSourceSubscription(
            subscription,
            count,
            DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
      batch.requireAccess();
      return (
        changes: changes,
        assessments: List<BookSourceAssessment>.unmodifiable(
          batch.assessments.values,
        ),
        recoveredQuarantine: batch.recoveredQuarantine,
      );
    }, tables: {'app_meta'});
  }
}

final class _ImportBatch {
  _ImportBatch(
    this.importer, {
    required this.token,
    required this.automatic,
    required this.catalogAdultFilter,
    required this.subscriptionId,
    required this.fromCatalog,
  });

  final BookSourceImporter importer;
  final CancellationToken? token;
  final bool automatic, fromCatalog;
  final bool? catalogAdultFilter;
  final String? subscriptionId;
  final pending = <({BookSource source, BookSourceEntry? previous})>[];
  final assessments = <String, BookSourceAssessment>{};
  bool recoveredQuarantine = false;
  ContentPolicy get policy => importer.policy;

  void requireAccess() {
    token?.check();
    policy.supervision.require(SensitiveOperation.channels);
    if ((automatic &&
            (policy.supervision.enabled || policy.supervision.corrupted)) ||
        (catalogAdultFilter != null &&
            policy.filterAdult != catalogAdultFilter)) {
      throw const ContentBlocked();
    }
  }

  Future<void> apply(BookSourceImportPlan plan, BookSource candidate) async {
    requireAccess();
    final prepared = plan.prepare(candidate);
    final (:source, :previous, blacklisted: _) = prepared;
    // Preserve evidence against the installed identity before rejecting an
    // adult-labelled replacement, even when its endpoint has changed.
    if (previous != null &&
        policy.filterAdult &&
        adultBookSource(source) &&
        !importer.adultAssessed(source.id) &&
        !assessments.containsKey(source.id)) {
      assessments[source.id] = await importer.assessAdult(previous.source);
    }
    requireAccess();
    final action = plan.decide(
      prepared,
      allowed: !prepared.blacklisted && importer.sourceAllowed(source),
      supervisionRestricted:
          policy.supervision.enabled || policy.supervision.corrupted,
    );
    switch (action) {
      case BookSourceImportAction.insert:
      case BookSourceImportAction.update:
        pending.add((source: source, previous: previous));
      case BookSourceImportAction.replaceReviewed:
        await flush();
        _requireReplacement(source);
        await importer.store.saveSource(previous!.source, {
          'source': source.toJson(),
          'enabled': false,
          'health': '',
          'checkedAt': null,
        });
        _requireReplacement(source);
        recoveredQuarantine = true;
      case BookSourceImportAction.skip:
      case BookSourceImportAction.duplicate:
        break;
    }
    if (pending.length >= 128) await flush();
  }

  void _requireReplacement(BookSource source) {
    requireAccess();
    if (policy.supervision.enabled ||
        policy.supervision.corrupted ||
        !importer.sourceAllowed(source)) {
      throw const ContentBlocked();
    }
  }

  Future<void> flush() async {
    requireAccess();
    await importer.store.writeImported(
      pending,
      subscriptionId: subscriptionId,
      fromCatalog: fromCatalog,
    );
    pending.clear();
  }
}
