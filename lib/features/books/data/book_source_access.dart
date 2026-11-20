import '../../supervision/application/content_policy.dart';
import '../../supervision/domain/adult_source_evidence.dart';
import '../../supervision/domain/supervision_rules.dart';
import '../domain/book.dart';
import '../domain/book_source_risk.dart';
import 'book_source_risk_store.dart';
import 'book_store.dart';

/// Owns the published source snapshot and its exact-host restriction indexes.
/// Persistence, mutation leases and notifications belong to the caller. Only
/// committed findings may be remembered; stale reloads cannot replace them.
final class BookSourceAccess {
  BookSourceAccess(this.policy);

  final ContentPolicy policy;
  final _riskSourceEntries = <String, BookSourceEntry>{};
  final _sourceAssessments = <String, BookSourceAssessment>{};
  final _blockedSourceIds = <String>{};
  final _assessedAdultIds = <String>{};
  final _assessedQuarantinedIds = <String>{};
  final _assessedAdultHosts = <String>{};
  final _assessedQuarantinedHosts = <String>{};
  bool _riskLoaded = false;
  bool _riskSuspended = false;
  int _riskGeneration = 0;

  bool get loaded => _riskLoaded;
  bool get suspended => _riskSuspended;
  bool get ready => _riskLoaded && !_riskSuspended;
  int get generation => _riskGeneration;
  BookSourceEntry? entry(String id) => _riskSourceEntries[id];
  bool blocked(String id) => _blockedSourceIds.contains(id);
  bool adultAssessed(String id) => _assessedAdultIds.contains(id);

  void invalidate({bool unload = false}) {
    _riskGeneration++;
    if (unload) _riskLoaded = false;
  }

  void suspend() {
    _riskSuspended = true;
    invalidate(unload: true);
  }

  void resume() => _riskSuspended = false;

  int beginReload() {
    if (_riskSuspended) throw const ContentBlocked();
    _riskLoaded = false;
    return _riskGeneration;
  }

  /// Publish in the same synchronous step as the caller's companion snapshots.
  /// A false result requires rereading persistence, including companion data.
  bool publish({
    required int generation,
    required Iterable<BookSourceEntry> entries,
    required Map<String, BookSourceAssessment> assessments,
    required Iterable<String> blocked,
  }) {
    if (_riskSuspended) throw const ContentBlocked();
    if (generation != _riskGeneration) return false;
    _riskSourceEntries
      ..clear()
      ..addEntries(entries.map((entry) => MapEntry(entry.source.id, entry)));
    _sourceAssessments
      ..clear()
      ..addAll(assessments);
    _blockedSourceIds
      ..clear()
      ..addAll(blocked);
    _rebuildAssessmentHosts();
    _riskLoaded = true;
    return true;
  }

  void block(String id) {
    _blockedSourceIds.add(id);
    invalidate();
  }

  static bool retiredNewsHost(String host) => const [
    'ithome.com',
    'sspai.com',
    'ifanr.com',
  ].any((domain) => host == domain || host.endsWith('.$domain'));

  void _rebuildAssessmentHosts() {
    _assessedAdultIds.clear();
    _assessedQuarantinedIds.clear();
    _assessedAdultHosts.clear();
    _assessedQuarantinedHosts.clear();
    for (final risk in _sourceAssessments.values) {
      if (risk.adult) _assessedAdultIds.add(risk.sourceId);
      if (risk.quarantined) _assessedQuarantinedIds.add(risk.sourceId);
      if (risk.host.isEmpty) continue;
      if (risk.adultHost) _assessedAdultHosts.add(risk.host);
      if (risk.quarantinedHost) _assessedQuarantinedHosts.add(risk.host);
    }
  }

  bool assessedAdult(String id, String host) =>
      _assessedAdultIds.contains(id) ||
      _assessedAdultHosts.contains(host.toLowerCase());

  bool assessedQuarantined(String id, String host) =>
      _assessedQuarantinedIds.contains(id) ||
      _assessedQuarantinedHosts.contains(host.toLowerCase());

  void rememberAssessment(BookSourceAssessment assessment) {
    final previous = _sourceAssessments[assessment.key];
    if (previous != null && previous.version > assessment.version) return;
    _riskGeneration++;
    _sourceAssessments[assessment.key] = assessment;
    _rebuildAssessmentHosts();
  }

  List<BookSourceRiskEntry> riskEntries() {
    if (!ready || policy.supervision.enabled || policy.supervision.corrupted) {
      return const [];
    }
    final byId = <String, List<BookSourceAssessment>>{};
    for (final assessment in _sourceAssessments.values) {
      if (!assessment.adult && !assessment.quarantined) continue;
      (byId[assessment.sourceId] ??= []).add(assessment);
    }
    final ids = {..._riskSourceEntries.keys, ...byId.keys};
    final result = <BookSourceRiskEntry>[];
    for (final id in ids) {
      final sourceEntry = _riskSourceEntries[id];
      final assessments = byId[id] ?? const <BookSourceAssessment>[];
      for (final assessment in assessments) {
        final row = _sourceRiskEntry(
          id,
          assessment.host,
          sourceEntry,
          assessment,
        );
        if (row != null) result.add(row);
      }
      final currentHost = sourceEntry?.source.endpoint.host.toLowerCase();
      if (currentHost != null &&
          !assessments.any((assessment) => assessment.host == currentHost)) {
        final row = _sourceRiskEntry(id, currentHost, sourceEntry, null);
        if (row != null) result.add(row);
      }
    }
    return result..sort((a, b) => a.name.compareTo(b.name));
  }

  BookSourceRiskEntry? _sourceRiskEntry(
    String id,
    String host,
    BookSourceEntry? sourceEntry,
    BookSourceAssessment? assessment,
  ) {
    final source = sourceEntry?.source;
    final name = source?.name ?? assessment?.name ?? '';
    final isCurrentHost = source?.endpoint.host.toLowerCase() == host;
    final sourceAdult =
        source != null &&
        (adultBookSource(source) ||
            adultBookLabels(source.name, sourceEntry!.group) ||
            source.mediaHosts.any(
              (h) =>
                  adultBookHost(h) ||
                  knownAdultHost(h) ||
                  _assessedAdultHosts.contains(h.toLowerCase()),
            ));
    final hostAdult =
        adultBookHost(host) ||
        knownAdultHost(host) ||
        _assessedAdultHosts.contains(host);
    final adultRestricted =
        sourceAdult || hostAdult || _assessedAdultIds.contains(id);
    final adult =
        (assessment?.adult ?? false) ||
        hostAdult ||
        (isCurrentHost && sourceAdult) ||
        (assessment == null && _assessedAdultIds.contains(id));
    final fixed =
        (sourceEntry != null && _archivedComic(sourceEntry)) ||
        fixedRisk(id, host, source);
    final quarantined =
        fixed ||
        (assessment?.quarantined ?? false) ||
        _assessedQuarantinedHosts.contains(host) ||
        (assessment == null && _assessedQuarantinedIds.contains(id));
    if ((!adult && !quarantined) ||
        (policy.filterAdult && adultRestricted) ||
        !policy.textAllowed(
          '$name $host',
          category: sourceEntry?.group ?? '',
        )) {
      return null;
    }
    return BookSourceRiskEntry(
      sourceId: id,
      name: name,
      host: host,
      adult: adult,
      adultRestricted: adultRestricted,
      quarantined: quarantined,
      fixedQuarantine: fixed,
      version: assessment?.version ?? 0,
      recordKey: assessment?.key,
    );
  }

  static bool fixedRisk(String id, String host, BookSource? source) =>
      quarantinedBookHost(host) ||
      (source == null && quarantinedBookSourceId(id)) ||
      (source != null &&
          source.endpoint.host.toLowerCase() == host &&
          quarantinedBookSource(source));

  /// A review dialog can outlive a policy change or another site's finding.
  /// Recheck its snapshot instead of displaying stale, now restricted rows.
  bool riskEntryAllowed(BookSourceRiskEntry entry) {
    if (!ready || policy.supervision.enabled || policy.supervision.corrupted) {
      return false;
    }
    final assessment = entry.recordKey == null
        ? null
        : _sourceAssessments[entry.recordKey];
    if (entry.recordKey != null &&
        (assessment == null ||
            assessment.version != entry.version ||
            assessment.host != entry.host ||
            (!assessment.adult && !assessment.quarantined))) {
      return false;
    }
    final current = _sourceRiskEntry(
      entry.sourceId,
      entry.host,
      _riskSourceEntries[entry.sourceId],
      assessment,
    );
    return current != null &&
        current.name == entry.name &&
        current.adult == entry.adult &&
        current.adultRestricted == entry.adultRestricted &&
        current.quarantined == entry.quarantined &&
        current.fixedQuarantine == entry.fixedQuarantine;
  }

  bool kindAllowed(BookKind kind) =>
      !policy.supervision.corrupted &&
      !((kind == BookKind.audio || kind == BookKind.comic) &&
          policy.supervision.enabled);

  bool sourceAllowed(BookSource source) {
    if (!_riskLoaded) return false;
    final installed = entry(source.id);
    if (installed != null && _archivedComic(installed)) return false;
    final hosts = [source.endpoint.host, ...source.mediaHosts];
    return kindAllowed(source.kind) &&
        !_blockedSourceIds.contains(source.id) &&
        !quarantinedBookSource(source) &&
        !hosts.any(
          (host) =>
              quarantinedBookHost(host) || assessedQuarantined(source.id, host),
        ) &&
        (source.kind != BookKind.text ||
            !retiredNewsHost(source.endpoint.host)) &&
        !(policy.filterAdult &&
            (adultBookSource(source) ||
                hosts.any(
                  (host) =>
                      adultBookHost(host) ||
                      knownAdultHost(host) ||
                      assessedAdult(source.id, host),
                ))) &&
        policy.textAllowed(
          '${source.name} ${source.endpoint.host}',
          category: source.group,
        ) &&
        !(policy.supervision.enabled && !source.builtin);
  }

  bool entryAllowed(BookSourceEntry entry) =>
      !_archivedComic(entry) &&
      sourceAllowed(entry.source) &&
      policy.textAllowed('', category: entry.group) &&
      !(policy.filterAdult && adultBookLabels(entry.source.name, entry.group));

  static bool _archivedComic(BookSourceEntry entry) =>
      entry.fromCatalog &&
      !entry.source.builtin &&
      entry.source.kind == BookKind.comic;
}
