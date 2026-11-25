import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/reading_marks_store.dart';
import 'package:zero_player/features/books/domain/reading_mark.dart';
import 'package:zero_player/features/books/presentation/rich_reader_page.dart';
import 'package:zero_player/features/publications/application/publication_android_worker.dart';
import 'package:zero_player/features/publications/application/publication_output.dart';
import 'package:zero_player/features/publications/data/publication_alltool_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_archive_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_documents.dart';
import 'package:zero_player/features/publications/data/publication_dushupai_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_gallica_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_gutenberg_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_haodoo_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_kgbook_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_lunarora_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_obp_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_openstax_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_rule_examples.dart';
import 'package:zero_player/features/publications/data/publication_sobooks_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_standard_ebooks_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_tadoku_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_tokyo_hong_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_treasure_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_tstrs_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_transfer.dart';
import 'package:zero_player/features/publications/data/publication_wikisource_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_zip.dart';
import 'package:zero_player/features/publications/domain/acquisition_task.dart';
import 'package:zero_player/features/publications/domain/publication.dart';
import 'package:zero_player/features/publications/presentation/publications_page.dart';

import '../test_support/local_book_fixtures.dart';
import '../test_support/publication_archive_fixture.dart';
import '../test_support/publication_catalogue_fixture.dart';
import '../test_support/publication_pdf_admission_flow.dart';
import '../test_support/publication_epub_acceptance.dart';
import '../test_support/publication_publisher_pdf_search.dart';
import '../test_support/publication_space_flow.dart';
import '../test_support/publication_shared_copy_flow.dart';
import '../test_support/publication_source_maintenance.dart';

@pragma('vm:entry-point')
Future<void> publicationBackgroundMain() =>
    runPublicationAndroidWorker(allowLoopback: true);

const _evidence = String.fromEnvironment('PUBLICATION_EVIDENCE');
const _online = bool.fromEnvironment('RUN_PUBLICATIONS_ONLINE');
const _builtInOnline = bool.fromEnvironment('RUN_PUBLICATION_BUILTINS_ONLINE');
const _channelOnline = bool.fromEnvironment('RUN_PUBLICATION_CHANNELS_ONLINE');
const _remainingOnline = bool.fromEnvironment(
  'RUN_PUBLICATION_REMAINING_ONLINE',
);
const _authorOnline = bool.fromEnvironment('PUBLICATION_AUTHOR_ONLINE');
const _gutenbergOnline = bool.fromEnvironment('RUN_GUTENBERG_MIRROR_ONLINE');
const _redChamberOnline = bool.fromEnvironment('RUN_RED_CHAMBER_ONLINE');
const _obpDistributionOnline = bool.fromEnvironment(
  'RUN_OBP_DISTRIBUTION_ONLINE',
);
const _obpReconnect = bool.fromEnvironment('RUN_OBP_ANDROID_RECONNECT');
const _obpEpubBytes = 5135710;
const _obpEpubDigest =
    '2acf6c73502d98d659cd539c757b1c74d10ee71204b0f22669adfdade9d97aad';
const _timeoutProbe = bool.fromEnvironment('PUBLICATION_TIMEOUT_PROBE');
const _publisherPdf = String.fromEnvironment('PUBLICATION_PUBLISHER_PDF');
const _publisherBlocked = bool.fromEnvironment('PUBLICATION_PUBLISHER_BLOCKED');
const _publisherQuery = String.fromEnvironment('PUBLICATION_PUBLISHER_QUERY');
const _publisherHits = int.fromEnvironment('PUBLICATION_PUBLISHER_HITS');
const _publisherFirstPage = int.fromEnvironment(
  'PUBLICATION_PUBLISHER_FIRST_PAGE',
);
const _publisherNextPage = int.fromEnvironment(
  'PUBLICATION_PUBLISHER_NEXT_PAGE',
);
const _zipEvidence = String.fromEnvironment('PUBLICATION_ZIP_EVIDENCE');

const _quarkShare = String.fromEnvironment('PUBLICATION_QUARK_SHARE');
const _quarkDigest = String.fromEnvironment('PUBLICATION_QUARK_SHA256');
const _quarkBytes = int.fromEnvironment('PUBLICATION_QUARK_BYTES');
const _protectedShare = String.fromEnvironment('PUBLICATION_PROTECTED_SHARE');
const _protectedDigest = String.fromEnvironment('PUBLICATION_PROTECTED_SHA256');
const _protectedBytes = int.fromEnvironment('PUBLICATION_PROTECTED_BYTES');
const _configuredCatalogue = bool.fromEnvironment(
  'PUBLICATION_CONFIGURED_CATALOGUE',
);
const _ucShare = String.fromEnvironment('PUBLICATION_UC_SHARE');
const _ucDigest = String.fromEnvironment('PUBLICATION_UC_SHA256');
const _ucBytes = int.fromEnvironment('PUBLICATION_UC_BYTES');
const _downloadTimeout = Duration(seconds: 95);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (_obpReconnect) {
    testWidgets(
      'Android retains a verified publication range across network loss',
      _obpDownloadReconnect,
      skip: !Platform.isAndroid,
      timeout: const Timeout(Duration(minutes: 8)),
    );
    return;
  }
  if (_obpDistributionOnline) {
    testWidgets(
      'Open Book Publishers downloads both formats and restores PDF position',
      _obpDistributionDownload,
      timeout: const Timeout(Duration(minutes: 6)),
    );
    return;
  }
  if (_redChamberOnline) {
    testWidgets(
      'simplified Red Chamber query downloads the EPUB and applies admission',
      _redChamberDownload,
      timeout: const Timeout(Duration(minutes: 5)),
    );
    return;
  }
  if (_gutenbergOnline) {
    testWidgets(
      'Gutenberg official mirror discovers and searches a public edition',
      _gutenbergMirrorDownload,
      timeout: const Timeout(Duration(minutes: 5)),
    );
    return;
  }
  if (_remainingOnline) {
    _remainingChannelTests();
    return;
  }
  if (_channelOnline) {
    _channelContinuationTests();
    return;
  }
  registerPublicationPdfAdmissionTests(_withServices);
  testWidgets(
    'local PDF opens from the separate shelf and keeps version notes',
    _localReader,
  );
  testWidgets(
    'legacy shelf and reader preserve a shared publication file',
    (tester) => _withServices(
      (services) => verifyPublicationSharedCopyFlow(tester, services),
    ),
  );
  testWidgets(
    'publication PDF search pauses, resumes and navigates across pages',
    _publicationPdfSearch,
  );
  testWidgets(
    'EPUB reader renders a table, code, and image and follows a footnote',
    _epubReader,
  );
  testWidgets(
    'opening source management checks due sources and restores a pause',
    (tester) => withPublicationCatalogue(
      (fixture) => _withServices(
        (services) =>
            verifyPublicationSourceMaintenance(tester, services, fixture),
      ),
    ),
  );
  testWidgets(
    _authorOnline
        ? 'official PDF from an author search downloads and opens'
        : 'official PDF from an ISBN search downloads and opens',
    (tester) => _officialDownload(
      tester,
      _authorOnline ? 'Allen B. Downey' : '9781491939369',
      PublicationFormat.pdf,
      '6033000bac3f9268ad75ee041bf8e5d9a3bc8a33bb156399cbd014918cb59f94',
    ),
    skip: !_online && !_authorOnline,
    timeout: const Timeout(Duration(minutes: 3)),
  );
  testWidgets(
    'configured HTML rule discovers, downloads and opens a Green Tea Press original',
    _greenTeaPressDownload,
    skip: !_online,
    timeout: const Timeout(Duration(minutes: 3)),
  );
  testWidgets(
    'Open Logic Project rule example downloads and opens an official PDF',
    _openLogicProjectDownload,
    skip: !_builtInOnline,
    timeout: const Timeout(Duration(minutes: 4)),
  );
  testWidgets(
    'Internet Archive Gutenberg fixture discovers and opens the original',
    (tester) => withPublicationArchiveFixture(
      (digest) => _archiveGutenbergDownload(tester, expectedDigest: digest),
    ),
    // The Android download worker uses a separate isolate.
    skip: !Platform.isWindows,
  );
  testWidgets(
    'Internet Archive Gutenberg source downloads and opens a public original',
    _archiveGutenbergDownload,
    skip: !_builtInOnline,
    timeout: const Timeout(Duration(minutes: 3)),
  );
  testWidgets(
    'Shuge source opens a licensed public storage PDF',
    _shugeDownload,
    skip: !_builtInOnline,
    timeout: const Timeout(Duration(minutes: 6)),
  );
  testWidgets(
    'OpenStax catalogue finds an official textbook PDF and opens it',
    _openStaxDownload,
    skip: !_builtInOnline,
    timeout: const Timeout(Duration(minutes: 4)),
  );
  testWidgets(
    'Tadoku catalogue finds a licensed Japanese PDF and opens it',
    _tadokuDownload,
    skip: !_builtInOnline,
    timeout: const Timeout(Duration(minutes: 3)),
  );
  for (final (id, host) in const [
    (alltoolSource, 'alltool.top'),
    (kgbookSource, 'kgbook.com'),
    (tstrsSource, 'tstrs.me'),
  ]) {
    testWidgets(
      'Public directory from $host discovers and filters metadata',
      (_) => _publicDirectory(id, host),
      skip: !_builtInOnline,
    );
  }
  for (final (source, name, query, url) in const [
    (
      lunaroraSource,
      'Lunarora',
      'python',
      'https://lunarora.com/book/9787115474810',
    ),
    (
      dushupaiSource,
      'Dushupai',
      'python',
      'https://www.dushupai.com/book-content-18908.html',
    ),
    (
      tokyoHongSource,
      'Tokyo Hong',
      '司馬溫公切韻',
      'https://kanseki.ioc.u-tokyo.ac.jp/kanzi/user/query_detail_im.php?nu=A582100',
    ),
  ]) {
    testWidgets(
      '$name searches its public catalogue',
      (_) => _remoteCatalogueSearch(source, query, Uri.parse(url)),
      skip: !_builtInOnline,
    );
    testWidgets(
      '$name discovers public book metadata',
      (_) => _remoteCatalogueDiscovery(source),
      skip: !_builtInOnline,
    );
  }
  _cloudShareTests();
  _androidTests();
  testWidgets(
    'large file admission, encrypted PDF and independently generated ZIP samples',
    (_) => _measureSamples(),
    skip: _evidence.isEmpty,
    timeout: const Timeout(Duration(minutes: 5)),
  );
  testWidgets(
    'a large publisher PDF exercises file-based rendering and admission',
    _measurePublisherPdf,
    skip: _publisherPdf.isEmpty,
    timeout: const Timeout(Duration(minutes: 4)),
  );
  testWidgets(
    'a retained ZIP survives recovery and can import a second book',
    (_) => _withServices(_retainedZip),
    timeout: const Timeout(Duration(minutes: 3)),
  );
  testWidgets(
    'unavailable book destinations have distinct recovery states',
    (_) => _withServices(_directorySaveFailures),
  );
  testWidgets(
    'Android document selection reserves bounded staging before reading',
    (_) => _withServices(_androidDocumentBudget),
    skip: !Platform.isAndroid,
  );
  testWidgets(
    'a blocked candidate falls back only to the confirmed edition',
    (_) => _withServices(_sameEdition, allowPrivate: true),
  );
}

Future<void> _gutenbergMirrorDownload(WidgetTester tester) => _withServices((
  services,
) async {
  final discovery = services.publications.discovery;
  await _useOnlyBuiltIn(services, gutenbergPublicationSource);
  final browsed =
      (await discovery.search('', CancellationToken()).toList()).single;
  expect(browsed.problem, isNull);
  expect(browsed.editions.expand((book) => book.candidates), isNotEmpty);
  final matches =
      (await discovery
              .search("Alice's Adventures in Wonderland", CancellationToken())
              .toList())
          .single;
  expect(matches.problem, isNull);
  final edition = matches.editions.singleWhere(
    (book) => book.page?.path == '/ebooks/928',
  );
  expect(edition.candidates.single.link.host, 'gutenberg.pglaf.org');
  await _fetchAndOpen(
    tester,
    services,
    edition,
    PublicationFormat.epub,
    expectedDigest: null,
  );
  await _openPublicationReader(tester, services, edition.title);
});

Future<void> _redChamberDownload(WidgetTester _) => _withServices((
  services,
) async {
  await _useOnlyBuiltIn(services, gutenbergPublicationSource);
  final module = services.publications;
  final result = await module.discovery
      .search('《红楼梦》', CancellationToken(), maxPages: 1)
      .single;
  expect(result.problem, isNull);
  final work = result.editions.singleWhere(
    (book) => book.page?.path == '/ebooks/24264',
  );
  expect(work.title, '紅樓夢');
  final id = await module.workflow.add(work, PublicationFormat.epub);
  final task = await _taskWhen(
    services,
    id,
    (item) =>
        item.state == AcquisitionState.downloaded ||
        item.state == AcquisitionState.failed,
    timeout: const Duration(minutes: 3),
  );
  expect(task.state, AcquisitionState.downloaded, reason: '${task.problem}');
  final downloaded = module.workflow.transfer.part(id);
  expect(await detectPublicationFormat(downloaded), PublicationFormat.epub);
  debugPrint(
    'Red Chamber transfer ${await downloaded.length()} bytes '
    '${await publicationFileDigest(downloaded, CancellationToken())}',
  );
  await expectLater(
    module.workflow.finish(task),
    throwsA(
      isA<PublicationFailure>().having(
        (failure) => failure.problem,
        'problem',
        PublicationProblem.blocked,
      ),
    ),
  );
  expect((await module.store.task(id))?.problem, PublicationProblem.blocked);
  expect(await module.library.holdings(), isEmpty);
});

Future<PublicationEdition> _obpEpubEdition(AppServices services) async {
  final matches =
      (await services.publications.discovery
              .search('The Classic Short Story', CancellationToken())
              .toList())
          .single;
  expect(matches.problem, isNull);
  final edition = matches.editions.singleWhere(
    (book) => book.page?.path == '/books/10.11647/obp.0039',
  );
  expect(edition.isbn, '9781909254770');
  expect(edition.license, 'CC BY');
  expect(
    edition.candidates.map((copy) => copy.format),
    unorderedEquals([PublicationFormat.pdf, PublicationFormat.epub]),
  );
  return edition;
}

Future<void> _obpDownloadReconnect(WidgetTester tester) => _withServices((
  services,
) async {
  await _useOnlyBuiltIn(services, obpPublicationSource);
  final edition = await _obpEpubEdition(services);
  final module = services.publications;
  debugPrint('Publication reconnect ready ${services.root.path}');
  await _waitForReconnectSignal(services, 'start');
  final id = await module.workflow.add(edition, PublicationFormat.epub);
  final partial = await _taskWhen(
    services,
    id,
    (task) =>
        task.state == AcquisitionState.downloading &&
        task.received > 0 &&
        task.received < _obpEpubBytes,
    timeout: const Duration(seconds: 120),
  );
  expect(partial.total, _obpEpubBytes);
  Future<List<Map<String, Object?>>> checkpoints() => module.store.db.rows(
    'SELECT rowid, start, digest FROM publication_ranges WHERE task=? '
    'ORDER BY start',
    [id],
  );

  final saved = (await checkpoints()).single;
  debugPrint('Publication reconnect cut ${partial.received}/${partial.total}');
  final failed = await _taskWhen(
    services,
    id,
    (task) => task.state == AcquisitionState.failed,
    timeout: const Duration(seconds: 110),
  );
  expect(
    failed.problem,
    anyOf(PublicationProblem.network, PublicationProblem.timeout),
  );
  expect(failed.received, partial.received);
  expect(await checkpoints(), [saved]);
  debugPrint('Publication reconnect retry ${failed.problem?.name}');
  await _waitForReconnectSignal(services, 'online');
  await module.workflow.start(id);
  final resumed = await _taskWhen(
    services,
    id,
    (task) =>
        task.state == AcquisitionState.downloaded ||
        task.state == AcquisitionState.failed,
    afterGeneration: failed.generation,
    timeout: const Duration(seconds: 150),
  );
  expect(
    resumed.state,
    AcquisitionState.downloaded,
    reason: resumed.problem?.label,
  );
  expect(resumed.received, _obpEpubBytes);
  final complete = await checkpoints();
  expect(complete, hasLength(2));
  // A replacement checkpoint would have a different rowid even for the same bytes.
  expect(complete.singleWhere((row) => row['start'] == saved['start']), saved);
  await _verifyDownloadedBook(
    tester,
    services,
    id,
    expectedDigest: _obpEpubDigest,
  );
  await _openPublicationReader(tester, services, edition.title);
  debugPrint(
    'Publication reconnect verified ${partial.received}/${resumed.received}',
  );
});

Future<void> _waitForReconnectSignal(AppServices services, String stage) async {
  final signal = File('${services.root.path}/reconnect-$stage');
  final deadline = DateTime.now().add(const Duration(seconds: 100));
  while (!await signal.exists()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('No emulator signal for publication reconnect: $stage');
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
}

Future<void> _obpDistributionDownload(WidgetTester tester) => _withServices((
  services,
) async {
  final module = services.publications;
  await _useOnlyBuiltIn(services, obpPublicationSource);
  final browsed =
      (await module.discovery
              .search('', CancellationToken(), maxPages: 1)
              .toList())
          .single;
  expect(browsed.problem, isNull);
  expect(browsed.editions.expand((book) => book.candidates), isNotEmpty);
  final edition = await _obpEpubEdition(services);
  await _fetchAndOpen(
    tester,
    services,
    edition,
    PublicationFormat.epub,
    expectedDigest: _obpEpubDigest,
  );
  await _openPublicationReader(
    tester,
    services,
    edition.title,
    verifyEpub: (reopen) =>
        verifyPublicationEpubAcceptance(tester, services, reopen),
  );
  final pdfMatches =
      (await module.discovery
              .search('978-1-78374-037-6', CancellationToken())
              .toList())
          .single;
  expect(pdfMatches.problem, isNull);
  final pdf = pdfMatches.editions.single;
  expect(pdf.page?.path, '/books/10.11647/obp.0043');
  for (var attempt = 0; attempt < 2; attempt++) {
    await _fetchAndOpen(
      tester,
      services,
      pdf,
      PublicationFormat.pdf,
      expectedDigest:
          '0c0e0b5559787a4a4645102effa9da60ef9344fd34268b4f5ddb8d27aa686e6b',
    );
  }
  await _openPublicationReader(
    tester,
    services,
    pdf.title,
    checkPdfProgress: true,
  );
  expect(
    (await module.library.holdings()).map((book) => book.format),
    unorderedEquals([PublicationFormat.pdf, PublicationFormat.epub]),
  );
});

void _remainingChannelTests() {
  testWidgets(
    'Standard Ebooks discovers releases and downloads a public search result',
    _standardEbooksDownload,
    timeout: const Timeout(Duration(minutes: 4)),
  );
  testWidgets(
    'Open Book Publishers discovers KBART books and filters by ISBN',
    (_) async {
      await _remoteCatalogueDiscovery(obpPublicationSource);
      await _remoteCatalogueSearch(
        obpPublicationSource,
        '978-1-80064-404-5',
        Uri.https('www.openbookpublishers.com', '/books/10.11647/obp.0290'),
      );
    },
  );
  testWidgets(
    'SoBooks discovers entries and filters the public directory',
    (_) => _publicDirectory(sobooksPublicationSource, 'sobooks.cc'),
  );
  testWidgets('BnF SRU discovers and searches public Gallica editions', (
    _,
  ) async {
    await _remoteCatalogueDiscovery(gallicaPublicationSource);
    await _remoteCatalogueSearch(
      gallicaPublicationSource,
      'Dépit amoureux',
      Uri.https('gallica.bnf.fr', '/ark:/12148/bpt6k9688417m'),
    );
  });
}

Future<void> _standardEbooksDownload(WidgetTester tester) =>
    _withServices((services) async {
      final module = services.publications;
      await _useOnlyBuiltIn(services, standardEbooksPublicationSource);
      final discovered =
          (await module.discovery
                  .search('', CancellationToken(), maxPages: 1)
                  .toList())
              .single;
      expect(discovered.problem, isNull);
      expect(discovered.editions.expand((book) => book.candidates), isNotEmpty);
      final matches =
          (await module.discovery
                  .search('Sir Nigel', CancellationToken(), maxPages: 1)
                  .toList())
              .single;
      expect(matches.problem, isNull);
      final edition = matches.editions.singleWhere(
        (book) => book.page?.path == '/ebooks/arthur-conan-doyle/sir-nigel',
      );
      expect(edition.author, 'Arthur Conan Doyle');
      expect(edition.candidates.single.format, PublicationFormat.epub);
      await _fetchAndOpen(
        tester,
        services,
        edition,
        PublicationFormat.epub,
        expectedDigest: null,
      );
      await _openPublicationReader(tester, services, edition.title);
    });

void _channelContinuationTests() {
  testWidgets(
    'Wikisource OPDS discovers, searches, downloads and opens an EPUB',
    _wikisourceDownload,
    timeout: const Timeout(Duration(minutes: 4)),
  );
  testWidgets(
    'Open Logic Project rule example downloads and opens an official PDF',
    _openLogicProjectDownload,
    timeout: const Timeout(Duration(minutes: 4)),
  );
  testWidgets(
    'Treasure Chest discovers books and filters the public index',
    (_) => _publicDirectory(treasurePublicationSource, 'jbiaojerry.github.io'),
  );
  testWidgets(
    'Haodoo discovers and searches the public store catalogue',
    (_) => _publicDirectory(haodooPublicationSource, 'haodoo.org'),
  );
  testWidgets(
    'Mobi Books v2 rule discovers and searches public records',
    (_) => _ruleDirectory(
      mobiPublicationRule,
      '伊势物语',
      Uri.https('www.mobitushu.cn', '/wenxue/28857.html'),
    ),
  );
  if (Platform.isAndroid) _androidTests();
}

Future<void> _ruleDirectory(
  Map<String, Object?> rule,
  String query,
  Uri page,
) => _withServices((services) async {
  final discovery = services.publications.discovery;
  await discovery.saveConfig(jsonEncode(rule));
  final source = (await discovery.sources())
      .singleWhere((item) => item.source.name == rule['name'])
      .source;
  await discovery.setEnabled(source, true);
  final discovered =
      (await discovery.search('', CancellationToken()).toList()).single;
  expect(discovered.problem, isNull);
  expect(discovered.editions, isNotEmpty);
  final matched =
      (await discovery.search(query, CancellationToken()).toList()).single;
  expect(matched.problem, isNull);
  expect(matched.editions.map((book) => book.page), contains(page));
  expect(
    [
      ...discovered.editions,
      ...matched.editions,
    ].expand((book) => book.candidates),
    isEmpty,
  );
});

Future<void> _wikisourceDownload(WidgetTester tester) =>
    _withServices((services) async {
      final module = services.publications;
      await _useOnlyBuiltIn(services, wikisourcePublicationSource);
      final discovered =
          (await module.discovery
                  .search('', CancellationToken(), maxPages: 1)
                  .toList())
              .single;
      expect(discovered.problem, isNull);
      expect(discovered.editions, isNotEmpty);
      final matches =
          (await module.discovery
                  .search('Charles Francis Adams', CancellationToken())
                  .toList())
              .single;
      expect(matches.problem, isNull);
      final edition = matches.editions.singleWhere(
        (book) => book.page?.pathSegments.last == "'Tis_Sixty_Years_Since",
      );
      expect(edition.edition, '1913');
      expect(edition.candidates.single.format, PublicationFormat.epub);
      await _fetchAndOpen(
        tester,
        services,
        edition,
        PublicationFormat.epub,
        expectedDigest: null,
      );
      await _openPublicationReader(tester, services, edition.title);
    });

Future<void> _openPublicationReader(
  WidgetTester tester,
  AppServices services,
  String title, {
  bool checkPdfProgress = false,
  Future<void> Function(Future<void> Function() reopen)? verifyEpub,
}) async {
  Future<void> read() async {
    await tester.tap(find.text(title).first);
    await _until(
      tester,
      () => find.byType(RichReaderPage).evaluate().isNotEmpty,
    );
    await _until(tester, () => find.byTooltip('阅读菜单').evaluate().isNotEmpty);
  }

  await tester.pumpWidget(_publicationApp(services));
  await _until(tester, () => find.text('书库').evaluate().isNotEmpty);
  await tester.tap(find.text('书库'));
  await tester.pumpAndSettle();
  await read();
  await verifyEpub?.call(read);
  if (checkPdfProgress) {
    final next = find.byTooltip('下一页');
    await _until(tester, () => next.evaluate().isNotEmpty);
    await tester.tap(next.last);
    final secondPage = find.textContaining(RegExp(r'^2 / \d+$'));
    await _until(tester, () => secondPage.evaluate().isNotEmpty);
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
    await read();
    await _until(tester, () => secondPage.evaluate().isNotEmpty);
    debugPrint(
      'Publication ${Platform.operatingSystem} PDF reopened on page 2',
    );
  }
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
}

typedef _CatalogueSample = ({
  String name,
  int topic,
  int post,
  String query,
  String sharePath,
  int bytes,
  String digest,
});

const _catalogueSamples = <_CatalogueSample>[
  (
    name: 'configured HTML source supplies a code and binds its real PDF',
    topic: 134934,
    post: 184673,
    query: '七十二翻',
    sharePath: '/s/a1c3ece1d70c',
    bytes: 2932449,
    digest: '7ac40b2429a5d42141385395990dd3d87c79e64149d4dccc86c25ef3f217949d',
  ),
  (
    name: 'abbreviated HTML link resolves the complete share and selected PDF',
    topic: 190899,
    post: 218028,
    query: '黄帝内经',
    sharePath: '/s/d080135520ef',
    bytes: 26554853,
    digest: 'b07acaf071cf03d281ab476e384378f9b018bcf63147135c4099ab719754cbc9',
  ),
];

void _cloudShareTests() {
  for (final sample in _catalogueSamples) {
    testWidgets(
      sample.name,
      (tester) => _catalogueShare(tester, sample),
      skip: !_configuredCatalogue,
      timeout: const Timeout(Duration(minutes: 4)),
    );
  }
  testWidgets(
    'Quark public share downloads and opens an EPUB without an account',
    (tester) => _publicShareDownload(
      tester,
      _quarkShare,
      PublicationFormat.epub,
      _quarkBytes,
      _quarkDigest,
    ),
    skip: _quarkShare.isEmpty,
    timeout: const Timeout(Duration(minutes: 3)),
  );
  testWidgets(
    'Quark protected share requires a code and opens the complete PDF',
    (tester) {
      final code = Platform.environment['ZERO_PUBLICATION_SAMPLE_CODE'];
      expect(code, isNotNull);
      return _publicShareDownload(
        tester,
        _protectedShare,
        PublicationFormat.pdf,
        _protectedBytes,
        _protectedDigest,
        shareCode: code,
        expectedText: false,
      );
    },
    skip: _protectedShare.isEmpty,
    timeout: const Timeout(Duration(minutes: 3)),
  );
  testWidgets(
    'UC public share downloads and renders an image-only PDF',
    (tester) => _publicShareDownload(
      tester,
      _ucShare,
      PublicationFormat.pdf,
      _ucBytes,
      _ucDigest,
      expectedText: false,
      downloadTimeout: const Duration(minutes: 4),
    ),
    skip: _ucShare.isEmpty,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

void _androidTests() {
  testWidgets(
    'Android dataSync host checkpoints, pauses and resumes a real PDF',
    (_) => _withServices(
      (services) => _androidDownload(services, timeout: false),
      allowPrivate: true,
    ),
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 3)),
  );
  testWidgets(
    'Android dataSync checkpoints on system timeout and resumes in foreground',
    (_) => _withServices(
      (services) => _androidDownload(services, timeout: true),
      allowPrivate: true,
    ),
    skip: !Platform.isAndroid || !_timeoutProbe,
    timeout: const Timeout(Duration(minutes: 3)),
  );
  testWidgets(
    'capacity denial waits without writing, then downloads exact ranges',
    (tester) => _withServices(
      (services) => verifyPublicationCapacityFlow(tester, services),
      allowPrivate: true,
    ),
  );
  testWidgets(
    'Android opens independent AES and ZipCrypto fixtures',
    (_) => _encryptedArchives(CancellationToken(), _zipEvidence),
    skip: !Platform.isAndroid || _zipEvidence.isEmpty,
  );
}

Widget _publicationApp(AppServices services) => MaterialApp(
  home: Scaffold(
    body: PublicationsPage(
      module: services.publications,
      books: services.books,
      platform: services.platform,
    ),
  ),
);

Future<void> _localReader(WidgetTester tester) => _withServices((
  services,
) async {
  final module = services.publications;
  await module.workflow.initialize();
  final file = await File(
    '${services.root.path}/Manual.pdf',
  ).writeAsBytes(samplePdf());
  final oldBook = await services.books.importLocal(file);
  await module.library.attachLegacy(oldBook);
  final digest = await module.workflow.importLocal(file);
  expect(digest, oldBook.uri.path);
  expect((await module.library.holdings()).map((item) => item.digest).toSet(), {
    digest,
  });
  expect(await services.books.documentFile(oldBook, 'pdf').exists(), isTrue);
  await services.books.removeLocalBook(oldBook);
  expect(await services.books.store.entry(oldBook), isNull);
  expect(await services.books.documentFile(oldBook, 'pdf').exists(), isTrue);
  await tester.pumpWidget(_publicationApp(services));
  await _until(tester, () => find.text('书库').evaluate().isNotEmpty);
  await tester.tap(find.text('书库'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Manual').first);
  await _until(tester, () => find.byTooltip('阅读菜单').evaluate().isNotEmpty);
  expect(find.byType(RichReaderPage), findsOneWidget);
  await tester.tap(find.byTooltip('下一页').last);
  await _until(tester, () => find.text('2 / 2').evaluate().isNotEmpty);
  await tester.pumpAndSettle();
  final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
  final page = viewer.pages[1];
  final pageText = await page.loadStructuredText();
  final word = pageText.fullText.indexOf('Technical');
  expect(word, isNonNegative);
  final documentPoint = pageText.charRects[word + 3].center.toOffsetInDocument(
    page: page,
    pageRect: viewer.layout.pageLayouts[1],
  );
  await viewer.ensureVisible(
    Rect.fromCenter(center: documentPoint, width: 32, height: 32),
    duration: Duration.zero,
    margin: 24,
  );
  await tester.pumpAndSettle();
  await viewer.textSelectionDelegate.selectWord(documentPoint);
  expect(viewer.textSelectionDelegate.isCopyAllowed, isTrue);
  expect(viewer.textSelectionDelegate.hasSelectedText, isTrue);
  await tester.pumpAndSettle();
  final pressPoint = viewer.documentToGlobal(documentPoint)!;
  expect(tester.getRect(find.byType(PdfViewer)).contains(pressPoint), isTrue);
  await tester.tapAt(
    pressPoint,
    kind: ui.PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await _until(tester, () => find.text('添加摘录').evaluate().isNotEmpty);
  await tester.tap(find.text('添加摘录'));
  await tester.pumpAndSettle();
  final selected = find.textContaining('Technical');
  expect(selected, findsOneWidget);
  final excerpt = tester.widget<Text>(selected).data!.trim();
  await tester.enterText(
    find.byType(TextField).last,
    'Reading note for this version',
  );
  await tester.tap(find.text('记录当前位置'));
  await _until(
    tester,
    () => find.text('Reading note for this version').evaluate().isNotEmpty,
  );
  final note = (await module.store.db.rows(
    'SELECT section,excerpt,text FROM publication_notes',
  )).single;
  expect(note['text'], 'Reading note for this version');
  expect(note['excerpt'], excerpt);
  expect(note['section'], 1);
  final backup = await module.output.backup.encode();
  final snapshot = jsonDecode(backup) as Map;
  expect(snapshot['positions'][digest]['index'], 1);
  expect(snapshot['notes'][digest].single['section'], 1);
  final restore = await File(
    '${services.root.path}/backup.json',
  ).writeAsString(backup);
  expect(await module.output.backup.restore(restore), 2);
  expect(await module.output.backup.restore(restore), 2);
  expect(
    await module.store.db.rows('SELECT * FROM publication_notes'),
    hasLength(1),
  );
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
});

Future<void> _publicationPdfSearch(WidgetTester tester) =>
    _withServices((services) async {
      final file = await File(
        '${services.root.path}/SearchManual.pdf',
      ).writeAsBytes(samplePdf());
      await services.publications.workflow.importLocal(file);
      await tester.pumpWidget(_publicationApp(services));
      await _until(tester, () => find.text('书库').evaluate().isNotEmpty);
      await tester.tap(find.text('书库'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SearchManual'));
      await _until(tester, () => find.byTooltip('阅读菜单').evaluate().isNotEmpty);
      await tester.tap(find.byTooltip('阅读菜单').last);
      await tester.pumpAndSettle();

      final searchField = find.widgetWithText(TextField, '全文搜索');
      await tester.enterText(searchField, 'TECHNICAL');
      await tester.pump();
      expect(find.text('检索中 · 0'), findsOneWidget);
      await tester.tap(find.byTooltip('暂停检索'));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('已暂停 · 0'), findsOneWidget);

      await tester.tap(find.byTooltip('继续检索'));
      await _until(tester, () => find.text('2 项').evaluate().isNotEmpty);
      await tester.tap(find.byTooltip('下个结果'));
      await _until(tester, () => find.text('2 / 2').evaluate().isNotEmpty);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('阅读菜单').last);
      await tester.pumpAndSettle();
      expect(searchField, findsNothing);
      await tester.tap(find.byTooltip('阅读菜单').last);
      await tester.pumpAndSettle();
      expect(searchField, findsOneWidget);
      expect(find.text('0 项'), findsOneWidget);
      expect(find.byTooltip('暂停检索'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

Future<void> _directorySaveFailures(AppServices services) async {
  final module = services.publications;
  final original = await File(
    '${services.root.path}/DirectoryCase.pdf',
  ).writeAsBytes(samplePdf());
  final digest = await module.workflow.importLocal(original);

  Future<void> saveFailsWith(PublicationProblem problem) => expectLater(
    module.output.autoSave(digest),
    throwsA(
      isA<PublicationFailure>().having(
        (error) => error.problem,
        'problem',
        problem,
      ),
    ),
  );

  if (Platform.isAndroid) {
    await module.store.setPreference(
      PublicationOutput.directoryPreference,
      'content://com.android.externalstorage.documents/tree/'
      'primary%3ADocuments%2FZeroPlayerNoPublicationTestGrant',
    );
    await saveFailsWith(PublicationProblem.directoryPermission);
  } else {
    final directory = await Directory(
      '${services.root.path}/external',
    ).create();
    await module.store.setPreference(
      PublicationOutput.directoryPreference,
      directory.path,
    );
    final path = await module.output.autoSave(digest);
    final saved = File(path!);
    expect(await saved.readAsBytes(), samplePdf());
    expect(await module.output.autoSave(digest), path);
    final conflicts = await Directory(
      '${services.root.path}/external-conflict',
    ).create();
    const existingBytes = 'Existing file belonging to the directory owner';
    final occupied = await File(
      '${conflicts.path}/${saved.uri.pathSegments.last}',
    ).writeAsString(existingBytes);
    await module.store.setPreference(
      PublicationOutput.directoryPreference,
      conflicts.path,
    );
    await saveFailsWith(PublicationProblem.destinationConflict);
    expect(await occupied.readAsString(), existingBytes);
    expect(await saved.readAsBytes(), samplePdf());

    await module.store.setPreference(
      PublicationOutput.directoryPreference,
      '${directory.path}/unavailable',
    );
    await saveFailsWith(PublicationProblem.directoryUnavailable);
  }
  expect(await original.readAsBytes(), samplePdf());
  expect((await module.library.holdings()).single.resident, isTrue);
}

Future<void> _androidDocumentBudget(AppServices services) async {
  final module = services.publications;
  const channel = MethodChannel('zero_player/publications_files');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  int? declared = (512 << 20) + 1;
  var remaining = 9 << 20;
  var reads = 0;
  var releases = 0;
  messenger.setMockMethodCallHandler(channel, (call) async {
    switch (call.method) {
      case 'choose':
        return {'name': 'Publisher scan.pdf', 'size': declared};
      case 'read':
        reads++;
        final count = remaining.clamp(0, 512 << 10);
        remaining -= count;
        return Uint8List(count);
      case 'release':
        releases++;
        return null;
    }
    throw MissingPluginException(call.method);
  });
  try {
    await expectLater(
      module.workflow.withAndroidDocument(
        (_) async => fail('oversize selection'),
      ),
      throwsA(
        isA<PublicationFailure>().having(
          (failure) => failure.problem,
          'problem',
          PublicationProblem.invalid,
        ),
      ),
    );
    expect(reads, 0);
    expect(releases, 1);
    declared = null;
    await module.workflow.withAndroidDocument((selected) async {
      expect(await selected.file.length(), 9 << 20);
      final usage = await module.space.usage();
      expect(usage.used, 9 << 20);
      expect(usage.reserved, 0);
      expect(releases, 2);
    });
    expect(reads, 19);
    final usage = await module.space.usage();
    expect(usage.used, 0);
    expect(usage.reserved, 0);
  } finally {
    messenger.setMockMethodCallHandler(channel, null);
  }
}

Future<void> _epubReader(WidgetTester tester) => _withServices((
  services,
) async {
  final mime = 'application/epub+zip'.codeUnits;
  final archive = Archive()
    ..addFile(ArchiveFile.noCompress('mimetype', mime.length, mime));
  void add(String path, String contents) {
    archive.addFile(ArchiveFile.string(path, contents));
  }

  add(
    'META-INF/container.xml',
    '<container><rootfiles><rootfile full-path="text/book.opf"/></rootfiles></container>',
  );
  add(
    'text/book.opf',
    '''
    <package><metadata><title>Engineering Reader</title></metadata>
    <manifest><item id="start" href="main.xhtml" media-type="application/xhtml+xml"/>
    <item id="notes" href="notes.xhtml" media-type="application/xhtml+xml"/></manifest>
    <spine><itemref idref="start"/><itemref idref="notes"/></spine></package>''',
  );
  add('text/main.xhtml', '''
    <html><body><h1>Engineering notes</h1>
    <p><a href="notes.xhtml#explanation">阅读脚注</a></p>
    <table><tr><th>Scale</th><td>Measured length</td></tr></table>
    <pre><code>final value = 42;</code></pre>
    <img width="36" height="36" src="marker.png" alt="Measurement marker"/>
    </body></html>''');
  add('text/notes.xhtml', '''
    <html><body><h1 id="explanation">Footnote explanation</h1>
    <p>Units are recorded with each measurement.</p></body></html>''');
  final image = ZipDecoder()
      .decodeBytes(sampleEpub())
      .findFile('OEBPS/picture.png')!;
  archive.addFile(ArchiveFile.bytes('text/marker.png', image.content));
  final file = await File(
    '${services.root.path}/reading.epub',
  ).writeAsBytes(ZipEncoder().encode(archive));
  final digest = await services.publications.workflow.importLocal(file);
  final frame = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(key: frame, child: _publicationApp(services)),
  );
  await _until(tester, () => find.text('书库').evaluate().isNotEmpty);
  await tester.tap(find.text('书库'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Engineering Reader').first);
  final footnote = find.text('阅读脚注', findRichText: true);
  await _until(tester, () => footnote.evaluate().isNotEmpty);
  expect(
    find.textContaining('Measured length', findRichText: true),
    findsWidgets,
  );
  expect(
    find.textContaining('final value = 42;', findRichText: true),
    findsWidgets,
  );
  await _saveReaderFrame(tester, frame);
  await tester.ensureVisible(footnote.first);
  await tester.pumpAndSettle();
  await tester.tapAt(_firstCharacters(tester, footnote.first, 4));
  final body = find.text(
    'Units are recorded with each measurement.',
    findRichText: true,
  );
  await _until(tester, () => body.evaluate().isNotEmpty);
  await tester.longPressAt(_firstCharacters(tester, body.first, 5));
  await _until(tester, () => find.text('添加摘录').evaluate().isNotEmpty);
  await tester.tap(find.text('添加摘录'));
  await tester.pumpAndSettle();
  expect(find.text('Units'), findsOneWidget);
  await tester.tap(find.text('记录当前位置'));
  await _until(tester, () => find.text('第 2 节').evaluate().isNotEmpty);
  final stored = await services.publications.store.db.rows(
    'SELECT excerpt FROM publication_notes WHERE digest=? AND section=1',
    [digest],
  );
  expect(stored.single['excerpt'], 'Units');
  await tester.tap(find.byTooltip('关闭').last);
  await tester.pumpAndSettle();
  await tester.longPressAt(_firstCharacters(tester, body.first, 5));
  await _until(tester, () => find.text('添加标注').evaluate().isNotEmpty);
  await tester.tap(find.text('添加标注'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('波浪线'));
  await tester.tap(find.byTooltip('蓝色'));
  await tester.tap(find.text('关联书签'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('保存标注'));
  await tester.pumpAndSettle();

  final book = publicationReaderBook(digest, PublicationFormat.epub, '', '');
  final marks = ReadingMarksStore(services.books.store, book, () => true);
  final savedMark = (await marks.load(digest: digest)).single;
  expect(savedMark.quote, 'Units');
  expect(savedMark.section, 1);
  expect(savedMark.style, ReadingMarkStyle.wave);
  expect(savedMark.color, 3);
  expect(savedMark.bookmark, isTrue);

  if (find.byTooltip('标注与关联书签').evaluate().isEmpty) {
    await tester.tap(find.byTooltip('阅读菜单'));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byTooltip('上一章'));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('阅读菜单'));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('标注与关联书签'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Units'));
  await _until(tester, () => body.evaluate().isNotEmpty);
  expect((await marks.load()).single.range, savedMark.range);
  await tester.tap(find.byTooltip('阅读菜单'));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('标注与关联书签'));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('标注操作'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('修改标注'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('框选'));
  await tester.tap(find.byTooltip('紫色'));
  await tester.tap(find.text('保存标注'));
  await tester.pumpAndSettle();
  final changed = (await marks.load()).single;
  expect(changed.range, savedMark.range);
  expect(changed.style, ReadingMarkStyle.outline);
  expect(changed.color, 4);
  expect(changed.bookmark, isTrue);
  await tester.tap(find.byTooltip('标注操作'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('删除标注'));
  await tester.pumpAndSettle();
  expect(await marks.load(), isEmpty);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
});

Offset _firstCharacters(WidgetTester tester, Finder finder, int count) {
  final text = tester.renderObject<RenderParagraph>(finder);
  final hit = text
      .getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: count))
      .first
      .toRect()
      .center;
  return text.localToGlobal(hit);
}

Future<void> _saveReaderFrame(WidgetTester tester, GlobalKey frame) async {
  if (_evidence.isEmpty) return;
  await tester.pumpAndSettle();
  final boundary =
      frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage();
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await File(
      '$_evidence/reader-epub-${Platform.operatingSystem}.png',
    ).writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  } finally {
    image.dispose();
  }
}

Future<void> _officialDownload(
  WidgetTester tester,
  String query,
  PublicationFormat format,
  String digest,
) => _withServices((services) async {
  final module = services.publications;
  await module.workflow.initialize();
  if (_authorOnline && !_online) {
    final source = (await module.discovery.sources())
        .singleWhere((status) => status.source.id == 'open-textbooks')
        .source;
    await module.discovery.setEnabled(source, true);
    await module.discovery.check(source);
  }
  final editions = <PublicationEdition>[];
  final problems = <String>[];
  await for (final update in module.discovery.search(
    query,
    CancellationToken(),
  )) {
    if (update.problem case final error?) {
      problems.add('${update.source.id}: ${error.name}');
    }
    editions.addAll(update.editions);
  }
  final matching = editions.where(
    (item) => item.candidates.any(
      (candidate) =>
          candidate.format == format &&
          (candidate.digest == digest || candidate.digest == null),
    ),
  );
  expect(matching, isNotEmpty, reason: 'Sources for $query: $problems');
  await _fetchAndOpen(
    tester,
    services,
    matching.first,
    format,
    expectedDigest: digest,
  );
});

Future<void> _archiveGutenbergDownload(
  WidgetTester tester, {
  String expectedDigest =
      'c9b33c2c4826ba8666fbd6ecfca98ba65eee3a629e75cb030b1100ca884df2c3',
}) => _withServices((services) async {
  final module = services.publications;
  await module.workflow.initialize();
  final sources = await module.discovery.sources();
  for (final status in sources) {
    if (status.enabled) await module.discovery.setEnabled(status.source, false);
  }
  final source = sources
      .singleWhere((status) => status.source.id == 'internet-archive-gutenberg')
      .source;
  await module.discovery.setEnabled(source, true);
  const title = archiveFixtureTitle;
  final results = await module.discovery
      .search(title, CancellationToken(), maxPages: 1)
      .toList();
  if (results.single.problem != null) {
    await ArchiveGutenbergCatalogue(
      module.discovery.http,
    ).search(title, CancellationToken(), maxPages: 1, allowed: (_) => true);
  }
  expect(results.single.problem, isNull);
  final edition = results.single.editions.singleWhere(
    (item) => item.page?.path == '/details/$archiveFixtureId',
  );
  await _fetchAndOpen(
    tester,
    services,
    edition,
    PublicationFormat.epub,
    expectedDigest: expectedDigest,
  );
  await tester.pumpWidget(_publicationApp(services));
  await _until(tester, () => find.text('书库').evaluate().isNotEmpty);
  await tester.tap(find.text('书库'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(edition.title).first);
  await _until(tester, () => find.byTooltip('阅读菜单').evaluate().isNotEmpty);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
});

Future<void> _shugeDownload(WidgetTester tester) => _withServices((
  services,
) async {
  final module = services.publications;
  await module.workflow.initialize();
  final sources = await module.discovery.sources();
  for (final status in sources) {
    if (status.enabled) await module.discovery.setEnabled(status.source, false);
  }
  final source = sources
      .singleWhere((status) => status.source.id == 'shuge-open')
      .source;
  await module.discovery.setEnabled(source, true);
  final browsed = await module.discovery
      .search('', CancellationToken(), maxPages: 1)
      .toList();
  expect(browsed.single.problem, isNull);
  expect(browsed.single.editions, isNotEmpty);
  final matches = await module.discovery
      .search('鲁班木经匠家镜', CancellationToken(), maxPages: 1)
      .toList();
  expect(matches.single.problem, isNull);
  final edition = matches.single.editions.singleWhere(
    (edition) =>
        edition.candidates.any((candidate) => candidate.fileId == 'SJ00000771'),
  );
  expect(edition.license, 'CC BY 4.0');
  expect(edition.candidates.single.bytes, 56834720);
  await _fetchAndOpen(
    tester,
    services,
    edition,
    PublicationFormat.pdf,
    expectedDigest:
        'bfadba08c2314f05b76d56f6b4953ff7ba5d0dc9f4ff4044e204eaa027017183',
    expectedText: false,
    downloadTimeout: const Duration(minutes: 4),
  );
});

Future<void> _useOnlyBuiltIn(AppServices services, String sourceId) async {
  final module = services.publications;
  await module.workflow.initialize();
  final sources = await module.discovery.sources();
  for (final status in sources) {
    final enabled = status.source.id == sourceId;
    if (enabled != status.enabled) {
      await module.discovery.setEnabled(status.source, enabled);
    }
  }
}

Future<void> _openStaxDownload(WidgetTester tester) => _withServices((
  services,
) async {
  final module = services.publications;
  await _useOnlyBuiltIn(services, openStaxSource);
  final browsed = await module.discovery
      .search('', CancellationToken(), maxPages: 1)
      .toList();
  expect(browsed.single.problem, isNull);
  expect(browsed.single.editions, isNotEmpty);
  final matches = await module.discovery
      .search('979-8-90095-013-6', CancellationToken())
      .toList();
  expect(matches.single.problem, isNull);
  final edition = matches.single.editions.single;
  expect(edition.title, 'Business Law I Essentials 2e');
  expect(edition.license, 'CC BY-NC-SA 4.0');
  expect(edition.candidates.single.link.host, 'assets.openstax.org');
  final authors = await module.discovery
      .search('Mirande Valbrune', CancellationToken())
      .toList();
  expect(authors.single.editions.map((item) => item.id), contains(edition.id));
  await _fetchAndOpen(
    tester,
    services,
    edition,
    PublicationFormat.pdf,
    expectedDigest:
        '6e7b5db71416d923ae0007154edad4288c98f8efcb2f93870fb6e4ab31baad4f',
  );
});

Future<void> _tadokuDownload(WidgetTester tester) =>
    _withServices((services) async {
      final module = services.publications;
      await _useOnlyBuiltIn(services, tadokuSource);
      final browsed = await module.discovery
          .search('', CancellationToken(), maxPages: 1)
          .toList();
      expect(browsed.single.problem, isNull);
      expect(browsed.single.editions, isNotEmpty);
      final matches = await module.discovery
          .search('花と色', CancellationToken(), maxPages: 1)
          .toList();
      expect(matches.single.problem, isNull);
      final edition = matches.single.editions.singleWhere(
        (item) => item.page?.path == '/japanese/book/2746/',
      );
      expect(edition.license, 'CC BY-NC-ND 4.0');
      expect(
        edition.candidates.single.link.path,
        endsWith('w0001e-hanatoiro-v2.pdf'),
      );
      await _fetchAndOpen(
        tester,
        services,
        edition,
        PublicationFormat.pdf,
        expectedDigest:
            '5896fa9a4e6af50bb01c222352c4469863bde5fed83c424a9423ddd5008f412a',
      );
    });

Future<void> _publicDirectory(String id, String host) => _withServices((
  services,
) async {
  final discovery = services.publications.discovery;
  await _useOnlyBuiltIn(services, id);
  final browsed = await discovery
      .search('', CancellationToken(), maxPages: 1)
      .toList();
  expect(browsed.single.problem, isNull);
  final edition = browsed.single.editions.first;
  expect(edition.page?.host, host);
  expect(browsed.single.editions.expand((item) => item.candidates), isEmpty);
  final matches = await discovery
      .search(edition.title, CancellationToken(), maxPages: 1)
      .toList();
  expect(matches.single.problem, isNull);
  expect(matches.single.editions.map((item) => item.id), contains(edition.id));
  expect(matches.single.editions.expand((item) => item.candidates), isEmpty);
});

Future<void> _remoteCatalogueDiscovery(String source) => _withServices((
  services,
) async {
  final discovery = services.publications.discovery;
  await _useOnlyBuiltIn(services, source);
  final browsed = await discovery
      .search('', CancellationToken(), maxPages: 1)
      .toList();
  expect(browsed.single.problem, isNull);
  expect(browsed.single.editions, isNotEmpty);
  expect(browsed.single.editions.expand((item) => item.candidates), isEmpty);
});

Future<void> _remoteCatalogueSearch(String source, String query, Uri page) =>
    _withServices((services) async {
      final discovery = services.publications.discovery;
      await _useOnlyBuiltIn(services, source);
      final matches = await discovery
          .search(query, CancellationToken(), maxPages: 1)
          .toList();
      expect(matches.single.problem, isNull);
      expect(matches.single.editions.map((item) => item.page), contains(page));
      expect(
        matches.single.editions.expand((item) => item.candidates),
        isEmpty,
      );
    });

Future<void> _openLogicProjectDownload(WidgetTester tester) =>
    _withServices((services) async {
      final module = services.publications;
      await module.workflow.initialize();
      final name = openLogicProjectRule['name'] as String;
      await module.discovery.saveConfig(jsonEncode(openLogicProjectRule));
      final source = (await module.discovery.sources())
          .singleWhere((item) => item.source.name == name)
          .source;
      expect(source.toSpec()['version'], 2);
      await module.discovery.setEnabled(source, true);
      final discoveries = await module.discovery
          .search('', CancellationToken(), maxPages: 1)
          .toList();
      expect(discoveries.single.problem, isNull);
      expect(discoveries.single.editions.length, greaterThanOrEqualTo(6));
      debugPrint('Open Logic Project catalogue returned six official editions');
      final matches = await module.discovery
          .search('Set Theory: An Open Introduction', CancellationToken())
          .toList();
      expect(matches.single.problem, isNull);
      final edition = matches.single.editions.single;
      expect(
        edition.candidates.single.link,
        Uri.https('st.openlogicproject.org', '/settheory-screen.pdf'),
      );
      await _fetchAndOpen(
        tester,
        services,
        edition,
        PublicationFormat.pdf,
        expectedDigest: null,
      );
    });

Future<void> _greenTeaPressDownload(WidgetTester tester) => _withServices((
  services,
) async {
  final module = services.publications;
  await module.workflow.initialize();
  final raw = jsonEncode(greenTeaPressRule);
  await module.discovery.saveConfig(raw);
  final source = (await module.discovery.sources())
      .singleWhere(
        (item) => item.source.name == 'Green Tea Press · Think Python 2e',
      )
      .source;
  expect(source.toSpec()['version'], 2);
  await module.discovery.setEnabled(source, true);
  final updates = await module.discovery
      .search('Think Python', CancellationToken(), maxPages: 1)
      .toList();
  final result = updates.singleWhere((item) => item.source.id == source.id);
  expect(result.problem, isNull);
  final edition = result.editions.singleWhere(
    (item) => item.title.startsWith('Think Python'),
  );
  final candidate = edition.candidates.single;
  expect(candidate.link.host, 'greenteapress.com');
  expect(candidate.link.path, '/thinkpython2/thinkpython2.pdf');
  const expected =
      '6033000bac3f9268ad75ee041bf8e5d9a3bc8a33bb156399cbd014918cb59f94';
  await _fetchAndOpen(
    tester,
    services,
    edition,
    PublicationFormat.pdf,
    expectedDigest: expected,
  );
  await tester.pumpWidget(_publicationApp(services));
  await _until(tester, () => find.text('书库').evaluate().isNotEmpty);
  await tester.tap(find.text('书库'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(edition.title).first);
  await _until(tester, () => find.byType(RichReaderPage).evaluate().isNotEmpty);
  await _until(tester, () => find.byTooltip('阅读菜单').evaluate().isNotEmpty);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
});

Future<void> _catalogueShare(WidgetTester tester, _CatalogueSample sample) =>
    _withServices((services) async {
      final module = services.publications;
      await module.discovery.saveConfig(
        jsonEncode({
          'version': 1,
          'kind': 'htmlSearch',
          'name': 'Shuge QA',
          'endpoint': 'https://www.shuge.org/meet/topic/${sample.topic}/',
          'hosts': ['pan.quark.cn'],
          'rows': 'html',
          'queryParameter': 'zp_query',
          'pageParameter': 'zp_page',
          'field': {
            'title': 'title',
            'pdf': '.post-${sample.post} .bbp-reply-content',
          },
        }),
      );
      final source = (await module.discovery.sources())
          .singleWhere((item) => item.source.configurable)
          .source;
      await module.discovery.setEnabled(source, true);
      final editions = await module.discovery
          .search(sample.query, CancellationToken())
          .expand((update) => update.editions)
          .toList();
      final edition = editions.single;
      expect(
        edition.candidates.single.link,
        Uri.https('pan.quark.cn', sample.sharePath),
      );
      final cancelled = await module.workflow.acquireFromCatalog(
        edition,
        PublicationFormat.pdf,
        (_) async => null,
      );
      expect(cancelled, isNull);
      expect(await module.store.tasks(), isEmpty);
      final id = (await module.workflow.acquireFromCatalog(
        edition,
        PublicationFormat.pdf,
        (candidate) async {
          final access = candidate.publishedAccess!;
          expect(access.code, isNotNull);
          expect(access.needsConfirmation, isFalse);
          final files = await module.workflow.inspectSourceShare(
            candidate,
            access.code,
            CancellationToken(),
          );
          expect(await module.store.tasks(), isEmpty);
          return (
            file: files.singleWhere((file) => file.bytes == sample.bytes),
            code: access.code,
          );
        },
      ))!;
      final task = (await module.store.task(id))!;
      expect(task.candidate.fileId, isNotNull);
      expect(task.candidate.sharedFileName, isNotEmpty);
      expect(task.candidate.link.hasQuery, isFalse);
      await _verifyDownloadedBook(
        tester,
        services,
        id,
        expectedDigest: sample.digest,
        expectedText: false,
        downloadTimeout: const Duration(minutes: 3),
      );
    });

Future<void> _publicShareDownload(
  WidgetTester tester,
  String share,
  PublicationFormat format,
  int expectedBytes,
  String digest, {
  String? shareCode,
  bool expectedText = true,
  Duration downloadTimeout = _downloadTimeout,
}) => _withServices((services) async {
  final module = services.publications;
  final link = Uri.parse(share);
  await module.workflow.initialize();
  if (shareCode != null) {
    await expectLater(
      module.shares.inspect(link, null, CancellationToken()),
      throwsA(
        isA<PublicationFailure>().having(
          (error) => error.problem,
          'problem',
          PublicationProblem.shareCode,
        ),
      ),
    );
  }
  final files = await module.shares.inspect(
    link,
    shareCode,
    CancellationToken(),
  );
  final matching =
      files
          .where(
            (file) =>
                file.format == format &&
                (expectedBytes == 0 || file.bytes == expectedBytes) &&
                module.library.policy.textAllowed(file.name),
          )
          .toList()
        ..sort((a, b) => a.bytes!.compareTo(b.bytes!));
  expect(matching, isNotEmpty);
  final file = matching.first;
  final id = await module.workflow.addSharedFile(link, file, code: shareCode);
  expect((await module.store.task(id))?.candidate.sharedFileName, file.name);
  await _verifyDownloadedBook(
    tester,
    services,
    id,
    expectedDigest: digest.isEmpty ? null : digest,
    expectedText: expectedText,
    downloadTimeout: downloadTimeout,
  );
});

Future<void> _fetchAndOpen(
  WidgetTester tester,
  AppServices services,
  PublicationEdition edition,
  PublicationFormat format, {
  required String? expectedDigest,
  String? shareCode,
  bool expectedText = true,
  Duration downloadTimeout = _downloadTimeout,
}) async {
  final module = services.publications;
  final id = await module.workflow.add(edition, format, shareCode: shareCode);
  await _verifyDownloadedBook(
    tester,
    services,
    id,
    expectedDigest: expectedDigest,
    expectedText: expectedText,
    downloadTimeout: downloadTimeout,
  );
}

Future<void> _verifyDownloadedBook(
  WidgetTester tester,
  AppServices services,
  String id, {
  required String? expectedDigest,
  bool expectedText = true,
  Duration downloadTimeout = _downloadTimeout,
}) async {
  final module = services.publications;
  final task = await _downloaded(
    tester,
    services,
    id,
    timeout: downloadTimeout,
  );
  final format = task.candidate.format;
  expect(task.state, AcquisitionState.downloaded, reason: task.problem?.label);
  final digest = await publicationFileDigest(
    module.workflow.transfer.part(id),
    CancellationToken(),
  );
  if (expectedDigest != null) expect(digest, expectedDigest);
  await module.workflow.finish(task);
  expect((await module.store.task(id))?.state, AcquisitionState.complete);
  final holding = (await module.library.holdings()).singleWhere(
    (item) => item.digest == digest,
  );
  final opened = await module.library.open(holding, CancellationToken());
  try {
    expect(opened.admission.chapters, isNotEmpty);
    expect(opened.admission.hasText, expectedText);
    if (format == PublicationFormat.pdf) {
      final pdf = await PdfDocument.openFile(opened.file.path);
      try {
        final image = await pdf.pages.first.render(width: 300, height: 300);
        expect(image, isNotNull);
        image?.dispose();
      } finally {
        await pdf.dispose();
      }
    }
  } finally {
    await module.space.unlease(opened.lease);
  }
  debugPrint(
    'Publication ${Platform.operatingSystem} ${task.candidate.link.host} '
    '$format ${task.received} $digest ${opened.admission.chapters.length} sections',
  );
}

Future<void> _withServices(
  Future<void> Function(AppServices) run, {
  bool allowPrivate = false,
}) async {
  final parent = Platform.isAndroid
      ? await getTemporaryDirectory()
      : Directory.systemTemp;
  final root = await parent.createTemp('zero-publications-');
  final services = AppServices.scoped(
    root,
    AppDatabase(File('${root.path}/zero-player.sqlite')),
    allowPrivateNetworks: allowPrivate,
  );
  try {
    await services.supervision.load();
    await services.settings.load();
    if (!_online) {
      final discovery = services.publications.discovery;
      for (final entry in (await discovery.sources()).where((e) => e.enabled)) {
        await discovery.setEnabled(entry.source, false);
      }
    }
    await run(services);
  } finally {
    if (Platform.isAndroid) {
      // Allow the foreground service to release this test's temporary database.
      await Future<void>.delayed(const Duration(milliseconds: 850));
    }
    await services.close();
    if (Platform.isWindows &&
        const String.fromEnvironment('PROJECT_ROOT').isNotEmpty) {
      debugPrint('Publication test evidence retained in ${root.path}');
    } else {
      await root.delete(recursive: true);
    }
  }
}

Future<void> _androidDownload(
  AppServices services, {
  required bool timeout,
}) async {
  final module = services.publications;
  final bytes = samplePdf();
  final fixture = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var connections = 0;
  fixture.listen((request) async {
    final first = connections++ == 0;
    await _sendTestPdf(request, bytes, slow: timeout && first);
  });
  try {
    final link = Uri.parse('http://127.0.0.1:${fixture.port}/fixture.pdf');
    final edition = PublicationEdition(
      id: publicationId('fixture'),
      title: 'Background fixture',
      candidates: [
        AcquisitionCandidate(
          source: 'manual',
          link: link,
          format: PublicationFormat.pdf,
        ),
      ],
    );
    final id = await module.workflow.add(edition, PublicationFormat.pdf);
    final active = await _taskWhen(
      services,
      id,
      (task) => task.state == AcquisitionState.downloading && task.received > 0,
    );
    if (timeout) {
      debugPrint('Publication Android timeout transfer running under dataSync');
      await _recoverAfterTimeout(services, id);
    } else {
      await module.workflow.pause(active);
      final paused = await _taskWhen(
        services,
        id,
        (task) => task.state == AcquisitionState.paused,
      );
      expect(paused.received, greaterThan(0));
      await module.workflow.start(id);
    }
    final complete = await _taskWhen(
      services,
      id,
      (task) => task.state == AcquisitionState.downloaded,
    );
    expect(
      complete.state,
      AcquisitionState.downloaded,
      reason: complete.problem?.name,
    );
    expect(await module.workflow.transfer.part(id).readAsBytes(), bytes);
    await module.workflow.finish(complete);
    expect((await module.library.holdings()).single.resident, isTrue);
    debugPrint('Publication Android PDF imported after dataSync transfer');
  } finally {
    await fixture.close(force: true);
  }
}

Future<void> _sameEdition(AppServices services) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final paths = <String>[];
  final bytes = samplePdf();
  server.listen((request) async {
    final path = request.uri.path;
    paths.add(path);
    if (path == '/blocked.pdf') {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    request.response.headers.contentType = ContentType('application', 'pdf');
    request.response.contentLength = bytes.length;
    request.response.add(bytes);
    await request.response.close();
  });

  PublicationEdition edition(String path, String translator) =>
      PublicationEdition(
        id: publicationId(path),
        title: 'Reference workbook',
        author: 'Taylor',
        isbn: '9781491939369',
        language: 'zh',
        edition: '2',
        translator: translator,
        candidates: [
          AcquisitionCandidate(
            source: 'manual',
            link: Uri.parse('http://127.0.0.1:${server.port}$path'),
            format: PublicationFormat.pdf,
            bytes: bytes.length,
          ),
        ],
      );
  final module = services.publications;
  try {
    final id = await module.workflow.add(
      edition('/blocked.pdf', 'Chen'),
      PublicationFormat.pdf,
      alternatives: [
        edition('/different.pdf', 'Wang'),
        edition('/confirmed.pdf', 'Chen'),
      ],
    );
    final completed = await _taskWhen(
      services,
      id,
      (task) => task.state == AcquisitionState.downloaded,
    );
    expect(completed.failures.single.problem, PublicationProblem.challenge);
    expect(completed.candidate.link.path, '/confirmed.pdf');
    expect(paths.toSet(), {'/blocked.pdf', '/confirmed.pdf'});
    await module.workflow.finish(completed);
    expect((await module.library.holdings()).single.edition.translator, 'Chen');
  } finally {
    await server.close(force: true);
  }
}

Future<void> _sendTestPdf(
  HttpRequest request,
  List<int> bytes, {
  required bool slow,
}) async {
  final response = request.response;
  response.bufferOutput = false;
  response.headers.contentType = ContentType('application', 'pdf');
  response.contentLength = bytes.length;
  final chunk = slow ? 8 : 64;
  try {
    for (var index = 0; index < bytes.length; index += chunk) {
      response.add(
        bytes.sublist(index, (index + chunk).clamp(0, bytes.length)),
      );
      await response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 450));
    }
    await response.close();
  } on IOException {
    // A pause cancels the stream.
  }
}

Future<void> _recoverAfterTimeout(AppServices services, String id) async {
  final module = services.publications;
  final paused = await _taskWhen(
    services,
    id,
    (task) =>
        task.state == AcquisitionState.paused &&
        task.problem == PublicationProblem.systemWait,
  );
  expect(paused.received, greaterThan(0));
  debugPrint('Publication Android dataSync budget exhausted');
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  await expectLater(
    module.workflow.start(id),
    throwsA(
      isA<PublicationFailure>().having(
        (error) => error.problem,
        'problem',
        PublicationProblem.systemWait,
      ),
    ),
  );
  debugPrint(
    'Publication Android denied restart before returning to foreground',
  );
  final binding = WidgetsBinding.instance;
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (binding.lifecycleState != AppLifecycleState.resumed &&
      DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
  expect(binding.lifecycleState, AppLifecycleState.resumed);
  await module.workflow.start(id);
  await _taskWhen(
    services,
    id,
    (task) =>
        task.state == AcquisitionState.resolving ||
        task.state == AcquisitionState.downloading ||
        task.state == AcquisitionState.downloaded,
    afterGeneration: paused.generation,
  );
}

Future<AcquisitionTask> _taskWhen(
  AppServices services,
  String id,
  bool Function(AcquisitionTask) accepts, {
  int? afterGeneration,
  Duration timeout = const Duration(seconds: 35),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final task = await services.publications.store.task(id);
    if (task != null &&
        (afterGeneration == null || task.generation > afterGeneration)) {
      if (accepts(task)) return task;
      if (task.state == AcquisitionState.failed) {
        throw StateError('Android fixture task failed: ${task.problem?.name}');
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }
  final latest = await services.publications.store.task(id);
  throw StateError(
    'Android fixture did not reach the expected state: ${latest?.state.name}',
  );
}

Future<AcquisitionTask> _downloaded(
  WidgetTester tester,
  AppServices services,
  String id, {
  Duration timeout = _downloadTimeout,
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    final task = await services.publications.store.task(id);
    if (task != null &&
        (task.state == AcquisitionState.downloaded ||
            task.state == AcquisitionState.failed)) {
      return task;
    }
    await tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 170));
  }
  final last = await services.publications.store.task(id);
  throw StateError(
    'Publication download did not settle: ${last?.state.name} '
    '${last?.received}/${last?.total}, ${last?.problem?.name}',
  );
}

Future<void> _until(WidgetTester tester, bool Function() check) async {
  final end = DateTime.now().add(const Duration(seconds: 15));
  while (!check() && DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  expect(check(), isTrue);
}

Future<void> _measureSamples() async {
  final token = CancellationToken();
  final results = <Map<String, Object?>>[];
  const sizes = [129, 511, 512];
  for (final size in sizes) {
    final path = File('$_evidence/fixture-$size.pdf');
    final startRss = ProcessInfo.currentRss;
    final elapsed = Stopwatch()..start();
    final digest = await publicationFileDigest(path, token);
    final hashMs = elapsed.elapsedMilliseconds;
    final data = await admitPublication(
      path,
      PublicationFormat.pdf,
      'sample.pdf',
      token,
      authorize: (_) {},
    );
    final admission = elapsed.elapsedMilliseconds;
    expect(data.chapters, hasLength(1));
    expect(data.hasText, size != 511);
    elapsed.reset();
    final pdf = await PdfDocument.openFile(path.path);
    try {
      final image = await pdf.pages.first.render(width: 400, height: 500);
      expect(image, isNotNull);
      image!.dispose();
      results.add({
        'bytes': await path.length(),
        'sha256': digest,
        'hashMs': hashMs,
        'admissionMs': admission,
        'renderMs': elapsed.elapsedMilliseconds,
        'startRss': startRss,
        'peakRss': ProcessInfo.maxRss,
        'hasText': data.hasText,
      });
    } finally {
      await pdf.dispose();
    }
  }
  await expectLater(
    admitPublication(
      File('$_evidence/fixture-over.pdf'),
      PublicationFormat.pdf,
      'over.pdf',
      token,
      authorize: (_) {},
    ),
    throwsA(isA<PublicationFailure>()),
  );
  final locked = File('$_evidence/fixture-locked.pdf');
  await expectLater(
    admitPublication(
      locked,
      PublicationFormat.pdf,
      'locked.pdf',
      token,
      authorize: (_) {},
      password: 'wrong',
    ),
    throwsA(
      isA<PublicationFailure>().having(
        (value) => value.problem,
        'problem',
        PublicationProblem.pdfPassword,
      ),
    ),
  );
  expect(
    (await admitPublication(
      locked,
      PublicationFormat.pdf,
      'locked.pdf',
      token,
      authorize: (_) {},
      password: 'print-key',
    )).hasText,
    isTrue,
  );
  final evidence = const JsonEncoder.withIndent('  ').convert(results);
  debugPrint('Publication large-PDF measurements $evidence');
  await File(
    '$_evidence/pdf-${Platform.operatingSystem}.json',
  ).writeAsString(evidence);
  await _encryptedArchives(token, _evidence);
}

Future<void> _measurePublisherPdf(WidgetTester tester) => _withServices((
  services,
) async {
  final module = services.publications;
  final file = File(_publisherPdf);
  final bytes = await file.length();
  expect(bytes, inInclusiveRange((128 << 20) + 1, 512 << 20));
  if (_publisherBlocked) {
    await expectLater(
      module.workflow.importLocal(file),
      throwsA(
        isA<PublicationFailure>().having(
          (failure) => failure.problem,
          'problem',
          PublicationProblem.blocked,
        ),
      ),
    );
    expect(await module.library.holdings(), isEmpty);
    await _measurePublisherEngine(file, bytes);
    return;
  }
  final start = ProcessInfo.currentRss;
  final watch = Stopwatch()..start();
  final digest = await module.workflow.importLocal(file);
  final importMs = watch.elapsedMilliseconds;
  final holding = (await module.library.holdings()).single;
  final opened = await module.library.open(holding, CancellationToken());
  final openMs = watch.elapsedMilliseconds - importMs;
  expect(opened.admission.hasText, isTrue);
  final pdf = await PdfDocument.openFile(opened.file.path);
  try {
    expect(pdf.pages.length, greaterThan(100));
    watch.reset();
    final cover = await pdf.pages.first.render(width: 400, height: 500);
    expect(cover, isNotNull);
    cover!.dispose();
    debugPrint(
      'Publication press PDF $bytes B ${pdf.pages.length} pages '
      '$digest importMs=$importMs openMs=$openMs '
      'coverMs=${watch.elapsedMilliseconds} rssStart=$start peak=${ProcessInfo.maxRss}',
    );
  } finally {
    await pdf.dispose();
    await module.space.unlease(opened.lease);
  }
  if (_publisherQuery.isNotEmpty) {
    await verifyPublisherPdfSearch(
      tester,
      _publicationApp(services),
      title: holding.edition.title,
      pages: opened.admission.chapters.length,
      query: _publisherQuery,
      hits: _publisherHits,
      firstPage: _publisherFirstPage,
      nextPage: _publisherNextPage,
    );
  }
});

Future<void> _measurePublisherEngine(File file, int bytes) async {
  final start = ProcessInfo.currentRss;
  final elapsed = Stopwatch()..start();
  // Exercise the engine independently after the real application has rejected
  // this file. This measurement has no application database or publication step.
  final admission = await admitPublication(
    file,
    PublicationFormat.pdf,
    'Publisher sample.pdf',
    CancellationToken(),
    authorize: (_) {},
  );
  final scanMs = elapsed.elapsedMilliseconds;
  expect(admission.hasText, isTrue);
  expect(admission.chapters.length, greaterThan(100));
  final pdf = await PdfDocument.openFile(file.path);
  try {
    elapsed.reset();
    final cover = await pdf.pages.first.render(width: 400, height: 500);
    expect(cover, isNotNull);
    cover!.dispose();
    debugPrint(
      'Publication publisher engine-only $bytes B ${pdf.pages.length} pages '
      'scanMs=$scanMs coverMs=${elapsed.elapsedMilliseconds} '
      'rssStart=$start peak=${ProcessInfo.maxRss}',
    );
  } finally {
    await pdf.dispose();
  }
}

Future<void> _retainedZip(AppServices services) async {
  final module = services.publications;
  await module.workflow.initialize();
  final first = samplePdf();
  final second = [...first, ...utf8.encode('\n% PDF fixture variant\n')];
  final archive = Archive()
    ..addFile(ArchiveFile.bytes('First.pdf', first))
    ..addFile(ArchiveFile.bytes('Second.pdf', second));
  final bytes = ZipEncoder().encode(archive);
  final edition = PublicationEdition(
    id: publicationId('archive-ownership'),
    title: 'Reference documents',
  );
  final id = await module.store.addTask(edition, [
    AcquisitionCandidate(
      source: 'manual',
      link: Uri.https('test.example', '/reference.zip'),
      format: PublicationFormat.zip,
    ),
  ]);
  final owner = (await module.store.claim(id, 'native-archive-fixture'))!;
  final path = module.workflow.transfer.part(id);
  await path.parent.create(recursive: true);
  await module.space.reserve(id, bytes.length);
  await path.writeAsBytes(bytes, flush: true);
  await module.space.release(id, used: bytes.length);
  await module.store.updateTask(
    owner,
    AcquisitionState.downloaded,
    received: bytes.length,
  );
  final downloaded = (await module.store.task(id))!;
  final entries = await module.workflow.downloadedEntries(downloaded);
  expect(entries.map((item) => item.path), ['First.pdf', 'Second.pdf']);
  await module.workflow.finish(
    downloaded,
    entry: entries.first,
    retainArchive: true,
  );
  final completed = (await module.store.task(id))!;
  expect(completed.retainedArchive, isTrue);
  await module.space.reconcile();
  expect(await path.readAsBytes(), bytes);
  await expectLater(
    module.workflow.removeTask(completed),
    throwsA(
      isA<PublicationFailure>().having(
        (error) => error.problem,
        'problem',
        PublicationProblem.inUse,
      ),
    ),
  );
  await module.workflow.importRetainedArchive(completed, entries.last);
  final holdings = await module.library.holdings();
  expect(holdings.where((book) => book.resident), hasLength(2));
  await module.workflow.deleteRetainedArchive(completed);
  expect(await path.exists(), isFalse);
  expect((await module.store.task(id))?.retainedArchive, isFalse);
  expect((await module.space.usage()).used, first.length + second.length);
}

Future<void> _encryptedArchives(CancellationToken token, String source) async {
  final parent = Platform.isAndroid
      ? await getTemporaryDirectory()
      : Directory.systemTemp;
  final temp = await parent.createTemp('publication-zip-native-');
  try {
    for (final (name, key) in [
      ('aes.zip', 'zip-key'),
      ('aes-utf8.zip', '汉字'),
      ('zipcrypto.zip', 'zip-key'),
    ]) {
      final zip = File('$source/$name');
      final item = (await PublicationZip.inspect(zip)).single;
      expect(item.encrypted, isTrue);
      final out = File('${temp.path}/decrypted.pdf');
      await expectLater(
        PublicationZip.extract(zip, item, out, token, password: 'wrong'),
        throwsA(isA<PublicationFailure>()),
      );
      expect(await out.exists(), isFalse);
      await PublicationZip.extract(zip, item, out, token, password: key);
      expect(
        await out.readAsBytes(),
        await File('$source/fixture.pdf').readAsBytes(),
      );
      await out.delete();
      debugPrint('Publication ZIP $name validated, including wrong password');
    }
    final archive = await File('$source/aes.zip').readAsBytes();
    final local = ByteData.sublistView(archive);
    final start =
        30 +
        local.getUint16(26, Endian.little) +
        local.getUint16(28, Endian.little);
    final size = local.getUint32(18, Endian.little);
    archive[start + size - 1] ^= 1;
    final damaged = await File(
      '${temp.path}/tampered.zip',
    ).writeAsBytes(archive);
    final entry = (await PublicationZip.inspect(damaged)).single;
    await expectLater(
      PublicationZip.extract(
        damaged,
        entry,
        File('${temp.path}/bad.pdf'),
        token,
        password: 'zip-key',
      ),
      throwsA(
        isA<PublicationFailure>().having(
          (error) => error.problem,
          'problem',
          PublicationProblem.invalid,
        ),
      ),
    );
    await damaged.writeAsBytes(archive.sublist(0, archive.length - 1));
    await expectLater(
      PublicationZip.inspect(damaged),
      throwsA(isA<PublicationFailure>()),
    );
  } finally {
    await temp.delete(recursive: true);
  }
}
