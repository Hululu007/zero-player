import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../supervision/application/content_policy.dart';
import '../domain/book.dart';
import 'book_site_inspection.dart';
import 'book_site_sale_clues.dart';
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
    this.legacySaleReviewMissing = false,
    this.scriptCluesLastObserved = const {},
    this.saleClueLastObserved,
    this.sourceHostSha256,
    this.sourceId,
    this.siteRevision,
  });
  final BookSiteInspection inspection;
  final DateTime checkedAt;
  final String fingerprint;
  final int consecutiveFailures;
  final bool legacyScriptReviewMissing;
  final bool legacySaleReviewMissing;
  final Map<BookPageScriptClue, DateTime> scriptCluesLastObserved;
  final DateTime? saleClueLastObserved;
  final String? sourceHostSha256;
  final String? sourceId;
  final String? siteRevision;

  /// This is only a historical static homepage clue, not a risk decision.
  DateTime? get pendingSaleClue =>
      inspection.saleReview.suspected ? checkedAt : saleClueLastObserved;
  DateTime? get historicalSaleClue =>
      inspection.saleReview.suspected ? null : saleClueLastObserved;

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
      inspection.truncated ||
      inspection.textIncomplete ||
      inspection.visibilityIncomplete ||
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
    if ((legacyScriptReviewMissing || legacySaleReviewMissing) && !needsRetry) {
      return checkedAt;
    }
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
    final currentHost = bookSiteHostFingerprint(source);
    final origin = bookSiteSaleOriginFingerprint(
      Uri(scheme: 'https', host: source.endpoint.host, path: '/'),
    );
    final acceptedInspection = inspection.saleReview.originSha256 == origin
        ? inspection
        : inspection.withSaleReview(const BookPageSaleReview());
    final current = BookSiteCheck(acceptedInspection, now, fingerprint);
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
    final saleComplete =
        !current.needsRetry &&
        !inspection.truncated &&
        acceptedInspection.saleReview.coverage == BookPageSaleCoverage.complete;
    DateTime? saleClue;
    // The shared record is authoritative when a supervised check follows a
    // manual full sample, which may already have cleared the older clue.
    final saleHistory = scriptHistoryPrevious ?? previous;
    if (!saleComplete &&
        saleHistory != null &&
        saleHistory.fingerprint == fingerprint &&
        (saleHistory.sourceId == null || saleHistory.sourceId == source.id) &&
        (saleHistory.sourceHostSha256 == null ||
            saleHistory.sourceHostSha256 == currentHost)) {
      saleClue = saleHistory.pendingSaleClue;
    }
    if (acceptedInspection.saleReview.suspected) saleClue = now;
    return BookSiteCheck(
      acceptedInspection,
      now,
      fingerprint,
      consecutiveFailures: failures,
      scriptCluesLastObserved: Map.unmodifiable(clues),
      saleClueLastObserved: saleClue,
      sourceHostSha256: currentHost,
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
    'textIncomplete': inspection.textIncomplete,
    'visibilityIncomplete': inspection.visibilityIncomplete,
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
    if (!legacySaleReviewMissing) 'saleReview': inspection.saleReview.toJson(),
    if (pendingSaleClue case final observed?)
      'saleClueLastObserved': observed.millisecondsSinceEpoch,
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
    final origin = bookSiteSaleOriginFingerprint(
      Uri(scheme: 'https', host: source.endpoint.host, path: '/'),
    );
    final parsedSaleReview = BookPageSaleReview.fromJson(value['saleReview']);
    final saleReview = parsedSaleReview.originSha256 == origin
        ? parsedSaleReview
        : const BookPageSaleReview();
    final rawSaleTime = value['saleClueLastObserved'];
    DateTime? saleTime =
        rawSaleTime is int && rawSaleTime > 0 && rawSaleTime <= 253402300799999
        ? DateTime.fromMillisecondsSinceEpoch(rawSaleTime)
        : null;
    if (saleReview.suspected) {
      saleTime = DateTime.fromMillisecondsSinceEpoch(stamp);
    }
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
        saleClueLastObserved: saleTime,
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
        // Older or damaged records cannot establish that the text traversal
        // covered the whole sample. Revisit them without discarding evidence.
        textIncomplete: value['textIncomplete'] != false,
        visibilityIncomplete: value['visibilityIncomplete'] != false,
        statusCode: code is int && code >= 100 && code <= 599 ? code : null,
        redirect: redirect,
        scriptReview: review,
        saleReview: saleReview,
      ),
      DateTime.fromMillisecondsSinceEpoch(stamp),
      value['fingerprint'] as String,
      consecutiveFailures: value['consecutiveFailures'] is int
          ? (value['consecutiveFailures'] as int).clamp(0, _maxSiteFailures)
          : 0,
      legacyScriptReviewMissing: !BookPageScriptReview.validJson(
        value['scriptReview'],
      ),
      legacySaleReviewMissing:
          !BookPageSaleReview.validJson(value['saleReview']) ||
          (parsedSaleReview.originSha256 != null &&
              parsedSaleReview.originSha256 != origin),
      scriptCluesLastObserved: Map.unmodifiable(scriptClues),
      saleClueLastObserved: saleTime,
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
