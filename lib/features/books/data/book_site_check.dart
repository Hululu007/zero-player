import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../supervision/application/content_policy.dart';
import '../domain/book.dart';
import 'book_site_inspection.dart';

const bookSiteCheckInterval = Duration(days: 7);
const bookSiteRetryInterval = Duration(minutes: 30);
const bookSiteMaxRetryInterval = Duration(hours: 24);
const _maxSiteFailures = 7;

String bookSourceCheckFingerprint(BookSource source) =>
    sha256.convert(utf8.encode(jsonEncode(source.toJson()))).toString();

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
  });
  final BookSiteInspection inspection;
  final DateTime checkedAt;
  final String fingerprint;
  final int consecutiveFailures;

  /// A redirect or transport failure did not sample the homepage's text.
  bool get needsRetry => switch (inspection.finding) {
    BookSiteFinding.sameSiteRedirect ||
    BookSiteFinding.externalRedirect ||
    BookSiteFinding.httpError ||
    BookSiteFinding.timeout ||
    BookSiteFinding.networkError ||
    BookSiteFinding.unsupported => true,
    _ => false,
  };

  int get _failureCount =>
      needsRetry ? consecutiveFailures.clamp(1, _maxSiteFailures) : 0;

  DateTime get nextDue {
    if (!needsRetry) return checkedAt.add(bookSiteCheckInterval);
    final minutes = bookSiteRetryInterval.inMinutes << (_failureCount - 1);
    final retry = Duration(
      minutes: minutes.clamp(0, bookSiteMaxRetryInterval.inMinutes),
    );
    return checkedAt.add(retry);
  }

  bool isDue(DateTime now) =>
      checkedAt.isAfter(now.add(const Duration(minutes: 5))) ||
      !now.isBefore(nextDue);

  /// Keep retry history only for the same source version. A real sample resets
  /// the failures, including when it contains weak or strong risk clues.
  static BookSiteCheck after(
    BookSiteInspection inspection,
    DateTime now,
    BookSource source,
    BookSiteCheck? previous,
  ) {
    final fingerprint = bookSourceCheckFingerprint(source);
    final current = BookSiteCheck(inspection, now, fingerprint);
    final previousFailures = previous?.fingerprint == fingerprint
        ? previous!._failureCount
        : 0;
    final failures = current.needsRetry
        ? (previousFailures + 1).clamp(1, _maxSiteFailures)
        : 0;
    return BookSiteCheck(
      inspection,
      now,
      fingerprint,
      consecutiveFailures: failures,
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
    'consecutiveFailures': _failureCount,
  };

  static BookSiteCheck? fromJson(Object? value, BookSource source) {
    if (value is! Map ||
        value['version'] != 1 ||
        value['checkedAt'] is! int ||
        value['fingerprint'] != bookSourceCheckFingerprint(source)) {
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
      ),
      DateTime.fromMillisecondsSinceEpoch(stamp),
      value['fingerprint'] as String,
      consecutiveFailures: value['consecutiveFailures'] is int
          ? (value['consecutiveFailures'] as int).clamp(0, _maxSiteFailures)
          : 0,
    );
  }
}
