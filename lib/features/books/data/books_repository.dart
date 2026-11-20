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
import '../../../core/network/header_policy.dart';
import '../../../core/network/media_http_client.dart';
import '../../../core/network/poster_repository.dart';
import '../../../core/network/source_certificate.dart';
import '../../../core/persistence/app_database.dart';
import '../../../media/gateway/offline_server.dart';
import '../../supervision/application/content_policy.dart';
import '../../supervision/domain/adult_source_evidence.dart';
import '../../supervision/domain/supervision_rules.dart';
import '../application/book_category_policy.dart';
import '../domain/book.dart';
import '../domain/book_search.dart';
import '../domain/book_source_risk.dart';
import '../domain/legado_source.dart';
import 'aoaostar_book_catalog.dart';
import 'audiobook_files.dart';
import 'book_client.dart';
import 'book_chapter_policy.dart';
import 'book_reading_cleanup.dart';
import 'reader_fonts.dart';
import 'book_comic_access.dart';
import 'book_cover_cache.dart';
import 'book_download_evidence.dart';
import 'book_download_guard.dart';
import 'book_download_source_health.dart';
import 'book_latest_aggregation.dart';
import 'book_discovery_paging.dart';
import 'book_import.dart';
import 'book_builtin_domain_updates.dart';
import 'book_image_payload.dart';
import 'book_resource_limits.dart';
import 'book_mixed_content.dart';
import 'book_policy_evidence.dart';
import 'book_policy_tracker.dart';
import 'book_request_guard.dart';
import 'book_site_check.dart';
import 'book_site_inspection.dart';
import 'book_site_revision.dart';
import 'book_source_risk_store.dart';
import 'book_source_access.dart';
import 'book_source_editor.dart';
import 'book_source_links.dart';
import 'book_source_import_plan.dart';
import 'book_source_importer.dart';
import 'book_store.dart';
import 'book_catalog_window.dart';
import 'local_book_library.dart';
import 'qidian_catalog.dart';
import 'ximalaya_audio_client.dart';

export 'book_source_import_plan.dart' show BookImportChanges;

part 'book_comic_download.dart';
part 'book_chapter_download.dart';
part 'book_repository_discovery.dart';
part 'book_repository_certificates.dart';
part 'book_repository_builtin_catalog.dart';
part 'book_repository_editions.dart';
part 'book_repository_mutations.dart';
part 'book_repository_media_access.dart';
part 'book_repository_policy_review.dart';
part 'book_repository_request_policy.dart';
part 'book_repository_probe.dart';
part 'book_repository_site_checks.dart';
part 'book_repository_site_lease.dart';
part 'book_repository_shutdown.dart';
part 'book_site_observed_sources.dart';
part 'book_supervised_site_scan.dart';

typedef BookEdition = ({Book book, List<BookChapter> chapters});
typedef VerifiedBookEdition = ({
  BookEdition edition,
  bool Function() isCurrent,
});
typedef BookEditionUpdate = ({
  BookSourceEntry? source,
  BookEdition? edition,
  int completed,
  int total,
  int eligible,
  bool failed,
});
typedef BookSearchUpdate = ({
  String? sourceId,
  List<Book> books,
  int completed,
  int total,
  bool failed,
  bool certificateFailed,
  int? latencyMs,
});

final class BooksRepository {
  BooksRepository(
    AppDatabase db,
    Directory root,
    OfflineServer offline,
    this.policy,
    Future<void> Function(File, CancellationToken, String) validateAudio, {
    int coverCacheMiB = 32,
    this.allowAggregateCertificateExceptions,
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
    _localLibrary = LocalBookLibrary(
      store: store,
      documents: Directory(p.join(root.path, 'book_documents')),
      policy: policy,
      bookAllowed: bookAllowed,
    );
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
    _discoveryPolicySnapshot = bookSitePolicySnapshot(policy);
    policy.addListener(_discoveryPolicyChanged);
    _bookPolicy = BookPolicyTracker(
      policy: policy,
      store: _bookPolicyEvidenceStore,
    );
    _sourceRiskChanges.addListener(_discoveryRiskChanged);
  }

  late final LocalBookLibrary _localLibrary;
  Directory get documents => _localLibrary.documents;
  Future<String> localDocumentFormat(Book book) =>
      _localLibrary.documentFormat(book);
  File documentFile(Book book, String extension) =>
      _localLibrary.documentFile(book, extension);
  final BookStore store;
  final BookSourceRiskStore riskStore;
  late final _sourceEditor = BookSourceEditor(
    store: store,
    risks: riskStore,
    policy: policy,
    sourceAllowed: sourceAllowed,
    comicAllowed: comicAccess.allowed,
  );
  final _sourceRiskChanges = ValueNotifier<int>(0);
  late final _allRiskChanges = Listenable.merge([
    _sourceRiskChanges,
    _bookPolicy.changes,
  ]);
  final _discoveryTokens = <CancellationToken>{};
  final _discoveryCursors = <String, _DiscoveryCursor>{};
  late String _discoveryPolicySnapshot;
  int _discoveryRevision = 0;
  Listenable get sourceRiskChanges => _allRiskChanges;
  Listenable get sourceConfigurationChanges => _sourceRiskChanges;
  Listenable get bookPolicyChanges => _bookPolicy.changes;
  Listenable get bookObservationChanges => _bookPolicy.observationChanges;
  bool get sourceRisksReady => _sourceAccess.ready;
  bool get sourceRisksSuspended => _sourceAccess.suspended;
  bool get sourceRiskMutationPending =>
      _evidenceMutations > 0 || _evidenceClosing;
  bool get closing => _evidenceClosing;
  int get sourceConfigurationRevision => _sourceConfigurationRevision;
  bool get sourceConfigurationChanging => _sourceConfigurationMutations != 0;
  final BookCoverCache coverCache;
  final ContentPolicy policy;
  late final chapterPolicy = BookChapterPolicy(store, policy);
  late final readingCleanup = BookReadingCleanup(store);
  late final readerFonts = ReaderFontStore(
    Directory(p.join(documents.parent.path, 'reader_fonts')),
    client.network,
  );
  late final comicAccess = BookComicAccess(store, policy);
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
  final bool Function()? allowAggregateCertificateExceptions;
  late final client = BookClient(
    DocumentClient(_http, sourceCertificates: true),
  );
  late final qidian = QidianCatalog(DocumentClient(_http), policy, store.db);
  late final AudiobookFiles audioFiles;
  late final Future<List<BookSource>> _builtins = _loadBuiltins();
  Future<void>? _siteObservation;
  int _siteObservationRestoreRevision = 0;
  @visibleForTesting
  Future<void> Function()? beforeSiteObservationTransactionForTesting;
  @visibleForTesting
  Future<void> Function()? afterSiteObservationWriteForTesting;
  final _verifiedSources = <String, BookSource>{};
  late final _sourceAccess = BookSourceAccess(policy);
  final _contentEpochs = <String, int>{};
  late final _bookPolicyEvidenceStore = BookPolicyEvidenceStore(store.db);
  late final BookPolicyTracker _bookPolicy;
  Future<void>? _riskLoading;
  @visibleForTesting
  Future<void> Function()? beforeSourceRiskPublishForTesting;
  int _sourceConfigurationRevision = 0, _sourceConfigurationMutations = 0;
  final _refreshingSubscriptions = <String>{};
  Future<void>? _seeding;
  int _evidenceMutations = 0;
  bool _evidenceClosing = false;
  Future<void>? _closing;
  final _pendingEvidenceMutations = <Completer<void>>{};
  _SiteScanLease? _siteScanLease;
  final _supervisedScans = <CancellationToken>{};
  final _supervisedScanDone = <Completer<void>>{};
  @visibleForTesting
  Future<void> Function()? beforeEvidenceMutationForTesting;
  @visibleForTesting
  Future<void> Function()? afterSiteRiskWriteForTesting;
  @visibleForTesting
  Future<void> Function()? afterSiteRiskCommitForTesting;
  @visibleForTesting
  Future<void> Function()? afterBookPolicyCommitForTesting;
  @visibleForTesting
  Future<void> Function()? beforeBookPolicyReviewWriteForTesting;
  @visibleForTesting
  Future<void> Function()? afterBookPolicyReviewWriteForTesting;
  @visibleForTesting
  Future<void> Function()? afterBookPolicyReviewCommitForTesting;
  @visibleForTesting
  Future<void> Function()? beforeBookPolicyReviewRegistrationForTesting;
  @visibleForTesting
  void Function()? afterBookPolicyReviewRegistrationForTesting;
  @visibleForTesting
  int pendingBookPolicyObservationsForTesting(String id) =>
      _bookPolicy.pendingCount(id);

  BookDownloadGuard? _downloadGuard;
  BookDownloadGuard get downloadGuard => _downloadGuard ??= BookDownloadGuard(
    store: store,
    risks: riskStore,
    policy: policy,
    sourceEntry: _sourceAccess.entry,
    verified: _verifiedSources,
    epochs: _contentEpochs,
    ready: () =>
        sourceRisksReady && !_evidenceClosing && _evidenceMutations == 0,
    bookAllowed: bookAllowed,
    entryAllowed: sourceEntryAllowed,
    generation: () => _sourceAccess.generation,
    bookPolicyGeneration: () => _bookPolicy.generation,
    ensureReady: ensureSourceRiskLoaded,
  );

  Future<void> ensureCatalog() async {
    if (closing || policy.supervision.enabled || policy.supervision.corrupted) {
      return;
    }
    final running = _seeding ??= _seedCatalog();
    try {
      await running;
    } finally {
      if (identical(_seeding, running)) _seeding = null;
    }
  }

  /// Load source metadata before exposing saved works or offline chapters.
  /// Source assessments are separate records and survive removal of a source.
  Future<void> ensureSourceRiskLoaded() async {
    if (!comicAccess.loaded) await comicAccess.load();
    if (_sourceAccess.suspended) throw const ContentBlocked();
    if (_sourceAccess.loaded) return;
    final pending = _riskLoading ??= refreshSourceRisks();
    try {
      await pending;
    } finally {
      if (identical(_riskLoading, pending)) _riskLoading = null;
    }
  }

  Future<void> refreshSourceRisks() async {
    final generation = _sourceAccess.beginReload();
    final entries = await store.sources(await _builtins);
    await store.observeTrackedSources(entries);
    final assessments = await riskStore.all();
    final contentEpochs = await store.contentEpochs();
    final blocked = await store.blockedSources();
    final bookEvidence = await _bookPolicyEvidenceStore.load();
    final beforePublish = beforeSourceRiskPublishForTesting;
    if (beforePublish != null) await beforePublish();
    // Source findings and reviewed work evidence share this reload barrier.
    if (!_sourceAccess.publish(
      generation: generation,
      entries: entries,
      assessments: assessments,
      blocked: blocked.keys,
    )) {
      return refreshSourceRisks();
    }
    _contentEpochs
      ..clear()
      ..addAll(contentEpochs);
    _bookPolicy.mergeLoaded(bookEvidence);
  }

  void suspendSourceRisks() {
    _sourceConfigurationRevision++;
    _siteObservationRestoreRevision++;
    _siteObservation = null;
    _sourceAccess.suspend();
    _sourceRiskChanges.value++;
  }

  Future<void> resumeSourceRisks() async {
    _sourceAccess.resume();
    try {
      await refreshSourceRisks();
    } finally {
      _sourceRiskChanges.value++;
      if (!_evidenceClosing) {
        unawaited(
          ensureSiteObservations().catchError((Object error, StackTrace _) {
            if (error is! RequestCancelled) {
              debugPrint('书源抽查版本初始化未完成: ${error.runtimeType}');
            }
          }),
        );
      }
    }
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
      assessment = await riskStore.addEvidence(
        source,
        adult: adult,
        quarantine: quarantine,
        rootPageEvidence: true,
      );
      _requireSubscriptionAccess();
    }, tables: {'app_meta'});
    _sourceAccess.rememberAssessment(assessment);
    policy.refresh();
  }

  /// Risk review is separate from ordinary source lists, which hide the source.
  /// Content policy also applies to the review list itself.
  Future<List<BookSourceRiskEntry>> sourceRiskEntries() async {
    _requireSubscriptionAccess();
    await ensureSourceRiskLoaded();
    final result = _sourceAccess.riskEntries();
    _requireSubscriptionAccess();
    return result;
  }

  /// Revalidate a displayed review against current evidence and policy.
  bool sourceRiskEntryAllowed(BookSourceRiskEntry entry) =>
      _sourceAccess.riskEntryAllowed(entry);

  /// Explicit manual review is required. A stale review cannot clear a newer
  /// finding, and a bundled fixed quarantine cannot be cleared here.
  Future<void> clearSourceRisk(BookSourceRiskEntry entry) async {
    _requireSubscriptionAccess();
    // A review invalidates every older homepage sample, including results
    // shared by several source IDs for the same host.
    await _withEvidenceMutation(
      () => _clearSourceRisk(entry),
      sourceConfiguration: true,
    );
  }

  bool kindAllowed(BookKind kind) => _sourceAccess.kindAllowed(kind);
  bool sourceAllowed(BookSource source) => _sourceAccess.sourceAllowed(source);

  /// Evaluate both source metadata and the user's stored group at display time.
  bool sourceEntryAllowed(BookSourceEntry entry) =>
      _sourceAccess.entryAllowed(entry);

  bool bookAllowed(Book book) {
    if (!_sourceAccess.loaded && book.sourceId != 'local') return false;
    final verified = _verifiedSources[book.sourceId];
    final sourceEntry = _sourceAccess.entry(book.sourceId);
    final ruleSource = sourceEntry?.source ?? verified;
    final restrictedBookAddress =
        policy.filterAdult &&
        ruleSource != null &&
        bookDiscoveryStaticBookDenied(
          ruleSource,
          book,
          [
            ...?ruleSource.legado?.categories,
            ...ruleSource.discoveryCategories,
          ].where((category) => !bookCategoryAllowed(policy, category)),
        );
    return kindAllowed(book.kind) &&
        (book.kind != BookKind.comic ||
            book.sourceId == 'local' ||
            (sourceEntry != null && comicAccess.allowed(sourceEntry.source))) &&
        !restrictedBookAddress &&
        !_sourceAccess.blocked(book.sourceId) &&
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
        !_sourceAccess.assessedQuarantined(book.sourceId, book.uri.host) &&
        (sourceEntry == null || sourceEntryAllowed(sourceEntry)) &&
        (book.kind != BookKind.text ||
            !BookSourceAccess.retiredNewsHost(book.uri.host)) &&
        (!policy.supervision.enabled ||
            (verified != null && sourceAllowed(verified))) &&
        !(policy.filterAdult &&
            (knownAdultHost(book.uri.host) ||
                adultBookHost(book.uri.host) ||
                adultBundledSourceId(book.sourceId) ||
                _sourceAccess.assessedAdult(book.sourceId, book.uri.host))) &&
        _bookPolicy.allows(book);
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
              (!enabledOnly || comicAccess.allowed(entry.source)) &&
              sourceEntryAllowed(entry),
        )
        .map(
          (entry) => comicAccess.allowed(entry.source)
              ? entry
              : BookSourceEntry(
                  entry.source,
                  false,
                  entry.favorite,
                  entry.group,
                  entry.health,
                  entry.checkedAt,
                  subscriptionId: entry.subscriptionId,
                  fromCatalog: entry.fromCatalog,
                ),
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
        !sourceEntryAllowed(entry)) {
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
    if (!comicAccess.allowed(entry.source)) {
      throw const ContentBlocked('漫画渠道未通过监管授权，仅新人漫画可直接启用');
    }
    if (!sourceEntryAllowed(entry)) {
      throw const ContentBlocked();
    }
    return entry.source;
  }

  Future<List<LegadoCategory>> categories(
    BookKind kind,
    String sourceId,
    CancellationToken token, {
    SourceCertificateFailure? temporaryCertificate,
  }) => _certificateRequest(
    sourceId,
    temporaryCertificate,
    () => _discoveryCategories(kind, sourceId, token),
  );

  Future<BookDiscoveryPage> discover(
    BookKind kind,
    String sourceId,
    CancellationToken token, {
    LegadoCategory? category,
    int page = 1,
    String? cursor,
    SourceCertificateFailure? temporaryCertificate,
  }) => _certificateRequest(
    sourceId,
    temporaryCertificate,
    () => _discoverPage(
      kind,
      sourceId,
      token,
      category: category,
      page: page,
      cursor: cursor,
    ),
  );

  Future<void> restoreDefaultSources(BookKind kind) => _withEvidenceMutation(
    () => _restoreDefaultSources(kind),
    sourceConfiguration: true,
  );

  Future<void> _restoreDefaultSources(BookKind kind) async {
    policy.supervision.require(SensitiveOperation.channels);
    await ensureSourceRiskLoaded();
    await _sourceEditor.restoreDefaults(kind, await _builtins);
    await _refreshChangedSources();
  }

  Future<void> saveSource(BookSource source, Map<String, Object?> updates) =>
      BookSourceEditor.changesConfiguration(updates)
      ? _withEvidenceMutation(
          () => _saveSource(source, updates),
          sourceConfiguration: true,
        )
      : _saveSource(source, updates);

  Future<void> _saveSource(
    BookSource source,
    Map<String, Object?> updates, {
    void Function()? validate,
  }) async {
    validate?.call();
    policy.supervision.require(SensitiveOperation.channels);
    await ensureSourceRiskLoaded();
    final retainedEvidence = await _sourceEditor.save(
      source,
      updates,
      builtin: _verifiedSources[source.id],
      validate: validate,
    );
    if (retainedEvidence != null) {
      _sourceAccess.rememberAssessment(retainedEvidence);
    }
    if (BookSourceEditor.changesConfiguration(updates)) {
      await _refreshChangedSources();
      if (updates.containsKey('group') || updates.containsKey('source')) {
        policy.refresh();
      }
    }
  }

  Future<void> setSourcesEnabled(
    BookKind kind,
    Set<String> ids,
    bool enabled,
  ) => _withEvidenceMutation(
    () => _setSourcesEnabled(kind, ids, enabled),
    sourceConfiguration: true,
  );

  Future<void> _setSourcesEnabled(
    BookKind kind,
    Set<String> ids,
    bool enabled,
  ) async {
    final changed = await _sourceEditor.setEnabled(
      () => sources(kind),
      ids,
      enabled,
    );
    if (changed) await _refreshChangedSources();
  }

  Future<void> authorizeAndEnableComics(List<BookSource> selection) =>
      _authorizeAndEnableComics(selection);

  Future<void> blockSource(BookSource source) => _withEvidenceMutation(
    () => _blockSource(source),
    sourceConfiguration: true,
  );

  Future<void> _blockSource(BookSource source) async {
    await ensureSourceRiskLoaded();
    await _sourceEditor.block(source);
    // Publish the committed restriction before rebuilding the full snapshot,
    // so an active offline player pauses as soon as the blacklist changes.
    _sourceAccess.block(source.id);
    policy.refresh();
    await refreshSourceRisks();
    policy.refresh();
  }

  Future<bool> _blocked(String id) async =>
      (await store.blockedSources()).containsKey(id);

  Future<void> unblockSource(String id) => _withEvidenceMutation(
    () => _unblockSource(id),
    sourceConfiguration: true,
  );

  Future<void> _unblockSource(String id) async {
    await _sourceEditor.unblock(id);
    _sourceAccess.invalidate();
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
    sourceConfiguration: true,
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
    final result =
        await BookSourceImporter(
          store: store,
          policy: policy,
          sourceAllowed: sourceAllowed,
          adultAssessed: _sourceAccess.adultAssessed,
          assessAdult: (source) => riskStore.addEvidence(
            source,
            adult: true,
            quarantine: false,
            rootPageEvidence: false,
          ),
        ).importSources(
          incoming,
          builtins: await _builtins,
          subscription: subscription,
          token: token,
          fromCatalog: fromCatalog,
          catalogRevision: catalogRevision,
          catalogAdultFilter: catalogAdultFilter,
        );
    for (final assessment in result.assessments) {
      _sourceAccess.rememberAssessment(assessment);
    }
    final changes = result.changes;
    if (changes.added > 0 || changes.updated > 0) {
      _sourceAccess.invalidate(unload: true);
      _sourceRiskChanges.value++;
      await refreshSourceRisks();
      _sourceRiskChanges.value++;
      policy.refresh();
    }
    if (result.assessments.isNotEmpty || result.recoveredQuarantine) {
      policy.refresh();
    }
    return changes;
  }

  Future<void> removeSource(BookSource source) => _withEvidenceMutation(
    () => _removeSource(source),
    sourceConfiguration: true,
  );

  Future<void> _removeSource(BookSource source) async {
    policy.supervision.require(SensitiveOperation.channels);
    await ensureSourceRiskLoaded();
    final retainedEvidence = await _sourceEditor.remove(
      source,
      builtin: _verifiedSources[source.id],
    );
    if (retainedEvidence != null) {
      _sourceAccess.rememberAssessment(retainedEvidence);
    }
    await _refreshChangedSources();
    policy.refresh();
  }

  Future<void> probe(
    BookSource source,
    String query,
    CancellationToken cancellation,
  ) => _probe(source, query, cancellation);

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
  }) => _find(
    kind,
    query,
    token,
    sourceId: sourceId,
    category: category,
    page: page,
    maxSources: maxSources,
    sourceIds: sourceIds,
    preferredSource: preferredSource,
    excludedSource: excludedSource,
    skipQidian: skipQidian,
    favorites: favorites,
    field: field,
    availableSources: availableSources,
    onProgress: onProgress,
  );

  Future<List<BookChapter>> chapters(
    Book book,
    CancellationToken token, {
    bool refresh = false,
    bool persistCatalog = true,
  }) async {
    token.check();
    if (book.sourceId != 'local') await ensureSourceRiskLoaded();
    if (!bookAllowed(book) || await _blocked(book.sourceId)) {
      throw const ContentBlocked();
    }
    token.check();
    final saved = await store.entry(book) ?? await store.detachedEntry(book);
    token.check();
    if (!bookAllowed(book) || await _blocked(book.sourceId)) {
      throw const ContentBlocked();
    }
    token.check();
    final catalogRevision = _catalogReparseRevision(book, saved);
    if (saved != null &&
        saved.chapters.isNotEmpty &&
        !refresh &&
        catalogRevision == null) {
      return saved.chapters
          .where(
            (c) =>
                policy.textAllowed(c.title) && _chapterTargetAllowed(book, c),
          )
          .toList();
    }
    final source = await _active(book);
    final fresh = await _guardedBookChapters(source, book, token);
    token.check();
    if (persistCatalog && fresh.isNotEmpty && catalogRevision != null) {
      await store.updateShelfChapters(
        book,
        fresh,
        catalogRevision: catalogRevision,
      );
    }
    token.check();
    return fresh;
  }

  Future<Book> details(Book book, CancellationToken token) async {
    token.check();
    final observation = book.sourceId == 'local'
        ? null
        : _bookPolicy.startObservation(book.id);
    try {
      if (book.sourceId != 'local') await ensureSourceRiskLoaded();
      if (!bookAllowed(book)) throw const ContentBlocked();
      if (book.sourceId == 'local') return book;
      final source = await _active(book);
      observation!.check();
      return await _guardedBookDetails(source, book, token, observation);
    } finally {
      observation?.close();
    }
  }

  Future<void> checkFollowing(BookKind kind, CancellationToken token) =>
      _checkFollowing(kind, token);

  /// Refreshes only the books currently shown on this shelf, including books
  /// that have not been marked as followed.
  Future<void> checkShelfUpdates(
    Iterable<BookShelfEntry> entries,
    CancellationToken token,
  ) async {
    token.check();
    await ensureSourceRiskLoaded();
    BookCatalogCapacityExceeded? capacityError;
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
      } on BookCatalogCapacityExceeded catch (error) {
        capacityError = error;
      } on Exception {
        token.check();
      }
    }
    if (capacityError != null) throw capacityError;
  }

  Future<List<BookEdition>> alternatives(
    Book book,
    CancellationToken token, {
    bool refresh = false,
    bool includeCurrent = false,
    void Function(BookEditionUpdate)? onProgress,
    Duration? timeLimit,
    void Function()? onTimeLimit,
    int? maxSources,
    void Function(VerifiedBookEdition)? onVerified,
  }) => _inspectEditions(
    book,
    token,
    refresh: refresh,
    includeCurrent: includeCurrent,
    onProgress: onProgress,
    timeLimit: timeLimit,
    onTimeLimit: onTimeLimit,
    maxSources: maxSources,
    onVerified: onVerified,
  );

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
    if (!bookAllowed(book)) {
      throw const ContentBlocked('作品或来源被内容策略限制，可能涉及来源隔离、作品标记或监管规则；章节未读取');
    }
    if (!policy.textAllowed(chapter.title)) {
      throw const ContentBlocked('章节标题触发成人过滤或监管关键词规则；标题及命中词未公开');
    }
    if (!_chapterTargetAllowed(book, chapter)) {
      throw const ContentBlocked('章节地址未通过来源及网络访问策略检查');
    }
  }

  void requireDownloadEvidence(BookDownloadEvidence? evidence) {
    if (evidence != null && !downloadGuard.allowed(evidence)) {
      throw const ContentBlocked();
    }
  }

  /// Unlabelled legacy files are readable but are not download evidence.
  Future<({String? body, BookDownloadEvidence? evidence})> offlineText(
    Book book,
    BookChapter chapter,
    CancellationToken token,
  ) async {
    token.check();
    await chapterPolicy.load();
    if (book.sourceId != 'local') await ensureSourceRiskLoaded();
    requireBook(book, chapter);
    final proven = await store.provenText(book, chapter);
    if (proven != null) {
      await downloadGuard.validate(proven.evidence);
      token.check();
      requireBook(book, chapter);
      chapterPolicy.prepare(book, chapter, proven.body);
      requireDownloadEvidence(proven.evidence);
      return (body: proven.body, evidence: proven.evidence);
    }
    final body = await store.text(book, chapter);
    token.check();
    requireBook(book, chapter);
    if (body != null) chapterPolicy.prepare(book, chapter, body);
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
    if (book.kind == BookKind.comic) {
      return _reusableComicDownloads(book, chapters, token);
    }
    await chapterPolicy.load();
    final type = book.kind == BookKind.audio ? 'audio' : 'text';
    final indexed = await store.provenChapters(type, book);
    final pending = chapters
        .where((chapter) => indexed.contains(chapter.id))
        .toList();
    final result = <String>{};
    // Proofs are independent per chapter, so validating a few at a time keeps
    // the pre-scan off the critical path for long catalogs.
    var cursor = 0;
    Future<void> scan() async {
      while (cursor < pending.length) {
        final chapter = pending[cursor++];
        token.check();
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
            chapterPolicy.prepare(book, chapter, text.body);
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
    }

    await Future.wait(
      List.generate(math.max(1, math.min(8, pending.length)), (_) => scan()),
    );
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
    if (BookLatestAggregation.isAggregated(chapter)) {
      return _readAggregatedText(book, chapter, token);
    }
    final saved = await offlineText(book, chapter, token);
    final offline = saved.body;
    var body = offline;
    List<BookChapterSegment>? mixed;
    body ??= await store.readingCache(book, chapter);
    final fetched = body == null;
    Future<String> finish(String text, CancellationToken active) async {
      void validate() {
        active.check();
        requireBook(book, chapter);
        requireDownloadEvidence(saved.evidence);
        chapterPolicy.prepare(book, chapter, text);
      }

      validate();
      if (await _blocked(book.sourceId)) throw const ContentBlocked();
      validate();
      if (text.trim().isEmpty) throw const FormatException('章节正文为空');
      if (fetched) {
        try {
          await store.cacheReading(book, chapter, text, validate: validate);
        } on Exception {
          // Cache storage is best effort; policy is checked again below.
        }
        validate();
      }
      if (mixed != null && !policy.supervision.enabled) {
        final parts = mixed!;
        if (parts.whereType<BookTextSegment>().every(
          (part) => policy.textAllowed(part.text),
        )) {
          try {
            await store.cacheMixedReading(
              book,
              chapter,
              parts,
              validate: validate,
            );
          } on Exception {
            // Mixed layout is optional if storage is unavailable.
          }
        }
      }
      validate();
      return chapterPolicy.prepare(book, chapter, text);
    }

    if (body != null) return finish(body, token);
    final source = await _active(book);
    return _withBookRequestGuard(source, book, token, (active, guard) async {
      final fresh = await client.text(
        source,
        chapter,
        active,
        book: book,
        onSegments: (parts) => mixed = parts,
        requestGuard: guard,
      );
      if (!sourceAllowed(source)) throw const ContentBlocked();
      return finish(fresh, active);
    });
  }

  Future<List<BookChapterSegment>> mixedReading(
    Book book,
    BookChapter chapter,
    CancellationToken token,
  ) async {
    token.check();
    if (book.sourceId != 'local') await ensureSourceRiskLoaded();
    if (policy.supervision.enabled) return const [];
    await chapterPolicy.load();
    // Optional mixed-layout caches must not bypass transformed/reviewed text.
    if (chapterPolicy.hasOverrides) return const [];
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
  ) => _guardedChapterImages(book, chapter, token);

  Future<List<Uri>> imageAddressesInText(
    Book book,
    BookChapter chapter,
    String body,
    CancellationToken token,
  ) async {
    await ensureSourceRiskLoaded();
    requireBook(book, chapter);
    final source = await _active(book);
    return _withBookRequestGuard(source, book, token, (active, guard) async {
      final images = parseBookImageAddresses(source, chapter.uri, body);
      for (final image in images) {
        guard?.call(image, null);
      }
      active.check();
      if ((policy.supervision.enabled && images.isNotEmpty) ||
          !sourceAllowed(source) ||
          !bookAllowed(book) ||
          await _blocked(book.sourceId)) {
        throw const ContentBlocked();
      }
      active.check();
      requireBook(book, chapter);
      return images;
    });
  }

  Future<List<int>> chapterImageBytes(
    Book book,
    Uri image,
    CancellationToken token, {
    BookChapter? chapter,
    int maxBytes = BookResourceLimits.imageBytes,
  }) => _guardedChapterImageBytes(
    book,
    image,
    token,
    chapter: chapter,
    maxBytes: maxBytes,
  );

  Future<void> download(
    Book book,
    BookChapter chapter,
    CancellationToken token, {
    List<BookEdition> alternatives = const [],
    List<(Book, BookChapter)> matchedAlternatives = const [],
    bool tryOriginal = true,
    BookDownloadSourceHealth? sourceHealth,
  }) => _downloadChapter(
    book,
    chapter,
    token,
    alternatives: alternatives,
    matchedAlternatives: matchedAlternatives,
    tryOriginal: tryOriginal,
    sourceHealth: sourceHealth,
  );

  Future<Book> importLocal(File file) => _localLibrary.importLocal(file);

  Future<void> removeLocalBook(Book book) =>
      _localLibrary.removeLocalBook(book);

  Future<void> close() {
    final running = _closing;
    if (running != null) return running;
    _evidenceClosing = true;
    _bookPolicy.beginClose();
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

  Future<void> _close() => _closeBooksRepository(this);
}
