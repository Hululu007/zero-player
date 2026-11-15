import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/network/cancellation_token.dart';
import '../../../core/network/document_client.dart';
import '../../../core/network/media_http_client.dart';
import '../../../core/network/poster_repository.dart';
import '../../../core/persistence/app_database.dart';
import '../../../media/gateway/offline_server.dart';
import '../../supervision/application/content_policy.dart';
import '../../supervision/domain/adult_source_evidence.dart';
import '../../supervision/domain/supervision_rules.dart';
import '../domain/book.dart';
import '../domain/book_search.dart';
import '../domain/book_source_risk.dart';
import '../domain/legado_source.dart';
import 'aoaostar_book_catalog.dart';
import 'audiobook_files.dart';
import 'book_client.dart';
import 'book_cover_cache.dart';
import 'book_download_evidence.dart';
import 'book_download_guard.dart';
import 'book_import.dart';
import 'book_image_payload.dart';
import 'book_mixed_content.dart';
import 'book_source_risk_store.dart';
import 'book_source_links.dart';
import 'book_store.dart';
import 'local_book.dart';
import 'qidian_catalog.dart';
import 'rich_book.dart';

part 'book_comic_download.dart';

typedef BookEdition = ({Book book, List<BookChapter> chapters});
typedef BookImportChanges = ({
  int added,
  int updated,
  int duplicates,
  int skipped,
});

typedef BookSearchUpdate = ({
  String? sourceId,
  List<Book> books,
  int completed,
  int total,
  bool failed,
  int? latencyMs,
});

bool _retiredNewsHost(String host) => const [
  'ithome.com',
  'sspai.com',
  'ifanr.com',
].any((domain) => host == domain || host.endsWith('.$domain'));

Uri? _bookAddress(String query) {
  final uri = Uri.tryParse(query);
  if (uri == null ||
      !uri.hasAuthority ||
      !const {'http', 'https'}.contains(uri.scheme)) {
    return null;
  }
  return legacyBookUri(uri);
}

final class BooksRepository {
  BooksRepository(
    AppDatabase db,
    Directory root,
    OfflineServer offline,
    this.policy,
    Future<void> Function(File, CancellationToken, String) validateAudio, {
    int coverCacheMiB = 32,
    this.downloadText,
  }) : store = BookStore(db),
       riskStore = BookSourceRiskStore(db),
       coverCache = BookCoverCache(
         Directory(p.join(root.path, 'book_covers')),
         maxMiB: coverCacheMiB,
       ),
       _http = MediaHttpClient(
         maxConnectionsPerHost: 2,
         allowLegacyQueryEncoding: true,
       ) {
    documents = Directory(p.join(root.path, 'book_documents'));
    audioFiles = AudiobookFiles(
      Directory(p.join(root.path, 'book_audio')),
      client,
      offline,
      validateAudio,
    );
    _coverSupervisionRestricted =
        policy.supervision.enabled || policy.supervision.corrupted;
    _coverAdultRestricted = policy.filterAdult;
    policy.addListener(_coverPolicyChanged);
  }

  late final Directory documents;
  File documentFile(Book book, String extension) =>
      File(p.join(documents.path, '${book.id}.$extension'));
  final BookStore store;
  final BookSourceRiskStore riskStore;
  final _sourceRiskChanges = ValueNotifier<int>(0);
  Listenable get sourceRiskChanges => _sourceRiskChanges;
  bool get sourceRisksReady => _riskLoaded && !_riskSuspended;
  bool get sourceRisksSuspended => _riskSuspended;
  bool get sourceRiskMutationPending =>
      _evidenceMutations > 0 || _evidenceClosing;
  final BookCoverCache coverCache;
  final ContentPolicy policy;
  late bool _coverSupervisionRestricted;
  late bool _coverAdultRestricted;

  void _coverPolicyChanged() {
    final supervisionRestricted =
        policy.supervision.enabled || policy.supervision.corrupted;
    final adultRestricted = policy.filterAdult;
    if ((supervisionRestricted && !_coverSupervisionRestricted) ||
        (adultRestricted && !_coverAdultRestricted)) {
      unawaited(coverCache.clear().onError((Object _, StackTrace _) {}));
    }
    _coverSupervisionRestricted = supervisionRestricted;
    _coverAdultRestricted = adultRestricted;
  }

  final MediaHttpClient _http;
  @visibleForTesting
  final Future<String> Function(
    BookSource,
    Book,
    BookChapter,
    CancellationToken,
  )?
  downloadText;
  late final client = BookClient(DocumentClient(_http));
  late final qidian = QidianCatalog(client.network, policy, store.db);
  late final AudiobookFiles audioFiles;
  late final Future<List<BookSource>> _builtins = _loadBuiltins();
  final _verifiedSources = <String, BookSource>{};
  final _riskSourceEntries = <String, BookSourceEntry>{};
  final _sourceAssessments = <String, BookSourceAssessment>{};
  final _contentEpochs = <String, int>{};
  final _blockedSourceIds = <String>{};
  final _assessedAdultIds = <String>{};
  final _assessedQuarantinedIds = <String>{};
  final _assessedAdultHosts = <String>{};
  final _assessedQuarantinedHosts = <String>{};
  Future<void>? _riskLoading;
  bool _riskLoaded = false;
  bool _riskSuspended = false;
  int _riskGeneration = 0;
  final _refreshingSubscriptions = <String>{};
  Future<void>? _seeding;
  int _evidenceMutations = 0;
  bool _evidenceClosing = false;
  Future<void>? _closing;
  final _pendingEvidenceMutations = <Completer<void>>{};
  @visibleForTesting
  Future<void> Function()? beforeEvidenceMutationForTesting;
  Future<T> _withEvidenceMutation<T>(Future<T> Function() action) async {
    if (_evidenceClosing) throw StateError('书源服务正在关闭');
    final done = Completer<void>();
    _pendingEvidenceMutations.add(done);
    _evidenceMutations++;
    _sourceRiskChanges.value++;
    try {
      final before = beforeEvidenceMutationForTesting;
      if (before != null) await before();
      return await action();
    } finally {
      _evidenceMutations--;
      _sourceRiskChanges.value++;
      _pendingEvidenceMutations.remove(done);
      done.complete();
    }
  }

  BookDownloadGuard? _downloadGuard;
  BookDownloadGuard get downloadGuard => _downloadGuard ??= BookDownloadGuard(
    store: store,
    risks: riskStore,
    policy: policy,
    sources: _riskSourceEntries,
    verified: _verifiedSources,
    epochs: _contentEpochs,
    ready: () =>
        sourceRisksReady && !_evidenceClosing && _evidenceMutations == 0,
    bookAllowed: bookAllowed,
    entryAllowed: _sourceEntryAllowed,
    generation: () => _riskGeneration,
    ensureReady: ensureSourceRiskLoaded,
  );

  Future<void> ensureCatalog() async {
    if (policy.supervision.enabled || policy.supervision.corrupted) return;
    final running = _seeding ??= _seedCatalog();
    try {
      await running;
    } finally {
      if (identical(_seeding, running)) _seeding = null;
    }
  }

  Future<void> _seedCatalog() async {
    final catalog = await AoaoStarBookCatalog.load();
    // A filtered import skips restricted rows. Revisit the same snapshot when
    // the user later changes the filter, or those rows would be lost forever.
    final filterAdult = policy.filterAdult;
    final revision =
        '${catalog.revision}:adult-${filterAdult ? 'filtered' : 'all'}:2';
    if (await store.read('books_catalog_revision') == revision) return;
    await importSources(
      (await catalog.read()).sources,
      fromCatalog: true,
      catalogRevision: revision,
      catalogAdultFilter: filterAdult,
    );
  }

  Future<List<BookSource>> _loadBuiltins() async {
    final data =
        jsonDecode(
              await rootBundle.loadString(
                'assets/catalogs/books/verified.json',
              ),
            )
            as List;
    final builtins = data
        .cast<Map>()
        .map((s) => BookSource.fromJson(s, builtin: true))
        .toList();
    _verifiedSources.addEntries(
      builtins.map((source) => MapEntry(source.id, source)),
    );
    return builtins;
  }

  /// Load source metadata before exposing saved works or offline chapters.
  /// Source assessments are separate records and survive removal of a source.
  Future<void> ensureSourceRiskLoaded() async {
    if (_riskSuspended) throw const ContentBlocked();
    if (_riskLoaded) return;
    final pending = _riskLoading ??= refreshSourceRisks();
    try {
      await pending;
    } finally {
      if (identical(_riskLoading, pending)) _riskLoading = null;
    }
  }

  Future<void> refreshSourceRisks() async {
    if (_riskSuspended) throw const ContentBlocked();
    _riskLoaded = false;
    final generation = _riskGeneration;
    final entries = await store.sources(await _builtins);
    await store.observeTrackedSources(entries);
    final assessments = await riskStore.all();
    final contentEpochs = await store.contentEpochs();
    final blocked = await store.blockedSources();
    if (_riskSuspended) throw const ContentBlocked();
    // A completed mark/clear may have changed the DB while this snapshot was
    // loading; never replace the newer restriction with an older snapshot.
    if (generation != _riskGeneration) return refreshSourceRisks();
    _riskSourceEntries
      ..clear()
      ..addEntries(entries.map((entry) => MapEntry(entry.source.id, entry)));
    _sourceAssessments
      ..clear()
      ..addAll(assessments);
    _contentEpochs
      ..clear()
      ..addAll(contentEpochs);
    _blockedSourceIds
      ..clear()
      ..addAll(blocked.keys);
    _rebuildAssessmentHosts();
    _riskLoaded = true;
  }

  Future<void> _refreshChangedSources() async {
    _riskGeneration++;
    _riskLoaded = false;
    _sourceRiskChanges.value++;
    try {
      await refreshSourceRisks();
    } finally {
      _sourceRiskChanges.value++;
    }
  }

  void suspendSourceRisks() {
    _riskSuspended = true;
    _riskLoaded = false;
    _riskGeneration++;
    _sourceRiskChanges.value++;
  }

  Future<void> resumeSourceRisks() async {
    _riskSuspended = false;
    try {
      await refreshSourceRisks();
    } finally {
      _sourceRiskChanges.value++;
    }
  }

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

  bool _assessedAdult(String id, String host) =>
      _assessedAdultIds.contains(id) ||
      _assessedAdultHosts.contains(host.toLowerCase());

  bool _assessedQuarantined(String id, String host) =>
      _assessedQuarantinedIds.contains(id) ||
      _assessedQuarantinedHosts.contains(host.toLowerCase());

  Future<BookSourceAssessment> _addSourceAssessment(
    BookSource source, {
    required bool adult,
    required bool quarantine,
    required bool rootPageEvidence,
  }) async {
    final host = source.endpoint.host.toLowerCase();
    final primary = await riskStore.get(source.id);
    final key = primary == null || primary.host == host
        ? source.id
        : BookSourceRiskStore.hostKey(source.id, host);
    final previous = key == source.id
        ? primary
        : await riskStore.getRecord(key);
    if (previous != null && previous.host != host) {
      // A damaged record must never be silently replaced by new evidence.
      throw const FormatException('风险记录损坏，请先人工复核');
    }
    final assessment = BookSourceAssessment(
      sourceId: source.id,
      name: source.name,
      host: host,
      adult: adult || previous?.adult == true,
      quarantined: quarantine || previous?.quarantined == true,
      adultHost: (adult && rootPageEvidence) || previous?.adultHost == true,
      quarantinedHost:
          (quarantine && rootPageEvidence) || previous?.quarantinedHost == true,
      version: (previous?.version ?? 0) + 1,
      recordKey: key,
    );
    await riskStore.write(assessment);
    return assessment;
  }

  void _rememberAssessment(BookSourceAssessment assessment) {
    final previous = _sourceAssessments[assessment.key];
    if (previous != null && previous.version > assessment.version) return;
    _riskGeneration++;
    _sourceAssessments[assessment.key] = assessment;
    _rebuildAssessmentHosts();
  }

  /// Called only for independently supported adult or site-mismatch evidence.
  /// The observed root host applies across kinds and IDs, never sibling hosts.
  /// A successful health check cannot remove this persistent assessment.
  Future<void> markSourceRisk(
    BookSource source, {
    bool adult = false,
    bool quarantine = false,
  }) => _withEvidenceMutation(
    () => _markSourceRisk(source, adult: adult, quarantine: quarantine),
  );

  Future<void> _markSourceRisk(
    BookSource source, {
    required bool adult,
    required bool quarantine,
  }) async {
    if (!adult && !quarantine) throw const FormatException('没有可保存的风险证据');
    _requireSubscriptionAccess();
    await ensureSourceRiskLoaded();
    late BookSourceAssessment assessment;
    await store.db.atomic(() async {
      _requireSubscriptionAccess();
      final current = await store.source(
        _verifiedSources[source.id],
        source.id,
      );
      if (current == null ||
          jsonEncode(current.source.toJson()) != jsonEncode(source.toJson())) {
        throw const FormatException('来源规则已变化，请重新检测');
      }
      assessment = await _addSourceAssessment(
        source,
        adult: adult,
        quarantine: quarantine,
        rootPageEvidence: true,
      );
      _requireSubscriptionAccess();
    }, tables: {'app_meta'});
    _rememberAssessment(assessment);
    policy.refresh();
  }

  /// Risk review is separate from ordinary source lists, which hide the source.
  /// Content policy also applies to the review list itself.
  Future<List<BookSourceRiskEntry>> sourceRiskEntries() async {
    _requireSubscriptionAccess();
    await ensureSourceRiskLoaded();
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
    _requireSubscriptionAccess();
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
    final fixed = _fixedSourceRisk(id, host, source);
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

  bool _fixedSourceRisk(String id, String host, BookSource? source) =>
      quarantinedBookHost(host) ||
      (source == null && quarantinedBookSourceId(id)) ||
      (source != null &&
          source.endpoint.host.toLowerCase() == host &&
          quarantinedBookSource(source));

  /// A review dialog can outlive a policy change or another site's finding.
  /// Recheck its snapshot instead of displaying stale, now restricted rows.
  bool sourceRiskEntryAllowed(BookSourceRiskEntry entry) {
    if (!sourceRisksReady ||
        policy.supervision.enabled ||
        policy.supervision.corrupted) {
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

  /// Explicit manual review is required. A stale review cannot clear a newer
  /// finding, and a bundled fixed quarantine cannot be cleared here.
  Future<void> clearSourceRisk(BookSourceRiskEntry entry) async {
    _requireSubscriptionAccess();
    await ensureSourceRiskLoaded();
    late BookSourceAssessment cleared;
    await store.db.atomic(() async {
      _requireSubscriptionAccess();
      final current = await riskStore.getRecord(
        entry.recordKey ?? entry.sourceId,
      );
      if (current == null ||
          current.sourceId != entry.sourceId ||
          current.host != entry.host ||
          current.version != entry.version ||
          (!current.adult && !current.quarantined)) {
        throw const FormatException('风险记录已变化，请刷新后复核');
      }
      if (current.key != current.sourceId &&
          current.key !=
              BookSourceRiskStore.hostKey(current.sourceId, current.host)) {
        // The host of a damaged secondary record cannot be reconstructed from
        // its hash. Do not report a successful clear that would reappear after
        // restart or discard evidence for an unknown host.
        throw const FormatException(
          '风险记录已损坏，相关来源暂不可用；普通备份不包含书源风险记录，请保留数据并从完整数据库备份恢复',
        );
      }
      final sourceEntry = await store.source(
        _verifiedSources[entry.sourceId],
        entry.sourceId,
      );
      final assessments = await riskStore.all();
      void requireReviewAllowed() {
        _requireSubscriptionAccess();
        final source = sourceEntry?.source;
        final hosts = [current.host, if (source != null) ...source.mediaHosts];
        if (source != null) hosts.add(source.endpoint.host);
        final adultRestricted =
            current.adult ||
            (source != null &&
                (adultBookSource(source) ||
                    adultBookLabels(source.name, sourceEntry!.group))) ||
            hosts.any((host) => adultBookHost(host) || knownAdultHost(host)) ||
            assessments.values.any(
              (risk) =>
                  (risk.sourceId == entry.sourceId && risk.adult) ||
                  (risk.adultHost && hosts.contains(risk.host)),
            );
        if (_fixedSourceRisk(entry.sourceId, current.host, source) ||
            (policy.filterAdult && adultRestricted) ||
            !policy.textAllowed(
              '${source?.name ?? current.name} ${current.host}',
              category: sourceEntry?.group ?? '',
            )) {
          throw const ContentBlocked();
        }
      }

      requireReviewAllowed();
      // Retain a revision tombstone so an old review cannot clear a finding
      // that was later rediscovered after an earlier assessment was cleared.
      cleared = BookSourceAssessment(
        sourceId: current.sourceId,
        name: current.name,
        host: current.host,
        adult: false,
        quarantined: false,
        adultHost: false,
        quarantinedHost: false,
        version: current.version + 1,
        recordKey: current.key,
      );
      await riskStore.write(cleared);
      requireReviewAllowed();
    }, tables: {'app_meta'});
    _rememberAssessment(cleared);
    policy.refresh();
  }

  bool kindAllowed(BookKind kind) =>
      !policy.supervision.corrupted &&
      !((kind == BookKind.audio || kind == BookKind.comic) &&
          policy.supervision.enabled);

  bool sourceAllowed(BookSource source) {
    if (!_riskLoaded) return false;
    final hosts = [source.endpoint.host, ...source.mediaHosts];
    return kindAllowed(source.kind) &&
        !_blockedSourceIds.contains(source.id) &&
        !quarantinedBookSource(source) &&
        !hosts.any(
          (host) =>
              quarantinedBookHost(host) ||
              _assessedQuarantined(source.id, host),
        ) &&
        (source.kind != BookKind.text ||
            !_retiredNewsHost(source.endpoint.host)) &&
        !(policy.filterAdult &&
            (adultBookSource(source) ||
                hosts.any(
                  (host) =>
                      adultBookHost(host) ||
                      knownAdultHost(host) ||
                      _assessedAdult(source.id, host),
                ))) &&
        policy.textAllowed(
          '${source.name} ${source.endpoint.host}',
          category: source.group,
        ) &&
        !(policy.supervision.enabled && !source.builtin);
  }

  bool _sourceEntryAllowed(BookSourceEntry entry) =>
      sourceAllowed(entry.source) &&
      policy.textAllowed('', category: entry.group) &&
      !(policy.filterAdult && adultBookLabels(entry.source.name, entry.group));

  /// Evaluate both source metadata and the user's stored group at display time.
  bool sourceEntryAllowed(BookSourceEntry entry) => _sourceEntryAllowed(entry);

  bool bookAllowed(Book book) {
    if (!_riskLoaded && book.sourceId != 'local') return false;
    final verified = _verifiedSources[book.sourceId];
    final sourceEntry = _riskSourceEntries[book.sourceId];
    return kindAllowed(book.kind) &&
        !_blockedSourceIds.contains(book.sourceId) &&
        !(sourceEntry == null && quarantinedBookSourceId(book.sourceId)) &&
        !(sourceEntry != null &&
            quarantinedBookSourceId(book.sourceId) &&
            book.uri.host.toLowerCase() !=
                sourceEntry.source.endpoint.host.toLowerCase()) &&
        !(policy.filterAdult &&
            sourceEntry == null &&
            verified == null &&
            book.sourceId != 'local' &&
            book.sourceId != qidianRecommendationId) &&
        !quarantinedBookHost(book.uri.host) &&
        !_assessedQuarantined(book.sourceId, book.uri.host) &&
        (sourceEntry == null || _sourceEntryAllowed(sourceEntry)) &&
        (book.kind != BookKind.text || !_retiredNewsHost(book.uri.host)) &&
        (!policy.supervision.enabled ||
            (verified != null && sourceAllowed(verified))) &&
        !(policy.filterAdult &&
            (knownAdultHost(book.uri.host) ||
                adultBookHost(book.uri.host) ||
                adultBundledSourceId(book.sourceId) ||
                _assessedAdult(book.sourceId, book.uri.host))) &&
        policy.textAllowed(
          '${book.title} ${book.author} ${book.description} ${book.category} '
          '${book.latestChapter} ${book.updatedLabel} ${book.rankLabel} ${book.uri.host}',
        );
  }

  Future<List<BookSourceEntry>> sources(
    BookKind kind, {
    bool enabledOnly = false,
  }) async {
    await ensureSourceRiskLoaded();
    final blocked = await store.blockedSources();
    return (await store.sources(await _builtins, enabledOnly: enabledOnly))
        .where(
          (entry) =>
              entry.source.kind == kind &&
              !blocked.containsKey(entry.source.id) &&
              _sourceEntryAllowed(entry),
        )
        .toList();
  }

  Future<BookSource> _active(Book book) async {
    if (!bookAllowed(book)) throw const ContentBlocked();
    return _enabledSource(book.kind, book.sourceId);
  }

  Future<BookSourceEntry?> sourceEntry(BookKind kind, String id) async {
    await ensureSourceRiskLoaded();
    await _builtins;
    if (await _blocked(id)) return null;
    final entry = await store.source(_verifiedSources[id], id);
    if (entry == null ||
        entry.source.kind != kind ||
        !_sourceEntryAllowed(entry)) {
      return null;
    }
    return entry;
  }

  Future<BookSource> _enabledSource(BookKind kind, String id) async {
    await ensureSourceRiskLoaded();
    await _builtins;
    if (await _blocked(id)) throw const ContentBlocked();
    final entry = await store.source(_verifiedSources[id], id);
    if (entry == null || !entry.enabled || entry.source.kind != kind) {
      throw const FormatException('请先启用该来源');
    }
    if (!_sourceEntryAllowed(entry)) {
      throw const ContentBlocked();
    }
    return entry.source;
  }

  Future<List<LegadoCategory>> categories(
    BookKind kind,
    String sourceId,
    CancellationToken token,
  ) async {
    final source = await _enabledSource(kind, sourceId);
    final categories = await client.categories(source, token);
    token.check();
    if (!sourceAllowed(source)) throw const ContentBlocked();
    return categories
        .where((category) => policy.textAllowed(category.title))
        .toList();
  }

  Future<BookDiscoveryPage> discover(
    BookKind kind,
    String sourceId,
    CancellationToken token, {
    LegadoCategory? category,
    int page = 1,
    String? cursor,
  }) async {
    final source = await _enabledSource(kind, sourceId);
    final result = await client.discover(
      source,
      token,
      category: category,
      page: page,
      cursor: cursor,
    );
    if (!sourceAllowed(source) || await _blocked(sourceId)) {
      throw const ContentBlocked();
    }
    token.check();
    return (books: result.books.where(bookAllowed).toList(), next: result.next);
  }

  Future<void> restoreDefaultSources(BookKind kind) =>
      _withEvidenceMutation(() => _restoreDefaultSources(kind));

  Future<void> _restoreDefaultSources(BookKind kind) async {
    policy.supervision.require(SensitiveOperation.channels);
    await ensureSourceRiskLoaded();
    final builtins = (await _builtins).where((s) => s.kind == kind).toList();
    final blocked = await store.blockedSources();
    final existing = await store.sources(await _builtins);
    await store.db.atomic(() async {
      policy.supervision.require(SensitiveOperation.channels);
      for (final entry in existing.where((e) => e.source.kind == kind)) {
        policy.supervision.require(SensitiveOperation.channels);
        await store.saveSource(entry.source, {'enabled': false});
      }
      for (final source in builtins) {
        policy.supervision.require(SensitiveOperation.channels);
        if (!source.defaultEnabled ||
            blocked.containsKey(source.id) ||
            !sourceAllowed(source)) {
          continue;
        }
        final key = 'books_source:${source.id}';
        final old = await store.read(key);
        policy.supervision.require(SensitiveOperation.channels);
        await store.write(key, {
          if (old is Map) ...old,
          'enabled': true,
          'removed': false,
        });
      }
      policy.supervision.require(SensitiveOperation.channels);
    }, tables: {'app_meta'});
    await _refreshChangedSources();
  }

  Future<void> saveSource(BookSource source, Map<String, Object?> updates) =>
      updates.keys.any(
        (key) => const {'group', 'source', 'removed'}.contains(key),
      )
      ? _withEvidenceMutation(() => _saveSource(source, updates))
      : _saveSource(source, updates);

  Future<void> _saveSource(
    BookSource source,
    Map<String, Object?> updates,
  ) async {
    policy.supervision.require(SensitiveOperation.channels);
    await ensureSourceRiskLoaded();
    if (!sourceAllowed(source)) throw const ContentBlocked();
    BookSourceAssessment? retainedEvidence;
    await store.db.atomic(() async {
      policy.supervision.require(SensitiveOperation.channels);
      if (await _blocked(source.id)) throw const ContentBlocked();
      policy.supervision.require(SensitiveOperation.channels);
      if (!sourceAllowed(source)) throw const ContentBlocked();
      if (updates.containsKey('group')) {
        final current = await store.source(
          _verifiedSources[source.id],
          source.id,
        );
        if (current != null &&
            (adultBookSource(current.source) ||
                adultBookLabels(current.source.name, current.group))) {
          retainedEvidence = await _addSourceAssessment(
            current.source,
            adult: true,
            quarantine: false,
            rootPageEvidence: false,
          );
        }
      }
      policy.supervision.require(SensitiveOperation.channels);
      if (!sourceAllowed(source)) throw const ContentBlocked();
      await store.saveSource(source, updates);
      policy.supervision.require(SensitiveOperation.channels);
    }, tables: {'app_meta'});
    if (retainedEvidence != null) _rememberAssessment(retainedEvidence!);
    if (updates.keys.any(
      (key) => const {'group', 'enabled', 'removed', 'source'}.contains(key),
    )) {
      _riskGeneration++;
      _riskLoaded = false;
      _sourceRiskChanges.value++;
      await refreshSourceRisks();
      _sourceRiskChanges.value++;
      if (updates.containsKey('group') || updates.containsKey('source')) {
        policy.refresh();
      }
    }
  }

  Future<void> setSourcesEnabled(
    BookKind kind,
    Set<String> ids,
    bool enabled,
  ) => _withEvidenceMutation(() => _setSourcesEnabled(kind, ids, enabled));

  Future<void> _setSourcesEnabled(
    BookKind kind,
    Set<String> ids,
    bool enabled,
  ) async {
    policy.supervision.require(SensitiveOperation.channels);
    var changed = false;
    await store.db.atomic(() async {
      final eligible = (await sources(kind)).where(
        (entry) => ids.contains(entry.source.id) && entry.enabled != enabled,
      );
      policy.supervision.require(SensitiveOperation.channels);
      final eligibleIds = eligible.map((entry) => entry.source.id).toSet();
      if (eligibleIds.isNotEmpty) {
        await store.setSourcesEnabled(eligibleIds, enabled);
        changed = true;
      }
      policy.supervision.require(SensitiveOperation.channels);
    }, tables: {'app_meta'});
    if (changed) {
      await _refreshChangedSources();
    }
  }

  Future<void> blockSource(BookSource source) =>
      _withEvidenceMutation(() => _blockSource(source));

  Future<void> _blockSource(BookSource source) async {
    await ensureSourceRiskLoaded();
    await store.db.atomic(() async {
      policy.supervision.require(SensitiveOperation.channels);
      if (!sourceAllowed(source)) throw const ContentBlocked();
      final blocked = await store.blockedSources();
      policy.supervision.require(SensitiveOperation.channels);
      if (!sourceAllowed(source)) throw const ContentBlocked();
      await store.write('books_source_blacklist', {
        ...blocked,
        source.id: '${source.name} · ${source.endpoint.host}',
      });
      final aliases = await store.read('books_source_blacklist_aliases');
      policy.supervision.require(SensitiveOperation.channels);
      await store.write('books_source_blacklist_aliases', {
        if (aliases is Map) ...aliases,
        _blacklistAlias(source): source.id,
      });
      policy.supervision.require(SensitiveOperation.channels);
      await store.saveSource(source, {'enabled': false});
      policy.supervision.require(SensitiveOperation.channels);
    }, tables: {'app_meta'});
    // Publish the committed restriction before rebuilding the full snapshot,
    // so an active offline player pauses as soon as the blacklist changes.
    _blockedSourceIds.add(source.id);
    _riskGeneration++;
    policy.refresh();
    await refreshSourceRisks();
    policy.refresh();
  }

  Future<bool> _blocked(String id) async =>
      (await store.blockedSources()).containsKey(id);

  String _blacklistAlias(BookSource source) {
    final host = source.endpoint.host.replaceFirst(RegExp(r'^www\.'), '');
    final path = source.endpoint.path == '/' ? '' : source.endpoint.path;
    return '${source.kind.name}:$host$path?${source.endpoint.query}:${source.sourceKey}';
  }

  Future<void> unblockSource(String id) async {
    await store.db.atomic(() async {
      policy.supervision.require(SensitiveOperation.channels);
      final blocked = await store.blockedSources()
        ..remove(id);
      policy.supervision.require(SensitiveOperation.channels);
      await store.write('books_source_blacklist', blocked);
      final aliases = await store.read('books_source_blacklist_aliases');
      policy.supervision.require(SensitiveOperation.channels);
      if (aliases is Map) {
        await store.write(
          'books_source_blacklist_aliases',
          {...aliases}..removeWhere((_, sourceId) => sourceId == id),
        );
      }
      policy.supervision.require(SensitiveOperation.channels);
    }, tables: {'app_meta'});
    _riskGeneration++;
    await refreshSourceRisks();
    policy.refresh();
  }

  void _requireSubscriptionAccess() {
    policy.supervision.require(SensitiveOperation.channels);
    if (policy.supervision.enabled || policy.supervision.corrupted) {
      throw const ContentBlocked();
    }
  }

  Future<({BookSourceImport parsed, BookImportChanges changes})> subscribe(
    String address,
    CancellationToken token,
  ) async {
    _requireSubscriptionAccess();
    final uri = bookSourceLink(address);
    final id = bookSubscriptionId(uri);
    if (!_refreshingSubscriptions.add(id)) {
      throw const FormatException('此订阅正在刷新');
    }
    try {
      final input = await BookSourceDocuments(client.network, (host) {
        _requireSubscriptionAccess();
        return policy.textAllowed(host) &&
            !(policy.filterAdult && knownAdultHost(host));
      }).load(uri, token);
      token.check();
      final parsed = await parseBookSourcesOffThread(input);
      token.check();
      if (parsed.sources.isEmpty) {
        throw FormatException('没有可导入来源${parsed.issueSummary}');
      }
      final changes = await importSources(
        parsed.sources,
        subscription: uri,
        token: token,
      );
      return (parsed: parsed, changes: changes);
    } finally {
      _refreshingSubscriptions.remove(id);
    }
  }

  Future<List<BookSourceSubscription>> subscriptions() async {
    if (policy.supervision.enabled || policy.supervision.corrupted) return [];
    return (await store.subscriptions())
        .where(
          (entry) =>
              policy.textAllowed(entry.url.host) &&
              !(policy.filterAdult && knownAdultHost(entry.url.host)),
        )
        .toList();
  }

  Future<({BookSourceImport parsed, BookImportChanges changes})> importCatalog(
    AoaoStarBookCatalog catalog,
    CancellationToken token, {
    String? packId,
  }) async {
    _requireSubscriptionAccess();
    token.check();
    final parsed = await catalog.read(packId: packId);
    token.check();
    final changes = await importSources(
      parsed.sources,
      fromCatalog: true,
      token: token,
    );
    return (parsed: parsed, changes: changes);
  }

  Future<void> removeSubscription(BookSourceSubscription entry) async {
    _requireSubscriptionAccess();
    if (_refreshingSubscriptions.contains(entry.id)) {
      throw const FormatException('请先完成订阅刷新');
    }
    await store.deleteSubscription(entry);
  }

  Future<BookImportChanges> importSources(
    List<BookSource> incoming, {
    Uri? subscription,
    CancellationToken? token,
    bool fromCatalog = false,
    String? catalogRevision,
    bool? catalogAdultFilter,
  }) => _withEvidenceMutation(
    () => _importSources(
      incoming,
      subscription: subscription,
      token: token,
      fromCatalog: fromCatalog,
      catalogRevision: catalogRevision,
      catalogAdultFilter: catalogAdultFilter,
    ),
  );

  Future<BookImportChanges> _importSources(
    List<BookSource> incoming, {
    Uri? subscription,
    CancellationToken? token,
    bool fromCatalog = false,
    String? catalogRevision,
    bool? catalogAdultFilter,
  }) async {
    policy.supervision.require(SensitiveOperation.channels);
    await ensureSourceRiskLoaded();
    final builtins = await _builtins;
    final subscriptionId = subscription == null
        ? null
        : bookSubscriptionId(subscription);
    var added = 0;
    var updated = 0;
    var duplicates = 0;
    var skipped = 0;
    var recoveredQuarantine = false;
    final retainedAssessments = <String, BookSourceAssessment>{};
    await store.db.atomic(() async {
      final current = await store.sources(builtins);
      final existing = {for (final entry in current) entry.source.id: entry};
      final blocked = await store.blockedSources();
      final aliases = await store.blockedAliases();
      final seen = <String>{};
      final customCount = current
          .where((entry) => !entry.source.builtin && !entry.fromCatalog)
          .length;
      final pending = <({BookSource source, BookSourceEntry? previous})>[];
      Future<void> flush() async {
        await store.writeImported(
          pending,
          subscriptionId: subscriptionId,
          fromCatalog: fromCatalog,
        );
        pending.clear();
      }

      for (final candidate in incoming) {
        token?.check();
        policy.supervision.require(SensitiveOperation.channels);
        if (subscription != null || fromCatalog) _requireSubscriptionAccess();
        if (catalogAdultFilter != null &&
            policy.filterAdult != catalogAdultFilter) {
          throw const ContentBlocked();
        }
        var source = _keepLegacyKey(candidate, existing);
        final previous = existing[source.id];
        if (previous != null &&
            (adultBookSource(previous.source) ||
                adultBookLabels(previous.source.name, previous.group)) &&
            !source.adultEvidence) {
          source = BookSource.fromJson({
            ...source.toJson(),
            'adultEvidence': true,
          });
        }
        // A subscription may replace an ordinary source with explicitly
        // adult-labelled metadata. When filtering rejects that update, the
        // previous enabled version must not continue to expose its cached data.
        if (previous != null &&
            policy.filterAdult &&
            adultBookSource(source) &&
            !_assessedAdultIds.contains(source.id) &&
            !retainedAssessments.containsKey(source.id)) {
          retainedAssessments[source.id] = await _addSourceAssessment(
            previous.source,
            adult: true,
            quarantine: false,
            rootPageEvidence: false,
          );
        }
        if (aliases.contains(_blacklistAlias(candidate)) ||
            blocked.containsKey(candidate.id) ||
            blocked.containsKey(source.id) ||
            !sourceAllowed(source)) {
          skipped++;
          continue;
        }
        if (!seen.add(source.id)) {
          duplicates++;
          continue;
        }
        if (previous != null) {
          // A previously installed, reviewed unsafe or unavailable rule is
          // hidden from normal management. A user can explicitly import a
          // different rule without silently re-enabling its old preference.
          // Automatic catalog/subscription refreshes never perform this repair.
          if (knownUnsafeBookRule(previous.source) ||
              knownUnavailableBookRule(previous.source)) {
            final manualReplacement =
                subscriptionId == null &&
                !fromCatalog &&
                !previous.source.builtin &&
                !policy.supervision.enabled &&
                !policy.supervision.corrupted &&
                previous.source.kind == source.kind &&
                previous.source.endpoint == source.endpoint &&
                !quarantinedBookSource(source);
            if (!manualReplacement) {
              skipped++;
              continue;
            }
            await flush();
            policy.supervision.require(SensitiveOperation.channels);
            if (policy.supervision.enabled || !sourceAllowed(source)) {
              throw const ContentBlocked();
            }
            // Update only the rule and enabled state. The original group,
            // favorite and ownership metadata remain available for the user.
            await store.saveSource(previous.source, {
              'source': source.toJson(),
              'enabled': false,
              'health': '',
              'checkedAt': null,
            });
            policy.supervision.require(SensitiveOperation.channels);
            if (policy.supervision.enabled || !sourceAllowed(source)) {
              throw const ContentBlocked();
            }
            updated++;
            recoveredQuarantine = true;
            continue;
          }
          final owned =
              subscriptionId != null &&
              previous.subscriptionId == subscriptionId;
          final newerCatalog =
              fromCatalog &&
              previous.fromCatalog &&
              source.updatedAt > previous.source.updatedAt;
          if (!previous.source.builtin &&
              (owned || newerCatalog) &&
              jsonEncode(source.toJson()) !=
                  jsonEncode(previous.source.toJson())) {
            pending.add((source: source, previous: previous));
            updated++;
          } else {
            duplicates++;
          }
        } else if (!fromCatalog && customCount + added >= 12000) {
          skipped++;
        } else {
          pending.add((source: source, previous: null));
          added++;
        }
        if (pending.length >= 128) await flush();
      }
      if (pending.isNotEmpty) await flush();
      token?.check();
      if (subscription != null || fromCatalog) _requireSubscriptionAccess();
      if (catalogAdultFilter != null &&
          policy.filterAdult != catalogAdultFilter) {
        throw const ContentBlocked();
      }
      if (catalogRevision != null) {
        await store.write('books_catalog_revision', catalogRevision);
      }
      await _recordSubscription(subscription, added + updated + duplicates);
      policy.supervision.require(SensitiveOperation.channels);
    }, tables: {'app_meta'});
    for (final assessment in retainedAssessments.values) {
      _rememberAssessment(assessment);
    }
    if (added > 0 || updated > 0) {
      _riskGeneration++;
      _riskLoaded = false;
      _sourceRiskChanges.value++;
      await refreshSourceRisks();
      _sourceRiskChanges.value++;
      policy.refresh();
    }
    if (retainedAssessments.isNotEmpty || recoveredQuarantine) {
      policy.refresh();
    }
    return (
      added: added,
      updated: updated,
      duplicates: duplicates,
      skipped: skipped,
    );
  }

  Future<void> _recordSubscription(Uri? address, int count) async {
    if (address == null || count == 0) return;
    _requireSubscriptionAccess();
    await store.saveSubscription(
      BookSourceSubscription(
        address,
        count,
        DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  BookSource _keepLegacyKey(
    BookSource source,
    Map<String, BookSourceEntry> existing,
  ) {
    if (source.sourceKey.isEmpty ||
        source.sourceKey.contains('#') ||
        source.sourceKey.startsWith('alias:') ||
        existing.containsKey(source.id)) {
      return source;
    }
    final legacy = existing[source.legacyId]?.source;
    if (legacy == null ||
        legacy.builtin ||
        legacy.legado == null ||
        legacy.endpoint != source.endpoint) {
      return source;
    }
    return BookSource.fromJson(source.toJson()..remove('sourceKey'));
  }

  Future<void> removeSource(BookSource source) =>
      _withEvidenceMutation(() => _removeSource(source));

  Future<void> _removeSource(BookSource source) async {
    policy.supervision.require(SensitiveOperation.channels);
    await ensureSourceRiskLoaded();
    if (!sourceAllowed(source)) throw const ContentBlocked();
    BookSourceAssessment? retainedEvidence;
    await store.db.atomic(() async {
      policy.supervision.require(SensitiveOperation.channels);
      final current = await store.source(
        _verifiedSources[source.id],
        source.id,
      );
      policy.supervision.require(SensitiveOperation.channels);
      if (!sourceAllowed(current?.source ?? source)) {
        throw const ContentBlocked();
      }
      if (current != null &&
          (adultBookSource(current.source) ||
              adultBookLabels(current.source.name, current.group))) {
        retainedEvidence = await _addSourceAssessment(
          current.source,
          adult: true,
          quarantine: false,
          rootPageEvidence: false,
        );
      }
      policy.supervision.require(SensitiveOperation.channels);
      if (!sourceAllowed(current?.source ?? source)) {
        throw const ContentBlocked();
      }
      await store.deleteSource(source);
      policy.supervision.require(SensitiveOperation.channels);
    }, tables: {'app_meta'});
    if (retainedEvidence != null) _rememberAssessment(retainedEvidence!);
    _riskGeneration++;
    _riskLoaded = false;
    _sourceRiskChanges.value++;
    await refreshSourceRisks();
    _sourceRiskChanges.value++;
    policy.refresh();
  }

  Future<void> probe(
    BookSource source,
    String query,
    CancellationToken token,
  ) async {
    policy.supervision.require(SensitiveOperation.channels);
    await ensureSourceRiskLoaded();
    if (!sourceAllowed(source) || await _blocked(source.id)) {
      throw const ContentBlocked();
    }
    final watch = Stopwatch()..start();
    var status = '';
    var stage = '搜索';
    try {
      final books = await client.books(
        source,
        query,
        token,
        bookAddress: _bookAddress(query),
      );
      final book = books.where(bookAllowed).firstOrNull;
      if (book == null) throw const FormatException('没有匹配作品，试试该源中已知的书名');
      stage = '详情';
      final details = await client.details(source, book, token);
      if (!bookAllowed(details)) throw const ContentBlocked();
      stage = '目录';
      final chapters = await client.chapters(source, details, token);
      final chapter = chapters
          .where((c) => policy.textAllowed(c.title))
          .firstOrNull;
      if (chapter == null) throw const FormatException('目录没有可用章节');
      stage = source.kind == BookKind.text
          ? '正文'
          : source.kind == BookKind.comic
          ? '图片'
          : '音频';
      if (source.kind == BookKind.text) {
        final body = await client.text(source, chapter, token, book: book);
        if (body.trim().length < 40 || !policy.textAllowed(body)) {
          throw const FormatException('正文为空、过短或被内容策略拦截');
        }
      } else if (source.kind == BookKind.comic) {
        final images = await client.chapterImages(
          source,
          chapter,
          token,
          book: details,
        );
        if (images.isEmpty) throw const FormatException('章节没有可阅读的图片');
        final sample = await client.fetch(
          source,
          images.first,
          token,
          media: true,
          maxBytes: 4 * 1024 * 1024,
        );
        if (sample.contentType?.toLowerCase().startsWith('image/') != true) {
          throw const FormatException('章节图片地址未返回图片');
        }
        await validateReadableBookImage(images.first, sample.bytes);
        token.check();
      } else {
        final (uri, bytes) = await client.sampleAudio(
          source,
          chapter,
          token,
          book: book,
        );
        audiobookExtension(
          bytes,
          isM4b: uri.path.toLowerCase().endsWith('.m4b'),
        );
      }
      status = '可用 · ${watch.elapsedMilliseconds} ms';
    } on FormatException catch (error) {
      status = '$stage · ${error.message}';
    } on RemoteFailure catch (error) {
      status = '$stage · ${error.message}';
    } on Exception {
      status = '$stage · 检测失败';
    }
    token.check();
    await saveSource(source, {
      'health': status,
      'checkedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<({List<Book> books, int failed})> find(
    BookKind kind,
    String query,
    CancellationToken token, {
    String? sourceId,
    LegadoCategory? category,
    int page = 1,
    int? maxSources,
    Set<String>? sourceIds,
    String? preferredSource,
    String? excludedSource,
    bool skipQidian = false,
    bool favorites = false,
    BookSearchField field = BookSearchField.all,
    List<BookSourceEntry>? availableSources,
    void Function(BookSearchUpdate)? onProgress,
  }) async {
    await ensureSourceRiskLoaded();
    if (!kindAllowed(kind)) throw const ContentBlocked();
    if (query.isNotEmpty && !policy.textAllowed(query)) {
      throw const ContentBlocked();
    }
    final address = _bookAddress(query);
    final entries = (availableSources ?? await sources(kind, enabledOnly: true))
        .where((entry) {
          if (!entry.enabled ||
              entry.source.kind != kind ||
              !_currentSearchEntry(entry) ||
              (skipQidian && isQidianHost(entry.source.endpoint.host)) ||
              entry.source.id == excludedSource ||
              (sourceId != null && sourceId != entry.source.id) ||
              (sourceIds != null && !sourceIds.contains(entry.source.id))) {
            return false;
          }
          if (address != null) return entry.source.acceptsBookAddress(address);
          return entry.source.hasDiscovery ||
              (query.isNotEmpty && entry.source.hasSearch);
        })
        .toList();
    final prioritized = _prioritize(entries, preferredSource, favorites);
    final selected = maxSources == null
        ? prioritized
        : prioritized.take(maxSources).toList();
    token.check();
    onProgress?.call((
      sourceId: null,
      books: [],
      completed: 0,
      total: selected.length,
      failed: false,
      latencyMs: null,
    ));
    return _searchSources(
      selected,
      query,
      token,
      category,
      page,
      address,
      field,
      onProgress,
    );
  }

  List<BookSourceEntry> _prioritize(
    Iterable<BookSourceEntry> entries,
    String? preferredSource,
    bool favorites,
  ) => [
    ...entries.where(
      (entry) =>
          entry.source.id == preferredSource && (!favorites || entry.favorite),
    ),
    ...entries.where(
      (entry) => entry.source.id != preferredSource && entry.favorite,
    ),
    if (!favorites)
      ...entries.where(
        (entry) => entry.source.id != preferredSource && !entry.favorite,
      ),
  ];

  bool _currentSearchEntry(BookSourceEntry snapshot) {
    final current = _riskSourceEntries[snapshot.source.id];
    if (current == null || !current.enabled || !_sourceEntryAllowed(current)) {
      return false;
    }
    return identical(current.source, snapshot.source) ||
        jsonEncode(current.source.toJson()) ==
            jsonEncode(snapshot.source.toJson());
  }

  Future<({List<Book> books, int failed})> _searchSources(
    List<BookSourceEntry> selected,
    String query,
    CancellationToken token,
    LegadoCategory? category,
    int page,
    Uri? address,
    BookSearchField field,
    void Function(BookSearchUpdate)? onProgress,
  ) async {
    final results = <String, List<Book>>{};
    final match = address == null && query.trim().isNotEmpty
        ? BookSearchQuery(query, field)
        : null;
    var failed = 0;
    var cursor = 0, completed = 0;
    Future<void> fetchSources() async {
      while (cursor < selected.length) {
        token.check();
        final entry = selected[cursor++];
        final source = entry.source;
        var books = <Book>[];
        var failure = false;
        int? latencyMs;
        try {
          if (_currentSearchEntry(entry) &&
              !await _blocked(source.id) &&
              _currentSearchEntry(entry)) {
            final watch = Stopwatch()..start();
            final found = await client.books(
              source,
              query,
              token,
              category: category,
              page: page,
              bookAddress: address,
            );
            latencyMs = watch.elapsedMilliseconds;
            if (_currentSearchEntry(entry) &&
                !await _blocked(source.id) &&
                _currentSearchEntry(entry)) {
              final allowEpisodeMatches =
                  source.kind == BookKind.audio &&
                  source.format == BookFormat.feed &&
                  field == BookSearchField.all;
              books = found
                  .where(
                    (book) =>
                        bookAllowed(book) &&
                        (match == null ||
                            allowEpisodeMatches ||
                            match.rank(book) != null),
                  )
                  .toList();
            }
          }
        } on Exception {
          failed++;
          failure = true;
        }
        token.check();
        results[source.id] = books;
        onProgress?.call((
          sourceId: source.id,
          books: books,
          completed: ++completed,
          total: selected.length,
          failed: failure,
          latencyMs: latencyMs,
        ));
      }
    }

    await Future.wait(
      List.generate(math.min(4, selected.length), (_) => fetchSources()),
    );
    token.check();
    return (
      books: selected
          .expand((entry) => results[entry.source.id] ?? const <Book>[])
          .where(bookAllowed)
          .toList(),
      failed: failed,
    );
  }

  Future<List<BookChapter>> chapters(
    Book book,
    CancellationToken token, {
    bool refresh = false,
  }) async {
    token.check();
    if (book.sourceId != 'local') await ensureSourceRiskLoaded();
    if (!bookAllowed(book) || await _blocked(book.sourceId)) {
      throw const ContentBlocked();
    }
    token.check();
    final saved = await store.entry(book);
    token.check();
    if (!bookAllowed(book) || await _blocked(book.sourceId)) {
      throw const ContentBlocked();
    }
    token.check();
    if (saved != null && saved.chapters.isNotEmpty && !refresh) {
      return saved.chapters.where((c) => policy.textAllowed(c.title)).toList();
    }
    final source = await _active(book);
    final chapters = (await client.chapters(
      source,
      book,
      token,
    )).where((c) => policy.textAllowed(c.title)).toList();
    token.check();
    if (!sourceAllowed(source) ||
        !bookAllowed(book) ||
        await _blocked(book.sourceId)) {
      throw const ContentBlocked();
    }
    token.check();
    return chapters;
  }

  Future<Book> details(Book book, CancellationToken token) async {
    token.check();
    if (book.sourceId != 'local') await ensureSourceRiskLoaded();
    if (!bookAllowed(book)) throw const ContentBlocked();
    if (book.sourceId == 'local') return book;
    final source = await _active(book);
    final result = await client.details(source, book, token);
    token.check();
    if (!sourceAllowed(source) ||
        !bookAllowed(result) ||
        await _blocked(book.sourceId)) {
      throw const ContentBlocked();
    }
    token.check();
    return result;
  }

  Future<void> checkFollowing(BookKind kind, CancellationToken token) async {
    await ensureSourceRiskLoaded();
    final entries = (await store.shelf()).where(
      (entry) =>
          entry.following && entry.book.kind == kind && bookAllowed(entry.book),
    );
    for (final entry in entries) {
      token.check();
      try {
        final fresh = await chapters(entry.book, token, refresh: true);
        token.check();
        if (fresh.isEmpty || !bookAllowed(entry.book)) continue;
        await store.updateFollowedChapters(entry.book, fresh);
      } on Exception {
        token.check();
      }
    }
  }

  /// Refreshes only the books currently shown on this shelf, including books
  /// that have not been marked as followed.
  Future<void> checkShelfUpdates(
    Iterable<BookShelfEntry> entries,
    CancellationToken token,
  ) async {
    token.check();
    await ensureSourceRiskLoaded();
    for (final entry in entries) {
      token.check();
      final book = entry.book;
      if (book.sourceId == 'local' || !bookAllowed(book)) continue;
      try {
        final fresh = await chapters(book, token, refresh: true);
        token.check();
        if (fresh.isNotEmpty && bookAllowed(book)) {
          await store.updateShelfChapters(book, fresh);
        }
      } on Exception {
        token.check();
      }
    }
  }

  Future<List<BookEdition>> alternatives(
    Book book,
    CancellationToken token,
  ) async {
    final title = bookIdentity(book.title);
    final author = bookIdentity(book.author);
    if (author.isEmpty) return [];
    final results = await find(
      book.kind,
      book.title,
      token,
      field: BookSearchField.title,
      excludedSource: book.sourceId,
    );
    final candidates = results.books
        .where(
          (other) =>
              other.sourceId != book.sourceId &&
              bookIdentity(other.title) == title &&
              bookIdentity(other.author) == author,
        )
        .toList();
    final editions = List<BookEdition?>.filled(candidates.length, null);
    var cursor = 0;
    Future<void> loadCatalogs() async {
      while (cursor < candidates.length) {
        token.check();
        final index = cursor++;
        final candidate = candidates[index];
        try {
          final catalog = await chapters(candidate, token);
          token.check();
          if (catalog.isNotEmpty) {
            editions[index] = (book: candidate, chapters: catalog);
          }
        } on Exception {
          token.check();
        }
      }
    }

    await Future.wait(
      List.generate(math.min(3, candidates.length), (_) => loadCatalogs()),
    );
    token.check();
    return editions.whereType<BookEdition>().toList();
  }

  BookChapter? matchingChapter(
    List<BookChapter> chapters,
    BookChapter reference,
  ) {
    final key = bookIdentity(reference.title);
    if (key.isEmpty) return null;
    final matches = chapters
        .where((chapter) => bookIdentity(chapter.title) == key)
        .take(2)
        .toList();
    return matches.length == 1 ? matches.single : null;
  }

  void requireBook(Book book, BookChapter chapter) {
    if (!bookAllowed(book) || !policy.textAllowed(chapter.title)) {
      throw const ContentBlocked();
    }
  }

  void requireDownloadEvidence(BookDownloadEvidence? evidence) {
    if (evidence != null && !downloadGuard.allowed(evidence)) {
      throw const ContentBlocked();
    }
  }

  /// Existing unlabelled files remain available under the existing policy;
  /// they are never treated as evidence for a subsequent download.
  Future<({String? body, BookDownloadEvidence? evidence})> offlineText(
    Book book,
    BookChapter chapter,
    CancellationToken token,
  ) async {
    token.check();
    if (book.sourceId != 'local') await ensureSourceRiskLoaded();
    requireBook(book, chapter);
    final proven = await store.provenText(book, chapter);
    if (proven != null) {
      await downloadGuard.validate(proven.evidence);
      token.check();
      requireBook(book, chapter);
      if (!policy.textAllowed(proven.body)) throw const ContentBlocked();
      requireDownloadEvidence(proven.evidence);
      return (body: proven.body, evidence: proven.evidence);
    }
    final body = await store.text(book, chapter);
    token.check();
    requireBook(book, chapter);
    if (body != null && !policy.textAllowed(body)) throw const ContentBlocked();
    return (body: body, evidence: null);
  }

  Future<Set<String>> savedAudio(Book book) async => {
    ...await audioFiles.saved(book),
    ...await store.provenChapters('audio', book),
  };

  /// Explicit downloads may reuse only evidence that is currently valid.
  /// Unlabelled legacy data and stale revisions remain stored but are not
  /// counted as a successful new download.
  Future<Set<String>> reusableDownloads(
    Book book,
    Iterable<BookChapter> chapters,
    CancellationToken token,
  ) async {
    if (book.kind == BookKind.comic) return store.savedImages(book);
    final type = book.kind == BookKind.audio ? 'audio' : 'text';
    final indexed = await store.provenChapters(type, book);
    final result = <String>{};
    for (final chapter in chapters) {
      token.check();
      if (!indexed.contains(chapter.id)) continue;
      try {
        if (book.kind == BookKind.audio) {
          final audio = await store.provenAudio(book, chapter);
          if (audio == null) continue;
          final lease = downloadGuard.lease();
          await downloadGuard.validate(audio.evidence, expected: lease);
          final session = await audioFiles.openProven(
            book,
            chapter,
            audio.directory,
            audio.evidence,
          );
          try {
            await downloadGuard.validate(audio.evidence, expected: lease);
            token.check();
          } finally {
            session.close();
          }
        } else {
          final text = await store.provenText(book, chapter);
          if (text == null) continue;
          await downloadGuard.validate(text.evidence);
          if (!policy.textAllowed(text.body)) continue;
        }
        token.check();
        result.add(chapter.id);
      } on RequestCancelled {
        rethrow;
      } on Exception {
        // A stale or damaged proof is not usable; a fresh download can replace
        // the pointer while retaining all previous records and files.
        token.check();
      }
    }
    return result;
  }

  Future<void> removeSavedAudio(Book book, {BookChapter? chapter}) =>
      audioFiles.removeDownloaded(
        book,
        chapter: chapter,
        clearProof: () => store.clearProvenAudio(book, chapter: chapter),
      );

  Future<({OfflineSession session, BookDownloadEvidence? evidence})>
  openOfflineAudio(
    Book book,
    BookChapter chapter,
    CancellationToken token,
  ) async {
    await ensureSourceRiskLoaded();
    token.check();
    requireBook(book, chapter);
    var saved = await store.provenAudio(book, chapter);
    if (saved == null && !await audioFiles.contains(book, chapter)) {
      await download(book, chapter, token);
      saved = await store.provenAudio(book, chapter);
      if (saved == null) throw const FormatException('离线音频来源记录缺失');
    }
    if (saved != null) {
      final evidence = saved.evidence;
      final lease = downloadGuard.lease();
      await downloadGuard.validate(evidence, expected: lease);
      token.check();
      final session = await audioFiles.openProven(
        book,
        chapter,
        saved.directory,
        evidence,
      );
      try {
        await downloadGuard.validate(evidence, expected: lease);
        token.check();
        requireBook(book, chapter);
        requireDownloadEvidence(evidence);
        return (session: session, evidence: evidence);
      } on Object {
        session.close();
        rethrow;
      }
    }
    final session = await audioFiles.open(book, chapter);
    try {
      token.check();
      requireBook(book, chapter);
      return (session: session, evidence: null);
    } on Object {
      session.close();
      rethrow;
    }
  }

  Future<String> readText(
    Book book,
    BookChapter chapter,
    CancellationToken token,
  ) async {
    token.check();
    if (book.sourceId != 'local') await ensureSourceRiskLoaded();
    requireBook(book, chapter);
    if (await _blocked(book.sourceId)) throw const ContentBlocked();
    final saved = await offlineText(book, chapter, token);
    final offline = saved.body;
    var body = offline;
    List<BookChapterSegment>? mixed;
    body ??= await store.readingCache(book, chapter);
    if (body == null) {
      final source = await _active(book);
      body = await client.text(
        source,
        chapter,
        token,
        book: book,
        onSegments: (parts) => mixed = parts,
      );
      if (!sourceAllowed(source)) throw const ContentBlocked();
    }
    token.check();
    if (await _blocked(book.sourceId)) throw const ContentBlocked();
    token.check();
    requireBook(book, chapter);
    requireDownloadEvidence(saved.evidence);
    if (!policy.textAllowed(body)) throw const ContentBlocked();
    if (body.trim().isEmpty) throw const FormatException('章节正文为空');
    if (offline == null) {
      token.check();
      try {
        await store.cacheReading(book, chapter, body);
      } on Exception {
        // Cache storage is best effort; a full or unavailable DB must not block reading.
      }
      token.check();
    }
    if (mixed != null && !policy.supervision.enabled) {
      final parts = mixed!;
      if (parts.whereType<BookTextSegment>().every(
        (part) => policy.textAllowed(part.text),
      )) {
        try {
          await store.cacheMixedReading(book, chapter, parts);
        } on Exception {
          // Mixed layout is optional if storage is unavailable.
        }
      }
    }
    return body;
  }

  Future<List<BookChapterSegment>> mixedReading(
    Book book,
    BookChapter chapter,
    CancellationToken token,
  ) async {
    token.check();
    if (book.sourceId != 'local') await ensureSourceRiskLoaded();
    if (policy.supervision.enabled) return const [];
    requireBook(book, chapter);
    final proven = await store.provenText(book, chapter);
    if (proven != null) {
      await downloadGuard.validate(proven.evidence);
      token.check();
      requireBook(book, chapter);
      if (proven.evidence.origin.sourceId != book.sourceId ||
          !proven.segments.any((part) => part is BookImageSegment)) {
        return const [];
      }
      final source = await _active(book);
      token.check();
      requireDownloadEvidence(proven.evidence);
      for (final part in proven.segments) {
        switch (part) {
          case BookTextSegment text when !policy.textAllowed(text.text):
            throw const ContentBlocked();
          case BookImageSegment image:
            source.requestTarget(image.address, media: true);
          default:
            break;
        }
      }
      return proven.segments;
    }
    final parts = await store.mixedReading(book, chapter);
    if (!parts.any((part) => part is BookImageSegment)) return const [];
    final source = await _active(book);
    token.check();
    if (!sourceAllowed(source) ||
        !bookAllowed(book) ||
        await _blocked(book.sourceId)) {
      throw const ContentBlocked();
    }
    for (final part in parts) {
      switch (part) {
        case BookTextSegment text when !policy.textAllowed(text.text):
          throw const ContentBlocked();
        case BookImageSegment image:
          source.requestTarget(image.address, media: true);
        default:
          break;
      }
    }
    return parts;
  }

  /// A failed chapter can only fall back to an unambiguous same-author edition.
  Future<({String text, Book sourceBook, BookChapter sourceChapter})>
  readWithFallback(
    Book book,
    BookChapter chapter,
    CancellationToken token, {
    bool automatic = true,
  }) async {
    try {
      return (
        text: await readText(book, chapter, token),
        sourceBook: book,
        sourceChapter: chapter,
      );
    } on ContentBlocked {
      rethrow;
    } on Exception {
      token.check();
      requireBook(book, chapter);
      if (!automatic || book.sourceId == 'local') rethrow;
      for (final edition in await alternatives(book, token)) {
        final match = matchingChapter(edition.chapters, chapter);
        if (match == null) continue;
        final String text;
        try {
          text = await readText(edition.book, match, token);
        } on Exception {
          token.check();
          continue;
        }
        if (await _blocked(book.sourceId)) throw const ContentBlocked();
        token.check();
        requireBook(book, chapter);
        return (text: text, sourceBook: edition.book, sourceChapter: match);
      }
      rethrow;
    }
  }

  Future<List<int>> coverBytes(Book book, CancellationToken token) async {
    await ensureSourceRiskLoaded();
    final qidianBook = book.sourceId == qidianRecommendationId;
    final source = qidianBook ? null : await _active(book);
    final uri = qidianBook
        ? qidian.coverUri(book)
        : source!.resolve(book.uri, book.cover, media: true);
    Future<void> validate() async {
      token.check();
      if (!bookAllowed(book) ||
          (qidianBook ? !qidian.allows(book) : !sourceAllowed(source!)) ||
          await _blocked(book.sourceId)) {
        throw const ContentBlocked();
      }
      token.check();
    }

    await validate();
    final key = coverCache.key(book.title, book.author, uri);
    final generation = coverCache.generation;
    List<int>? cached;
    try {
      cached = await coverCache.read(key);
    } on FileSystemException {
      // Optional cache failure must not hide a valid cover.
    }
    await validate();
    if (cached != null) return cached;
    final bytes = qidianBook
        ? await qidian.cover(book, token)
        : (await client.fetch(
            source!,
            uri,
            token,
            media: true,
            maxBytes: 2 * 1024 * 1024,
          )).bytes;
    token.check();
    await validate();
    if (isPosterPayload(bytes)) {
      unawaited(
        coverCache
            .write(key, bytes, generation)
            .onError((Object _, StackTrace _) {}),
      );
    }
    token.check();
    return bytes;
  }

  Future<List<Uri>> chapterImages(
    Book book,
    BookChapter chapter,
    CancellationToken token,
  ) async {
    await ensureSourceRiskLoaded();
    if (policy.supervision.enabled) throw const ContentBlocked();
    requireBook(book, chapter);
    final offline = await store.offlineImageAddresses(book, chapter);
    if (offline != null) {
      token.check();
      if (policy.supervision.enabled ||
          !bookAllowed(book) ||
          await _blocked(book.sourceId)) {
        throw const ContentBlocked();
      }
      return offline;
    }
    final source = await _active(book);
    final images = await client.chapterImages(
      source,
      chapter,
      token,
      book: book,
    );
    token.check();
    if (policy.supervision.enabled ||
        !sourceAllowed(source) ||
        !bookAllowed(book) ||
        await _blocked(book.sourceId)) {
      throw const ContentBlocked();
    }
    token.check();
    return images;
  }

  Future<List<Uri>> imageAddressesInText(
    Book book,
    BookChapter chapter,
    String body,
    CancellationToken token,
  ) async {
    await ensureSourceRiskLoaded();
    requireBook(book, chapter);
    final source = await _active(book);
    final images = parseBookImageAddresses(source, chapter.uri, body);
    token.check();
    if ((policy.supervision.enabled && images.isNotEmpty) ||
        !sourceAllowed(source) ||
        !bookAllowed(book) ||
        await _blocked(book.sourceId)) {
      throw const ContentBlocked();
    }
    return images;
  }

  Future<List<int>> chapterImageBytes(
    Book book,
    Uri image,
    CancellationToken token, {
    BookChapter? chapter,
  }) async {
    await ensureSourceRiskLoaded();
    if (policy.supervision.enabled || !bookAllowed(book)) {
      throw const ContentBlocked();
    }
    final offlineBytes = chapter == null
        ? null
        : await store.offlineImageBytes(book, chapter, image);
    if (offlineBytes != null) {
      token.check();
      if (policy.supervision.enabled ||
          !bookAllowed(book) ||
          await _blocked(book.sourceId)) {
        throw const ContentBlocked();
      }
      return readableBookImageBytes(image, offlineBytes);
    }
    final source = await _active(book);
    final uri = source.requestTarget(image, media: true);
    final cached = await store.readingImage(book, uri);
    final document = cached == null
        ? await client.fetch(
            source,
            uri,
            token,
            media: true,
            maxBytes: 4 * 1024 * 1024,
          )
        : null;
    token.check();
    if (policy.supervision.enabled ||
        !sourceAllowed(source) ||
        !bookAllowed(book) ||
        await _blocked(book.sourceId)) {
      throw const ContentBlocked();
    }
    if (document != null &&
        document.contentType?.toLowerCase().startsWith('image/') != true) {
      throw const FormatException('章节图片地址未返回图片');
    }
    final bytes = cached == null
        ? readableBookImageBytes(uri, document!.bytes)
        : readableBookImageBytes(uri, cached);
    if (document != null) {
      try {
        await store.cacheReadingImage(book, uri, bytes);
      } on Exception {
        // Reading continues if the optional image cache is unavailable.
      }
    }
    token.check();
    if (policy.supervision.enabled ||
        !sourceAllowed(source) ||
        !bookAllowed(book) ||
        await _blocked(book.sourceId)) {
      throw const ContentBlocked();
    }
    return bytes;
  }

  Future<void> download(
    Book book,
    BookChapter chapter,
    CancellationToken token, {
    List<BookEdition> alternatives = const [],
    bool tryOriginal = true,
  }) async {
    await ensureSourceRiskLoaded();
    if (book.kind == BookKind.comic) {
      await _downloadComic(book, chapter, token);
      return;
    }
    requireBook(book, chapter);
    if (await _blocked(book.sourceId)) throw const ContentBlocked();
    final candidates = [if (tryOriginal) (book, chapter)];
    for (final edition in alternatives) {
      final match = matchingChapter(edition.chapters, chapter);
      if (match != null) candidates.add((edition.book, match));
    }
    Object? last;
    for (final (candidate, part) in candidates) {
      token.check();
      try {
        final evidence = await downloadGuard.capture(
          book,
          chapter,
          candidate,
          part,
        );
        final lease = downloadGuard.lease();
        final source = await _active(candidate);
        void authorize() {
          token.check();
          if (lease != downloadGuard.lease()) throw const ContentBlocked();
          requireBook(book, chapter);
          requireBook(candidate, part);
          requireDownloadEvidence(evidence);
        }

        Future<void> validate() async {
          authorize();
          await downloadGuard.validate(evidence, expected: lease);
          authorize();
        }

        await validate();
        if (book.kind == BookKind.text) {
          // Legacy caches have no origin. Fetch fresh bytes so an old C→B
          // fallback cannot be relabelled as a verified B→A download.
          final freshChapter = BookChapter(
            part.title,
            part.uri,
            request: part.request,
          );
          List<BookChapterSegment>? mixed;
          final body = downloadText == null
              ? await client.text(
                  source,
                  freshChapter,
                  token,
                  book: candidate,
                  onSegments: (segments) => mixed = segments,
                )
              : await downloadText!(source, candidate, freshChapter, token);
          await validate();
          if (!policy.textAllowed(body)) throw const ContentBlocked();
          if (body.trim().isEmpty) throw const FormatException('章节正文为空');
          final segments =
              candidate.sourceId == book.sourceId &&
                  mixed != null &&
                  mixed!.whereType<BookTextSegment>().every(
                    (part) => policy.textAllowed(part.text),
                  ) &&
                  jsonEncode([
                        for (final part in mixed!)
                          switch (part) {
                            BookTextSegment text => {'text': text.text},
                            BookImageSegment image => {
                              'image': image.address.toString(),
                            },
                          },
                      ]).length <=
                      512 * 1024
              ? mixed!
              : const <BookChapterSegment>[];
          await store.saveProvenText(book, chapter, body, evidence, () async {
            await validate();
            if (!policy.textAllowed(body) ||
                !segments.whereType<BookTextSegment>().every(
                  (part) => policy.textAllowed(part.text),
                )) {
              throw const ContentBlocked();
            }
          }, segments: segments);
        } else {
          await audioFiles.download(
            source,
            book,
            part,
            token,
            authorize,
            targetChapter: chapter,
            originBook: candidate,
            evidence: evidence,
            publish: (directory) => store.saveProvenAudio(
              book,
              chapter,
              directory,
              evidence,
              validate,
            ),
          );
        }
        return;
      } on ContentBlocked {
        rethrow;
      } on Exception catch (error) {
        last = error;
      }
    }
    token.check();
    throw last ?? const FormatException('没有可用章节');
  }

  Future<Book> importLocal(File file) async {
    final name = p.basename(file.path);
    final extension = p.extension(name).toLowerCase();
    if (!{'.txt', '.epub', '.pdf'}.contains(extension)) {
      throw const FormatException('仅支持 TXT、EPUB 和 PDF');
    }
    if (policy.supervision.enabled || !kindAllowed(BookKind.text)) {
      throw const ContentBlocked();
    }
    final bytes = await readLocalBookBytes(file);
    final parsed = switch (extension) {
      '.epub' => await parseEpubBookOffThread(name, bytes),
      '.pdf' => await parsePdfBook(name, bytes),
      _ => await parseTextBookOffThread(name, bytes),
    };
    if (parsed.sections.isEmpty || parsed.sections.length > 4000) {
      throw const FormatException('电子书正文为空或章节过多');
    }
    final book = Book(
      'local',
      BookKind.text,
      parsed.title,
      parsed.author,
      Uri(scheme: 'book', path: sha256.convert(bytes).toString()),
    );
    void authorize() {
      if (!bookAllowed(book) ||
          parsed.sections.any(
            (section) =>
                !policy.textAllowed(section.title) ||
                !policy.textAllowed(section.text),
          )) {
        throw const ContentBlocked();
      }
    }

    authorize();
    final contents = {
      for (final (index, section) in parsed.sections.indexed)
        BookChapter(section.title, book.uri.replace(fragment: '$index')):
            section.text,
    };
    await _saveLocalImport(
      book,
      contents,
      authorize,
      file: extension == '.txt'
          ? null
          : documentFile(book, extension.substring(1)),
      bytes: bytes,
    );
    return book;
  }

  Future<void> _saveLocalImport(
    Book book,
    Map<BookChapter, String> contents,
    void Function() authorize, {
    required File? file,
    required List<int> bytes,
  }) async {
    Directory? staging;
    try {
      if (file != null) {
        await documents.create(recursive: true);
        staging = await documents.createTemp('.pending-');
        await File(
          p.join(staging.path, 'document'),
        ).writeAsBytes(bytes, flush: true);
      }
      await store.db.atomic(() async {
        authorize();
        await store.saveTexts(book, contents);
        await store.saveBook(
          book,
          chapters: contents.keys.toList(),
          favorite: true,
        );
        if (file != null) {
          await File(p.join(staging!.path, 'document')).rename(file.path);
        }
      }, tables: {'app_meta'});
    } finally {
      if (staging != null) {
        try {
          final pending = File(p.join(staging.path, 'document'));
          if (await pending.exists()) await pending.delete();
          await staging.delete();
        } on FileSystemException {
          // A failed cleanup must not mask the outcome of the import.
        }
      }
    }
  }

  Future<void> removeLocalBook(Book book) => store.db.atomic(() async {
    await store.removeLocal(book);
    for (final extension in ['epub', 'pdf']) {
      final file = documentFile(book, extension);
      if (await file.exists()) await file.delete();
    }
  }, tables: {'app_meta'});

  Future<void> close() {
    final running = _closing;
    if (running != null) return running;
    _evidenceClosing = true;
    final done = Completer<void>();
    _closing = done.future;
    unawaited(
      _close().then<void>(
        (_) => done.complete(),
        onError: (Object error, StackTrace stack) =>
            done.completeError(error, stack),
      ),
    );
    return done.future;
  }

  Future<void> _close() async {
    _sourceRiskChanges.value++;
    await Future.wait(
      _pendingEvidenceMutations.map((done) => done.future).toList(),
    );
    policy.removeListener(_coverPolicyChanged);
    _downloadGuard?.dispose();
    _sourceRiskChanges.dispose();
    _http.close();
    await audioFiles.close();
    await coverCache.waitForIdle();
  }
}
