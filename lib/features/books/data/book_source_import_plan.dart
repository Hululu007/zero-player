import 'dart:convert';

import '../domain/book.dart';
import '../domain/book_source_risk.dart';
import 'book_store.dart';

typedef BookImportChanges = ({
  int added,
  int updated,
  int duplicates,
  int skipped,
});

enum BookSourceImportAction { skip, duplicate, insert, update, replaceReviewed }

typedef BookSourceImportCandidate = ({
  BookSource source,
  BookSourceEntry? previous,
  bool blacklisted,
});

String bookSourceBlacklistAlias(BookSource source) {
  final host = source.endpoint.host.replaceFirst(RegExp(r'^www\.'), '');
  final path = source.endpoint.path == '/' ? '' : source.endpoint.path;
  return '${source.kind.name}:$host$path?${source.endpoint.query}:${source.sourceKey}';
}

/// One import's decisions against an installed-source snapshot. No I/O or live
/// authorization lives here; the executor supplies current access decisions.
final class BookSourceImportPlan {
  BookSourceImportPlan(
    List<BookSourceEntry> current, {
    required Set<String> blockedIds,
    required Set<String> blockedAliases,
    this.subscriptionId,
    this.fromCatalog = false,
  }) : _existing = {for (final entry in current) entry.source.id: entry},
       _blockedIds = Set.of(blockedIds),
       _blockedAliases = Set.of(blockedAliases),
       _customCount = current
           .where((entry) => !entry.source.builtin && !entry.fromCatalog)
           .length;

  final Map<String, BookSourceEntry> _existing;
  final Set<String> _blockedIds, _blockedAliases;
  final String? subscriptionId;
  final bool fromCatalog;
  final int _customCount;
  final _seen = <String>{};
  int _added = 0, _updated = 0, _duplicates = 0, _skipped = 0;

  BookImportChanges get changes => (
    added: _added,
    updated: _updated,
    duplicates: _duplicates,
    skipped: _skipped,
  );

  /// Preparation does not consume a row. Retain adult evidence before checking
  /// whether this row is allowed, including denied and repeated updates.
  BookSourceImportCandidate prepare(BookSource candidate) {
    var source = _keepLegacyKey(candidate);
    final previous = _existing[source.id];
    if (previous != null &&
        (adultBookSource(previous.source) ||
            adultBookLabels(previous.source.name, previous.group)) &&
        !source.adultEvidence) {
      source = BookSource.fromJson({...source.toJson(), 'adultEvidence': true});
    }
    return (
      source: source,
      previous: previous,
      blacklisted:
          _blockedAliases.contains(bookSourceBlacklistAlias(candidate)) ||
          _blockedIds.contains(candidate.id) ||
          _blockedIds.contains(source.id),
    );
  }

  /// Consume each prepared row once, in input order. Rejected rows remain
  /// skipped even if their identity was seen earlier in this batch.
  BookSourceImportAction decide(
    BookSourceImportCandidate candidate, {
    required bool allowed,
    required bool supervisionRestricted,
  }) {
    final (:source, :previous, :blacklisted) = candidate;
    if (blacklisted ||
        !allowed ||
        (fromCatalog && source.kind == BookKind.comic)) {
      return _count(BookSourceImportAction.skip);
    }
    if (!_seen.add(source.id)) return _count(BookSourceImportAction.duplicate);
    if (previous == null) {
      return _count(
        !fromCatalog && _customCount + _added >= 12000
            ? BookSourceImportAction.skip
            : BookSourceImportAction.insert,
      );
    }
    if (knownUnsafeBookRule(previous.source) ||
        knownUnavailableBookRule(previous.source)) {
      final manualReplacement =
          subscriptionId == null &&
          !fromCatalog &&
          !previous.source.builtin &&
          !supervisionRestricted &&
          previous.source.kind == source.kind &&
          previous.source.endpoint == source.endpoint &&
          !quarantinedBookSource(source);
      return _count(
        manualReplacement
            ? BookSourceImportAction.replaceReviewed
            : BookSourceImportAction.skip,
      );
    }
    final owned =
        subscriptionId != null && previous.subscriptionId == subscriptionId;
    final newerCatalog =
        fromCatalog &&
        previous.fromCatalog &&
        source.updatedAt > previous.source.updatedAt;
    return _count(
      !previous.source.builtin &&
              (owned || newerCatalog) &&
              jsonEncode(source.toJson()) !=
                  jsonEncode(previous.source.toJson())
          ? BookSourceImportAction.update
          : BookSourceImportAction.duplicate,
    );
  }

  BookSourceImportAction _count(BookSourceImportAction action) {
    switch (action) {
      case BookSourceImportAction.skip:
        _skipped++;
      case BookSourceImportAction.duplicate:
        _duplicates++;
      case BookSourceImportAction.insert:
        _added++;
      case BookSourceImportAction.update:
      case BookSourceImportAction.replaceReviewed:
        _updated++;
    }
    return action;
  }

  BookSource _keepLegacyKey(BookSource source) {
    if (source.sourceKey.isEmpty ||
        source.sourceKey.contains('#') ||
        source.sourceKey.startsWith('alias:') ||
        _existing.containsKey(source.id)) {
      return source;
    }
    final legacy = _existing[source.legacyId]?.source;
    if (legacy == null ||
        legacy.builtin ||
        legacy.legado == null ||
        legacy.endpoint != source.endpoint) {
      return source;
    }
    return BookSource.fromJson(source.toJson()..remove('sourceKey'));
  }
}
