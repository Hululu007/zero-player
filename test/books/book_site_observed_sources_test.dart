import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/application/book_site_checks.dart';
import 'package:zero_player/features/books/application/book_site_monitor.dart';
import 'package:zero_player/features/books/data/book_site_inspection.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/data/book_site_script_clues.dart';
import 'package:zero_player/features/books/data/book_source_risk_store.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/data/books_repository.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/legado_source.dart';

import '../../test_support/verified_temp_directory.dart';

const _asset = 'assets/catalogs/books/verified.json';
const _domainUpdatesAsset =
    'assets/catalogs/books/reviewed-domain-updates.json';
const _observed = 'books_site_observed_fingerprint:';
const _check = 'books_site_check:';
const _supervised = 'books_supervised_site_check:';
const _clue = BookPageScriptClue.crossOriginRedirect;
const _sample = BookSiteInspection(
  BookSiteFinding.sampled,
  scriptReview: BookPageScriptReview(
    coverage: BookPageScriptCoverage.sampled,
    clues: {_clue},
  ),
);

Map<String, Object> _configuration(
  String name, {
  String host = 'site.example',
}) => {
  'name': name,
  'kind': 'text',
  'format': 'feed',
  'url': 'https://$host/feed',
  'sourceKey': 'fixture:site-observed-version',
};

BookSource _source(String name, {String host = 'site.example'}) =>
    BookSource.fromJson(_configuration(name, host: host), builtin: true);

BookSourceEntry _entry(BookSource source) =>
    BookSourceEntry(source, true, false, source.group, '', null);

Map<String, Object?> _oldLegadoConfiguration(BookSource source, Map raw) {
  final info = raw['ruleBookInfo'] as Map;
  final content = raw['ruleContent'] as Map;
  return {
    ...source.toJson(),
    'legado': {
      ...source.legado!.toJson(),
      'rules': {
        ...source.legado!.rules,
        'infoInit': info['init'],
        'infoTitle': info['name'],
        'infoAuthor': info['author'],
        'infoDescription': info['intro'],
        'infoCover': info['coverUrl'],
        'infoCategory': info['kind'],
        'infoLatest': info['lastChapter'],
        'nextContent': content['nextContentUrl'],
      },
    },
  };
}

Map<String, Object> _observedValue(BookSource source) => {
  'fingerprint': bookSourceCheckFingerprint(source),
  'inspectionRevision': bookSiteInspectionRevision,
};

void _assets(List<Map<String, Object>> sources) {
  rootBundle.evict(_asset);
  rootBundle.evict(_domainUpdatesAsset);
  final data = Uint8List.fromList(utf8.encode(jsonEncode(sources)));
  final updates = Uint8List.fromList(utf8.encode('{"updates":[]}'));
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler('flutter/assets', (message) async {
        final key = utf8.decode(Uint8List.sublistView(message!));
        if (key == _domainUpdatesAsset) return ByteData.sublistView(updates);
        return key == _asset ? ByteData.sublistView(data) : null;
      });
}

final class _Fixture {
  _Fixture(this.temp);
  final VerifiedTempDirectory temp;
  final _services = <AppServices>[];

  static Future<_Fixture> create() async =>
      _Fixture(await VerifiedTempDirectory.create('book-site-observed-'));

  Future<AppServices> open() async {
    final db = AppDatabase(File('${temp.directory.path}/site.sqlite'));
    final services = AppServices.scoped(temp.directory, db);
    _services.add(services);
    await services.supervision.load();
    await services.settings.load();
    return services;
  }

  Future<void> close() async {
    for (final service in _services.reversed) {
      await service.close();
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
    rootBundle.evict(_asset);
    rootBundle.evict(_domainUpdatesAsset);
    await temp.delete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'running A, B, A invalidates both checks and keeps risk and clues',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final a = _source('版本 A');
      final b = _source('版本 B');
      expect(a.id, b.id);
      _assets([_configuration('版本 A')]);
      final first = await fixture.open();
      final repo = first.books;
      final entry = (await repo.sources(
        BookKind.text,
        enabledOnly: true,
      )).singleWhere((value) => value.source.id == a.id);
      final checks = BookSiteChecks(repo, inspect: (_, _) async => _sample);
      final summary = await checks.run([entry], CancellationToken());
      expect(summary.checked, 1);
      final firstRevision = await repo.store.siteRevisions.get(a.id);
      expect(firstRevision, isNotNull);
      final saved = await repo.store.read('$_check${a.id}');
      expect(await repo.store.read('$_observed${a.id}'), _observedValue(a));
      // A supervised sample is deliberately independent but has the same token.
      await repo.store.write('$_supervised${a.id}', saved);
      final risk = BookSourceAssessment(
        sourceId: a.id,
        name: a.name,
        host: a.endpoint.host,
        adult: true,
        quarantined: true,
        adultHost: true,
        quarantinedHost: true,
        version: 7,
      );
      await repo.riskStore.write(risk);
      await first.close();

      _assets([_configuration('版本 B')]);
      final middle = await fixture.open();
      await middle.settings.update({'backgroundProbe': false});
      // start() records the effective version without waiting for the timer or
      // issuing a request, even when no page or scan is opened.
      middle.bookSiteMonitor.start();
      await middle.books.ensureSiteObservations();
      final middleRevision = await middle.books.store.siteRevisions.get(a.id);
      expect(middleRevision, isNot(firstRevision));
      expect(
        await middle.books.store.read('$_observed${a.id}'),
        _observedValue(b),
      );
      expect(await middle.books.store.read('$_supervised${a.id}'), saved);
      final supervised = BookSiteCheck.fromJson(
        await middle.books.store.read('$_supervised${a.id}'),
        b,
        currentRevision: middleRevision,
        requireRevision: true,
      )!;
      expect(supervised.inspection.finding, BookSiteFinding.sourceChanged);
      expect(supervised.historicalScriptClues.keys, contains(_clue));
      expect((await middle.books.riskStore.get(a.id))!.version, 7);
      await middle.close();

      _assets([_configuration('版本 A')]);
      final again = await fixture.open();
      await again.books.ensureSiteObservations();
      final lastRevision = await again.books.store.siteRevisions.get(a.id);
      expect(lastRevision, isNot(anyOf(firstRevision, middleRevision)));
      final stale = (await BookSiteChecks(
        again.books,
      ).load([_entry(a)]))[a.id]!;
      expect(stale.inspection.finding, BookSiteFinding.sourceChanged);
      expect(stale.isDue(DateTime.now()), isTrue);
      expect(stale.historicalScriptClues.keys, contains(_clue));
      expect(await again.books.store.read('$_check${a.id}'), saved);
      expect(await again.books.store.read('$_supervised${a.id}'), saved);
      final retained = (await again.books.riskStore.get(a.id))!;
      expect(retained.version, 7);
      expect(retained.adult, isTrue);
      expect(retained.quarantined, isTrue);
      await again.close();

      // A further unchanged launch is read-only and keeps the same generation.
      _assets([_configuration('版本 A')]);
      final unchanged = await fixture.open();
      await Future<void>.delayed(Duration.zero);
      var notifications = 0;
      final subscription = unchanged.db
          .changesFor({'app_meta'})
          .listen((_) => notifications++);
      addTearDown(subscription.cancel);
      await unchanged.books.ensureSiteObservations();
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 0);
      expect(await unchanged.books.store.siteRevisions.get(a.id), lastRevision);
    },
  );

  test(
    'startup observes a saved Legado source after its automatic rule repair',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      _assets([]);
      final archive = await File(
        'assets/catalogs/books/legado/catalog.json.bz2',
      ).readAsBytes();
      final catalog =
          jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive))) as Map;
      final raw = (catalog['records'] as List)[4760] as Map;
      final imported = parseBookSourceRecord(raw);
      final saved = _oldLegadoConfiguration(imported, raw);
      final repaired = BookSource.fromJson(saved);
      expect(
        repaired.id,
        '0723af128aa8adacd3e3a9efe03b622fa660d2f78a21b72cbe2bfe7d32ce8b75',
      );
      final oldRules = LegadoSource.fromJson(saved['legado'] as Map);
      expect(oldRules.rules['infoInit'], startsWith('@put:'));
      expect(repaired.legado!.rules['infoInit'], isEmpty);
      final oldEffective = {...repaired.toJson(), 'legado': oldRules.toJson()};
      final oldFingerprint = sha256
          .convert(utf8.encode(jsonEncode(oldEffective)))
          .toString();
      expect(oldFingerprint, isNot(bookSourceCheckFingerprint(repaired)));

      final service = await fixture.open();
      final repo = service.books;
      await repo.store.write('books_source:${repaired.id}', {
        'source': saved,
        'enabled': true,
        'favorite': true,
      });
      final revision = (await repo.store.siteRevisions.ensure({
        repaired.id,
      }))[repaired.id]!;
      await repo.store.write('$_observed${repaired.id}', {
        'fingerprint': oldFingerprint,
        'inspectionRevision': bookSiteInspectionRevision,
      });
      await repo.store.write(
        '$_check${repaired.id}',
        BookSiteCheck(
          _sample,
          DateTime.now(),
          oldFingerprint,
          sourceId: repaired.id,
          sourceHostSha256: bookSiteHostFingerprint(repaired),
          siteRevision: revision,
        ).toJson(),
      );
      await repo.ensureSiteObservations();
      expect(await repo.store.siteRevisions.get(repaired.id), isNot(revision));
      expect(
        await repo.store.read('$_observed${repaired.id}'),
        _observedValue(repaired),
      );
      final stored =
          await repo.store.read('books_source:${repaired.id}') as Map;
      expect(stored['source'], saved);
      expect(stored['enabled'], isTrue);
      expect(stored['favorite'], isTrue);
      final previous = (await BookSiteChecks(
        repo,
      ).load([_entry(repaired)]))[repaired.id]!;
      expect(previous.inspection.finding, BookSiteFinding.sourceChanged);
      expect(previous.historicalScriptClues.keys, contains(_clue));
    },
  );

  test(
    'legacy sample with no observed fingerprint migrates without losing clues',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final source = _source('旧版记录');
      _assets([_configuration('旧版记录')]);
      final service = await fixture.open();
      final store = service.books.store;
      final revision = (await store.siteRevisions.ensure({
        source.id,
      }))[source.id]!;
      final previous = BookSiteCheck(
        _sample,
        DateTime.now(),
        bookSourceCheckFingerprint(source),
        siteRevision: revision,
      );
      await store.write('$_check${source.id}', previous.toJson());
      await service.books.ensureSiteObservations();
      expect(await store.siteRevisions.get(source.id), isNot(revision));
      final migrated = (await BookSiteChecks(
        service.books,
      ).load([_entry(source)]))[source.id]!;
      expect(migrated.inspection.finding, BookSiteFinding.sourceChanged);
      expect(migrated.historicalScriptClues.keys, contains(_clue));
      expect(migrated.isDue(DateTime.now()), isTrue);

      // An explicitly contradictory host is never associated by old fingerprint.
      await store.write('$_check${source.id}', {
        ...previous.toJson(),
        'sourceHostSha256': 'not-this-host',
      });
      expect(
        await BookSiteChecks(service.books).load([_entry(source)]),
        isEmpty,
      );
    },
  );

  test(
    'legacy timeout without an observation becomes due on first migration',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final source = _source('旧版失败');
      _assets([_configuration('旧版失败')]);
      final service = await fixture.open();
      final store = service.books.store;
      final revision = (await store.siteRevisions.ensure({
        source.id,
      }))[source.id]!;
      final previous = BookSiteCheck(
        const BookSiteInspection(BookSiteFinding.timeout),
        DateTime.now(),
        bookSourceCheckFingerprint(source),
        consecutiveFailures: 1,
        siteRevision: revision,
      );
      expect(previous.isDue(DateTime.now()), isFalse);
      await store.write('$_check${source.id}', previous.toJson());
      final migrated = (await BookSiteChecks(
        service.books,
      ).load([_entry(source)]))[source.id]!;
      expect(migrated.inspection.finding, BookSiteFinding.sourceChanged);
      expect(migrated.isDue(DateTime.now()), isTrue);
      expect(await store.read('$_check${source.id}'), previous.toJson());
      expect(await store.siteRevisions.get(source.id), isNot(revision));
    },
  );

  test(
    'observation rereads a concurrent source write in its transaction',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      _assets([]);
      final service = await fixture.open();
      final repo = service.books;
      final a = BookSource.fromJson(_configuration('自定义 A'));
      final b = BookSource.fromJson(
        _configuration('自定义 B', host: 'other.example'),
      );
      await repo.store.writeImported([(source: a, previous: null)]);
      await repo.store.write(
        '$_check${a.id}',
        BookSiteCheck.after(_sample, DateTime.now(), a, null).toJson(),
      );
      await repo.store.write('$_observed${a.id}', 'damaged');
      final entered = Completer<void>();
      final release = Completer<void>();
      repo.beforeSiteObservationTransactionForTesting = () async {
        entered.complete();
        await release.future;
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final first = repo.ensureSiteObservations();
      final second = repo.ensureSiteObservations();
      expect(identical(first, second), isTrue);
      await entered.future.timeout(const Duration(seconds: 5));
      await repo.store.saveSource(a, {'source': b.toJson()});
      final writtenRevision = await repo.store.siteRevisions.get(a.id);
      release.complete();
      await Future.wait([first, second]).timeout(const Duration(seconds: 5));
      expect(await repo.store.read('$_observed${a.id}'), _observedValue(b));
      expect(await repo.store.siteRevisions.get(a.id), isNot(writtenRevision));
      expect(await BookSiteChecks(repo).load([_entry(b)]), isEmpty);
    },
  );

  test(
    'normal close waits for an already registered observation to commit',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final source = _source('快速退出');
      _assets([_configuration('快速退出')]);
      final service = await fixture.open();
      final repo = service.books;
      final oldRevision = (await repo.store.siteRevisions.ensure({
        source.id,
      }))[source.id]!;
      await repo.store.write(
        '$_check${source.id}',
        BookSiteCheck.after(_sample, DateTime.now(), source, null).toJson(),
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      repo.afterSiteObservationWriteForTesting = () async {
        entered.complete();
        await release.future;
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final observing = repo.ensureSiteObservations();
      await entered.future.timeout(const Duration(seconds: 5));
      var closed = false;
      final closing = repo.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      await expectLater(
        repo.ensureSiteObservations(),
        throwsA(isA<RequestCancelled>()),
      );
      release.complete();
      await observing.timeout(const Duration(seconds: 5));
      await closing.timeout(const Duration(seconds: 5));
      expect(await repo.store.siteRevisions.get(source.id), isNot(oldRevision));
      expect(
        await repo.store.read('$_observed${source.id}'),
        _observedValue(source),
      );
    },
  );

  test(
    'restore suspension rolls back and a later observation can retry',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final source = _source('恢复并发');
      _assets([_configuration('恢复并发')]);
      final service = await fixture.open();
      final repo = service.books;
      final revision = (await repo.store.siteRevisions.ensure({
        source.id,
      }))[source.id]!;
      await repo.store.write(
        '$_check${source.id}',
        BookSiteCheck.after(_sample, DateTime.now(), source, null).toJson(),
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      repo.afterSiteObservationWriteForTesting = () async {
        entered.complete();
        await release.future;
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final observing = expectLater(
        repo.ensureSiteObservations(),
        throwsA(isA<RequestCancelled>()),
      );
      await entered.future.timeout(const Duration(seconds: 5));
      repo.suspendSourceRisks();
      release.complete();
      await observing.timeout(const Duration(seconds: 5));
      expect(await repo.store.siteRevisions.get(source.id), revision);
      expect(await repo.store.read('$_observed${source.id}'), isNull);
      repo.afterSiteObservationWriteForTesting = null;
      await repo.resumeSourceRisks();
      await repo.ensureSiteObservations();
      expect(await repo.store.siteRevisions.get(source.id), isNot(revision));
    },
  );

  test(
    'restore ABA cancels the old transaction even if suspension already ended',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final source = _source('恢复往返');
      _assets([_configuration('恢复往返')]);
      final service = await fixture.open();
      final repo = service.books;
      final revision = (await repo.store.siteRevisions.ensure({
        source.id,
      }))[source.id]!;
      await repo.store.write(
        '$_check${source.id}',
        BookSiteCheck.after(_sample, DateTime.now(), source, null).toJson(),
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      repo.afterSiteObservationWriteForTesting = () async {
        entered.complete();
        await release.future;
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final observing = expectLater(
        repo.ensureSiteObservations(),
        throwsA(isA<RequestCancelled>()),
      );
      await entered.future.timeout(const Duration(seconds: 5));
      repo.suspendSourceRisks();
      final resuming = repo.resumeSourceRisks();
      repo.afterSiteObservationWriteForTesting = null;
      await Future<void>.delayed(Duration.zero);
      release.complete();
      await observing.timeout(const Duration(seconds: 5));
      await resuming.timeout(const Duration(seconds: 5));
      await repo.ensureSiteObservations();
      expect(await repo.store.siteRevisions.get(source.id), isNot(revision));
      expect(
        await repo.store.read('$_observed${source.id}'),
        _observedValue(source),
      );
    },
  );

  test(
    'failed initialization never returns old checks and retries cleanly',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final source = _source('写入失败');
      _assets([_configuration('写入失败')]);
      final service = await fixture.open();
      final repo = service.books;
      final revision = (await repo.store.siteRevisions.ensure({
        source.id,
      }))[source.id]!;
      await repo.store.write(
        '$_check${source.id}',
        BookSiteCheck.after(
          _sample,
          DateTime.now(),
          source,
          null,
          siteRevision: revision,
        ).toJson(),
      );
      await Future<void>.delayed(Duration.zero);
      var notifications = 0;
      final changes = service.db
          .changesFor({'app_meta'})
          .listen((_) => notifications++);
      addTearDown(changes.cancel);
      repo.afterSiteObservationWriteForTesting = () async =>
          throw StateError('fixture failure');
      await expectLater(
        BookSiteChecks(repo).load([_entry(source)]),
        throwsStateError,
      );
      expect(await repo.store.siteRevisions.get(source.id), revision);
      expect(await repo.store.read('$_observed${source.id}'), isNull);
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 0);
      repo.afterSiteObservationWriteForTesting = null;
      final checks = await BookSiteChecks(repo).load([_entry(source)]);
      expect(
        checks[source.id]!.inspection.finding,
        BookSiteFinding.sourceChanged,
      );
    },
  );

  test(
    'inspection semantics version makes old samples due without clearing risk',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final source = _source('检测版本');
      _assets([_configuration('检测版本')]);
      final service = await fixture.open();
      final repo = service.books;
      final revision = (await repo.store.siteRevisions.ensure({
        source.id,
      }))[source.id]!;
      await repo.store.write(
        '$_check${source.id}',
        BookSiteCheck.after(
          _sample,
          DateTime.now(),
          source,
          null,
          siteRevision: revision,
        ).toJson(),
      );
      await repo.store.write('$_observed${source.id}', {
        'fingerprint': bookSourceCheckFingerprint(source),
        'inspectionRevision': bookSiteInspectionRevision - 1,
      });
      await repo.riskStore.write(
        BookSourceAssessment(
          sourceId: source.id,
          name: source.name,
          host: source.endpoint.host,
          adult: true,
          quarantined: false,
          adultHost: true,
          quarantinedHost: false,
          version: 4,
        ),
      );
      await repo.ensureSiteObservations();
      expect(await repo.store.siteRevisions.get(source.id), isNot(revision));
      expect(
        await repo.store.read('$_observed${source.id}'),
        _observedValue(source),
      );
      final stale = (await BookSiteChecks(
        repo,
      ).load([_entry(source)]))[source.id]!;
      expect(stale.inspection.finding, BookSiteFinding.sourceChanged);
      expect(stale.historicalScriptClues.keys, contains(_clue));
      expect((await repo.riskStore.get(source.id))!.version, 4);
    },
  );

  test(
    'starting during restore still installs the later background timer',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      _assets([_configuration('恢复后抽查')]);
      final service = await fixture.open();
      final repo = service.books;
      final inspected = Completer<void>();
      final monitor = BookSiteMonitor(
        BookSiteChecks(
          repo,
          inspect: (_, _) async {
            if (!inspected.isCompleted) inspected.complete();
            return _sample;
          },
        ),
        service.settings,
        startDelay: const Duration(milliseconds: 100),
        interval: const Duration(hours: 1),
      );
      addTearDown(monitor.close);
      await service.settings.update({'bookSiteAutoCheck': true});
      repo.suspendSourceRisks();
      monitor.start();
      await Future<void>.delayed(Duration.zero);
      await repo.resumeSourceRisks();
      await inspected.future.timeout(const Duration(seconds: 5));
    },
  );
}
