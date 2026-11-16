import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../supervision/application/content_policy.dart';
import '../domain/book.dart';
import 'book_site_inspection.dart';
import 'book_site_script_clues.dart';

const bookSiteCheckInterval = Duration(days: 7);
const bookSiteRetryInterval = Duration(minutes: 30);
const bookSiteMaxRetryInterval = Duration(hours: 24);
const _maxSiteFailures = 7;

String bookSourceCheckFingerprint(BookSource source) =>
    sha256.convert(utf8.encode(jsonEncode(source.toJson()))).toString();

/// A host digest associates old homepage evidence without storing another URL.
String bookSiteHostFingerprint(BookSource source) =>
    sha256.convert(utf8.encode(source.endpoint.host)).toString();

/// Risk notifications also refresh ContentPolicy. Compare only settings that
/// affect book visibility so a newly quarantined host does not cancel a batch.
String bookSitePolicySnapshot(ContentPolicy policy) => jsonEncode({
  'filterAdult': policy.filterAdult,
  'supervision': policy.supervision.enabled,
  'corrupted': policy.supervision.corrupted,
  'rules': policy.supervision.rules.toJson(),
});

final class BookSiteCheck {
  const BookSiteCheck(
    this.inspection,
    this.checkedAt,
    this.fingerprint, {
    this.consecutiveFailures = 0,
    this.legacyScriptReviewMissing = false,
    this.scriptCluesLastObserved = const {},
    this.sourceHostSha256,
    this.sourceId,
    this.siteRevision,
  });
  final BookSiteInspection inspection;
  final DateTime checkedAt;
  final String fingerprint;
  final int consecutiveFailures;
  final bool legacyScriptReviewMissing;
  final Map<BookPageScriptClue, DateTime> scriptCluesLastObserved;
  final String? sourceHostSha256;
  final String? sourceId;
  final String? siteRevision;

  /// Pending clues are bounded enum codes, each with its own observation time.
  /// v1 records predating this field retain clues from their last sample.
  Map<BookPageScriptClue, DateTime> get pendingScriptClues => Map.unmodifiable({
    ...scriptCluesLastObserved,
    for (final clue in inspection.scriptReview.clues) clue: checkedAt,
  });

  Map<BookPageScriptClue, DateTime> get historicalScriptClues =>
      Map.unmodifiable({
        for (final entry in pendingScriptClues.entries)
          if (!inspection.scriptReview.clues.contains(entry.key))
            entry.key: entry.value,
      });

  /// The redirect target was not followed, even when its referring page had clues.
  bool get needsRetry =>
      inspection.redirect != BookSiteRedirect.none ||
      switch (inspection.finding) {
        BookSiteFinding.sameSiteRedirect ||
        BookSiteFinding.externalRedirect ||
        BookSiteFinding.httpError ||
        BookSiteFinding.timeout ||
        BookSiteFinding.networkError ||
        BookSiteFinding.unsupported ||
        BookSiteFinding.sourceChanged => true,
        _ => false,
      };

  int get _failureCount => inspection.finding == BookSiteFinding.sourceChanged
      ? 0
      : needsRetry
      ? consecutiveFailures.clamp(1, _maxSiteFailures)
      : 0;

  DateTime get nextDue {
    if (inspection.finding == BookSiteFinding.sourceChanged) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
    // Revisit pre-feature successful samples without bypassing failure backoff.
    if (legacyScriptReviewMissing && !needsRetry) return checkedAt;
    if (!needsRetry) return checkedAt.add(bookSiteCheckInterval);
    final minutes = bookSiteRetryInterval.inMinutes << (_failureCount - 1);
    final retry = Duration(
      minutes: minutes.clamp(0, bookSiteMaxRetryInterval.inMinutes),
    );
    return checkedAt.add(retry);
  }

  bool isDue(DateTime now) =>
      inspection.finding == BookSiteFinding.sourceChanged ||
      checkedAt.isAfter(now.add(const Duration(minutes: 5))) ||
      !now.isBefore(nextDue);

  /// Keep retry history only for the same source version. A real sample resets
  /// the failures, including when it contains weak or strong risk clues.
  static BookSiteCheck after(
    BookSiteInspection inspection,
    DateTime now,
    BookSource source,
    BookSiteCheck? previous, {
    BookSiteCheck? scriptHistoryPrevious,
    String? siteRevision,
  }) {
    final fingerprint = bookSourceCheckFingerprint(source);
    final current = BookSiteCheck(inspection, now, fingerprint);
    final previousFailures = previous?.fingerprint == fingerprint
        ? previous!._failureCount
        : 0;
    final failures = current.needsRetry
        ? (previousFailures + 1).clamp(1, _maxSiteFailures)
        : 0;
    final history = scriptHistoryPrevious ?? previous;
    final complete =
        !current.needsRetry &&
        !inspection.truncated &&
        inspection.scriptReview.coverage == BookPageScriptCoverage.sampled;
    final clues = <BookPageScriptClue, DateTime>{
      if (!complete && history?.fingerprint == fingerprint)
        ...history!.pendingScriptClues,
      for (final clue in inspection.scriptReview.clues) clue: now,
    };
    return BookSiteCheck(
      inspection,
      now,
      fingerprint,
      consecutiveFailures: failures,
      scriptCluesLastObserved: Map.unmodifiable(clues),
      sourceHostSha256: bookSiteHostFingerprint(source),
      sourceId: source.id,
      siteRevision: siteRevision,
    );
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'finding': inspection.finding.name,
    'gamblingRisk': inspection.gamblingRisk,
    'adultRisk': inspection.adultRisk,
    'truncated': inspection.truncated,
    'statusCode': inspection.statusCode,
    'redirect': inspection.redirect.name,
    'checkedAt': checkedAt.millisecondsSinceEpoch,
    'fingerprint': fingerprint,
    if (sourceHostSha256 != null) 'sourceHostSha256': sourceHostSha256,
    if (sourceId != null) 'sourceId': sourceId,
    if (siteRevision != null) 'siteRevision': siteRevision,
    'consecutiveFailures': _failureCount,
    if (!legacyScriptReviewMissing)
      'scriptReview': inspection.scriptReview.toJson(),
    'scriptCluesLastObserved': {
      for (final clue in BookPageScriptClue.values)
        if (pendingScriptClues[clue] case final observed?)
          clue.name: observed.millisecondsSinceEpoch,
    },
  };

  static BookSiteCheck? fromJson(
    Object? value,
    BookSource source, {
    String? currentRevision,
    bool requireRevision = false,
  }) {
    if (value is! Map ||
        value['version'] != 1 ||
        value['checkedAt'] is! int ||
        value['fingerprint'] is! String) {
      return null;
    }
    final currentFingerprint = bookSourceCheckFingerprint(source);
    final sameSourceVersion = value['fingerprint'] == currentFingerprint;
    final currentHost = bookSiteHostFingerprint(source);
    final conflictingId =
        value['sourceId'] != null && value['sourceId'] != source.id;
    final conflictingHost =
        value['sourceHostSha256'] != null &&
        value['sourceHostSha256'] != currentHost;
    final explicitBinding =
        value['sourceId'] == source.id &&
        value['sourceHostSha256'] == currentHost;
    final bound = explicitBinding || sameSourceVersion;
    if (conflictingId ||
        conflictingHost ||
        (!sameSourceVersion && !explicitBinding)) {
      return null;
    }
    final stamp = value['checkedAt'] as int;
    if (stamp <= 0 || stamp > 253402300799999) return null;
    final name = value['finding'];
    final finding = BookSiteFinding.values
        .where((v) => v.name == name)
        .firstOrNull;
    if (finding == null) return null;
    final code = value['statusCode'];
    final rawClues = value['scriptCluesLastObserved'];
    final scriptClues = <BookPageScriptClue, DateTime>{};
    if (rawClues is Map) {
      for (final clue in BookPageScriptClue.values) {
        final observed = rawClues[clue.name];
        if (observed is int && observed > 0 && observed <= 253402300799999) {
          scriptClues[clue] = DateTime.fromMillisecondsSinceEpoch(observed);
        }
      }
    }
    final review = BookPageScriptReview.fromJson(value['scriptReview']);
    final revisionChanged =
        requireRevision &&
        (currentRevision == null || value['siteRevision'] != currentRevision);
    if (!sameSourceVersion || revisionChanged) {
      final observedAt = DateTime.fromMillisecondsSinceEpoch(stamp);
      if (bound) {
        for (final clue in review.clues) {
          scriptClues[clue] = observedAt;
        }
      } else {
        scriptClues.clear();
      }
      return BookSiteCheck(
        const BookSiteInspection(BookSiteFinding.sourceChanged),
        observedAt,
        currentFingerprint,
        scriptCluesLastObserved: Map.unmodifiable(scriptClues),
        sourceHostSha256: currentHost,
        sourceId: source.id,
      );
    }
    final redirect =
        BookSiteRedirect.values
            .where((entry) => entry.name == value['redirect'])
            .firstOrNull ??
        switch (finding) {
          BookSiteFinding.externalRedirect => BookSiteRedirect.external,
          BookSiteFinding.sameSiteRedirect => BookSiteRedirect.sameSite,
          _ => BookSiteRedirect.none,
        };
    return BookSiteCheck(
      BookSiteInspection(
        finding,
        gamblingRisk: value['gamblingRisk'] == true,
        adultRisk: value['adultRisk'] == true,
        truncated: value['truncated'] == true,
        statusCode: code is int && code >= 100 && code <= 599 ? code : null,
        redirect: redirect,
        scriptReview: review,
      ),
      DateTime.fromMillisecondsSinceEpoch(stamp),
      value['fingerprint'] as String,
      consecutiveFailures: value['consecutiveFailures'] is int
          ? (value['consecutiveFailures'] as int).clamp(0, _maxSiteFailures)
          : 0,
      legacyScriptReviewMissing: !BookPageScriptReview.validJson(
        value['scriptReview'],
      ),
      scriptCluesLastObserved: Map.unmodifiable(scriptClues),
      sourceHostSha256: value['sourceHostSha256'] == currentHost
          ? currentHost
          : null,
      sourceId: value['sourceId'] == source.id ? source.id : null,
      siteRevision: value['siteRevision'] is String
          ? value['siteRevision'] as String
          : null,
    );
  }
}
