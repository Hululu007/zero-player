import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/network/cancellation_token.dart';
import '../../supervision/application/content_policy.dart';
import '../../supervision/domain/supervision_rules.dart';
import '../data/book_site_inspection.dart';
import '../data/book_store.dart';
import '../data/books_repository.dart';
import '../domain/book.dart';

const bookSiteCheckInterval = Duration(days: 7);
const _prefix = 'books_site_check:';

String bookSourceCheckFingerprint(BookSource source) =>
    sha256.convert(utf8.encode(jsonEncode(source.toJson()))).toString();

/// Risk notifications also refresh ContentPolicy. Compare only settings that
/// affect book visibility so a newly quarantined host does not cancel its batch.
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

final class BookSiteCheckSummary {
  const BookSiteCheckSummary({
    required this.checked,
    required this.skipped,
    required this.failed,
    required this.quarantined,
    required this.adult,
  });
  final int checked, skipped, failed, quarantined, adult;
}

/// Homepage-only checks. Results never change source enable/favorite settings.
/// Risk markers are monotonic and are changed by the repository separately.
final class BookSiteChecks {
  BookSiteChecks(
    this.books, {
    Future<BookSiteInspection> Function(BookSource, CancellationToken)? inspect,
  }) : _inspect =
           inspect ?? BookSiteInspector(books.client.network.http).inspect;
  final BooksRepository books;
  final Future<BookSiteInspection> Function(BookSource, CancellationToken)
  _inspect;
  bool _running = false;

  Future<Map<String, BookSiteCheck>> load(List<BookSourceEntry> entries) async {
    final sources = {
      for (final entry in entries) entry.source.id: entry.source,
    };
    final rows = await books.store.db.rows(
      "SELECT key,value FROM app_meta WHERE key GLOB 'books_site_check:*'",
    );
    final result = <String, BookSiteCheck>{};
    for (final row in rows) {
      final key = row['key'];
      if (key is! String || !key.startsWith(_prefix)) continue;
      final id = key.substring(_prefix.length);
      final source = sources[id];
      if (source == null) continue;
      try {
        final check = BookSiteCheck.fromJson(
          jsonDecode(row['value'] as String),
          source,
        );
        if (check != null) result[id] = check;
      } on FormatException {
        // Keep damaged metadata untouched; it is not evidence of a site check.
      } on TypeError {
        // A restored or older entry may have an unexpected value.
      }
    }
    return result;
  }

  Future<BookSiteCheckSummary> run(
    List<BookSourceEntry> entries,
    CancellationToken token, {
    bool enabledOnly = false,
    void Function(int processed, int total)? onProgress,
  }) async {
    if (_running) throw const FormatException('书源网页抽查正在进行，请稍后再试');
    _running = true;
    var next = 0, checked = 0, skipped = 0, failed = 0;
    var processed = 0, quarantined = 0, adult = 0;
    final policySnapshot = bookSitePolicySnapshot(books.policy);
    final hostResults = <String, Future<BookSiteInspection>>{};
    final hostMarks = <String, Future<void>>{};
    Future<void> worker() async {
      try {
        while (next < entries.length) {
          token.check();
          final entry = entries[next++];
          try {
            final check = await _check(
              entry,
              token,
              hostResults,
              hostMarks,
              enabledOnly,
              policySnapshot,
            );
            if (check == null) {
              skipped++;
            } else {
              checked++;
              if (check.inspection.gamblingRisk) quarantined++;
              if (check.inspection.adultRisk) adult++;
            }
          } on RequestCancelled {
            rethrow;
          } on Exception {
            // A changed/deleted source or a failed write must not prevent other
            // sites from being checked. A revoked policy still cancels all.
            _checkPolicy(token, policySnapshot);
            failed++;
          }
          onProgress?.call(++processed, entries.length);
        }
      } catch (_) {
        token.cancel();
        rethrow;
      }
    }

    try {
      await Future.wait(
        List.generate(entries.length.clamp(0, 3), (_) => worker()),
      );
      _checkPolicy(token, policySnapshot);
      return BookSiteCheckSummary(
        checked: checked,
        skipped: skipped,
        failed: failed,
        quarantined: quarantined,
        adult: adult,
      );
    } finally {
      _running = false;
    }
  }

  Future<BookSiteCheck?> _check(
    BookSourceEntry entry,
    CancellationToken token,
    Map<String, Future<BookSiteInspection>> hostResults,
    Map<String, Future<void>> hostMarks,
    bool enabledOnly,
    String policySnapshot,
  ) async {
    _checkPolicy(token, policySnapshot);
    var current = await books.sourceEntry(entry.source.kind, entry.source.id);
    _checkPolicy(token, policySnapshot);
    if (!_sameSource(current, entry, enabledOnly)) return null;
    final inspection = await hostResults.putIfAbsent(
      entry.source.endpoint.host,
      () => _inspect(entry.source, token),
    );
    _checkPolicy(token, policySnapshot);
    current = await books.sourceEntry(entry.source.kind, entry.source.id);
    _checkPolicy(token, policySnapshot);
    if (!_sameSource(current, entry, enabledOnly)) return null;
    if (inspection.gamblingRisk || inspection.adultRisk) {
      await hostMarks.putIfAbsent(
        entry.source.endpoint.host,
        () => books.markSourceRisk(
          entry.source,
          adult: inspection.adultRisk,
          quarantine: inspection.gamblingRisk,
        ),
      );
    }
    _checkPolicy(token, policySnapshot);
    final check = BookSiteCheck(
      inspection,
      DateTime.now(),
      bookSourceCheckFingerprint(entry.source),
    );
    final saved = await books.store.db.atomic(() async {
      _checkPolicy(token, policySnapshot);
      final current = await books.store.source(
        entry.source.builtin ? entry.source : null,
        entry.source.id,
      );
      _checkPolicy(token, policySnapshot);
      if (!_sameSource(current, entry, enabledOnly) ||
          !books.policy.textAllowed('', category: current!.group) ||
          (await books.store.blockedSources()).containsKey(entry.source.id)) {
        return false;
      }
      _checkPolicy(token, policySnapshot);
      await books.store.write('$_prefix${entry.source.id}', check.toJson());
      _checkPolicy(token, policySnapshot);
      return true;
    }, tables: {'app_meta'});
    return saved ? check : null;
  }

  void _checkPolicy(CancellationToken token, String expected) {
    token.check();
    if (books.sourceRisksSuspended) throw const RequestCancelled();
    books.policy.supervision.require(SensitiveOperation.channels);
    if (bookSitePolicySnapshot(books.policy) != expected) {
      throw const RequestCancelled();
    }
  }

  bool _sameSource(
    BookSourceEntry? current,
    BookSourceEntry original,
    bool enabledOnly,
  ) =>
      current != null &&
      (!enabledOnly || current.enabled) &&
      bookSourceCheckFingerprint(current.source) ==
          bookSourceCheckFingerprint(original.source);
}
