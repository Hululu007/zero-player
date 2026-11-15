import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../supervision/application/content_policy.dart';
import '../domain/book.dart';
import 'book_site_inspection.dart';

const bookSiteCheckInterval = Duration(days: 7);

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
  const BookSiteCheck(this.inspection, this.checkedAt, this.fingerprint);
  final BookSiteInspection inspection;
  final DateTime checkedAt;
  final String fingerprint;

  bool isDue(DateTime now) =>
      checkedAt.isAfter(now.add(const Duration(minutes: 5))) ||
      now.difference(checkedAt) >= bookSiteCheckInterval;

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
    );
  }
}
