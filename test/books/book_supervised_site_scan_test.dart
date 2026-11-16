import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/application/book_site_checks.dart';
import 'package:zero_player/features/books/application/book_site_monitor.dart';
import 'package:zero_player/features/books/data/book_site_inspection.dart';
import 'package:zero_player/features/books/data/book_site_script_clues.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/data/books_repository.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/supervision/application/supervision_controller.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

import '../../test_support/verified_temp_directory.dart';

const _password = 'test-password-123';
const _timeout = Duration(seconds: 8);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _batchLeaseSupervisedTests();

  test(
    'supervised checks use real requests and cannot accept fake results',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final a = f.first.source;
      final b = f.second.source;
      final sameHost = _external(a.endpoint.host, 'same-host');
      final siblingHost = _external('sub.${a.endpoint.host}', 'sibling-host');
      await f.services.books.importSources([sameHost, siblingHost]);
      await f.services.books.saveSource(sameHost, {'enabled': true});
      await f.services.books.saveSource(siblingHost, {'enabled': true});
      await f.supervise();
      final fake = BookSiteChecks(
        f.services.books,
        inspect: (_, _) async => const BookSiteInspection(
          BookSiteFinding.gamblingClue,
          gamblingRisk: true,
        ),
      );
      await expectLater(
        fake.run([f.first], CancellationToken()),
        throwsFormatException,
      );
      await expectLater(
        f.services.books.markSourceRisk(a, quarantine: true),
        throwsFormatException,
      );
      expect(await f.services.books.riskStore.get(a.id), isNull);

      // A generic, locally stored result must not postpone the trusted scan.
      final forged = BookSiteCheck(
        const BookSiteInspection(BookSiteFinding.sampled),
        DateTime.now(),
        bookSourceCheckFingerprint(a),
      );
      await f.services.books.store.write(
        'books_site_check:${a.id}',
        forged.toJson(),
      );
      f.server.pages[a.endpoint.host] = '<p>在线赌场 立即下注</p>';
      f.server.pages[b.endpoint.host] =
          '<title>成人小说网</title>'
          '<meta name="description" content="主要提供成人小说">';
      await f.monitor.check().timeout(_timeout);
      expect(f.injectedCalls, 0);
      expect(f.requested.map((uri) => uri.host).toSet(), {
        a.endpoint.host,
        b.endpoint.host,
      });
      expect(
        f.requested.every(
          (uri) => uri.scheme == 'https' && uri.path == '/' && !uri.hasQuery,
        ),
        isTrue,
      );
      expect(
        (await f.services.books.riskStore.get(a.id))!.quarantinedHost,
        isTrue,
      );
      expect((await f.services.books.riskStore.get(b.id))!.adultHost, isTrue);
      expect(
        await f.services.books.store.read(
          'books_supervised_site_check:${a.id}',
        ),
        isNotNull,
      );
      expect(
        await f.services.books.store.read(
          'books_supervised_site_check:${b.id}',
        ),
        isNotNull,
      );
      expect(
        await f.services.books.store.read(
          'books_supervised_site_check:${f.disabled.source.id}',
        ),
        isNull,
      );
      expect(
        await f.services.books.store.read(
          'books_supervised_site_check:${sameHost.id}',
        ),
        isNull,
      );

      await f.setSupervision(false);
      expect(f.services.books.sourceAllowed(sameHost), isFalse);
      expect(f.services.books.sourceAllowed(siblingHost), isTrue);
      await f.restart();
      expect(f.services.books.sourceAllowed(sameHost), isFalse);
      expect(f.services.books.sourceAllowed(siblingHost), isTrue);
      expect((await f.services.books.riskStore.get(a.id))!.quarantined, isTrue);
    },
  );

  test(
    'weak clues stay unblocked and trusted due records prevent early repeats',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      await f.supervise();
      f.server.pages[f.first.source.endpoint.host] = '<p>在线赌场</p>';
      await f.monitor.check().timeout(_timeout);
      expect(await f.services.books.riskStore.get(f.first.source.id), isNull);
      final raw = await f.services.books.store.read(
        'books_supervised_site_check:${f.first.source.id}',
      );
      final check = BookSiteCheck.fromJson(raw, f.first.source);
      expect(check!.inspection.finding, BookSiteFinding.gamblingClue);
      expect(check.inspection.gamblingRisk, isFalse);
      final count = f.requested.length;
      await f.monitor.check().timeout(_timeout);
      expect(f.requested, hasLength(count));
    },
  );

  test(
    'supervised checks persist script clues without risk and revisit v1',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      await f.supervise();
      final source = f.first.source;
      final host = source.endpoint.host;
      final key = 'books_supervised_site_check:${source.id}';
      f.server.pages[host] =
          "<script>location.href='https://other.example/?token=secret';</script>";
      await f.monitor.check().timeout(_timeout);
      final original = BookSiteCheck.fromJson(
        await f.services.books.store.read(key),
        source,
      )!;
      expect(original.inspection.scriptReview.hasClues, isTrue);
      expect(await f.services.books.riskStore.get(source.id), isNull);
      expect(original.toJson().toString(), isNot(contains('other.example')));
      final legacy = original.toJson()..remove('scriptReview');
      await f.services.books.store.write(key, legacy);
      final count = f.requested.where((uri) => uri.host == host).length;
      await f.monitor.check().timeout(_timeout);
      expect(
        f.requested.where((uri) => uri.host == host),
        hasLength(count + 1),
      );
      final migrated = BookSiteCheck.fromJson(
        await f.services.books.store.read(key),
        source,
      )!;
      expect(migrated.inspection.scriptReview.hasClues, isTrue);
      expect(migrated.legacyScriptReviewMissing, isFalse);
      expect(await f.services.books.riskStore.get(source.id), isNull);
    },
  );

  test(
    'manual and supervised checks share clue history without reviving cleared clues',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final source = f.first.source;
      final sharedKey = 'books_site_check:${source.id}';
      final trustedKey = 'books_supervised_site_check:${source.id}';
      var manualBody =
          "<script>location.href='https://other.example/';</script>";
      final manual = BookSiteChecks(
        f.services.books,
        inspect: (source, _) async =>
            inspectBookSiteHtml(source.endpoint, manualBody),
      );
      await manual.run([f.first], CancellationToken());
      final initial = BookSiteCheck.fromJson(
        await f.services.books.store.read(sharedKey),
        source,
      )!;
      expect(
        initial.pendingScriptClues.keys,
        contains(BookPageScriptClue.crossOriginRedirect),
      );
      await f.supervise();
      f.server.pages[source.endpoint.host] =
          "<script src='/external.js'></script><script>eval(atob('YWxlcnQoMSk='));</script>";
      await f.monitor.check().timeout(_timeout);
      final partial = BookSiteCheck.fromJson(
        await f.services.books.store.read(sharedKey),
        source,
      )!;
      expect(
        partial.historicalScriptClues[BookPageScriptClue.crossOriginRedirect],
        initial.pendingScriptClues[BookPageScriptClue.crossOriginRedirect],
      );
      expect(
        partial.inspection.scriptReview.clues,
        contains(BookPageScriptClue.decodedDynamicEvaluation),
      );
      expect(partial.pendingScriptClues, hasLength(2));
      final trusted = BookSiteCheck.fromJson(
        await f.services.books.store.read(trustedKey),
        source,
      )!;
      expect(trusted.pendingScriptClues, partial.pendingScriptClues);

      manualBody = '<p>完整普通页面</p>';
      await f.channels(() async {
        await manual.run([f.first], CancellationToken());
      });
      final cleared = BookSiteCheck.fromJson(
        await f.services.books.store.read(sharedKey),
        source,
      )!;
      expect(cleared.pendingScriptClues, isEmpty);
      await f.services.books.store.write(trustedKey, {
        ...trusted.toJson(),
        'checkedAt': DateTime.now()
            .subtract(const Duration(days: 8))
            .millisecondsSinceEpoch,
      });
      f.server.pages[source.endpoint.host] =
          "<script src='/external.js'></script>";
      await f.monitor.check().timeout(_timeout);
      final after = BookSiteCheck.fromJson(
        await f.services.books.store.read(sharedKey),
        source,
      )!;
      expect(
        after.inspection.scriptReview.coverage,
        BookPageScriptCoverage.partial,
      );
      expect(after.pendingScriptClues, isEmpty);
      expect(await f.services.books.riskStore.get(source.id), isNull);
    },
  );

  test(
    'only a trusted supervised sample can satisfy both revision records',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      for (final kind in [BookKind.audio, BookKind.comic]) {
        final ids = (await f.services.books.sources(
          kind,
          enabledOnly: true,
        )).map((entry) => entry.source.id).toSet();
        await f.services.books.setSourcesEnabled(kind, ids, false);
      }
      await f.supervise();
      final source = f.first.source;
      final sharedKey = 'books_site_check:${source.id}';
      final trustedKey = 'books_supervised_site_check:${source.id}';
      await f.monitor.check().timeout(_timeout);
      final oldRevision = (await f.services.books.store.siteRevisions.get(
        source.id,
      ))!;
      await f.channels(() async {
        await f.services.books.saveSource(source, {'enabled': false});
        await f.services.books.saveSource(source, {'enabled': true});
      });
      final revision = (await f.services.books.store.siteRevisions.get(
        source.id,
      ))!;
      expect(revision, isNot(oldRevision));
      BookSiteCheck? parse(Object? raw) => BookSiteCheck.fromJson(
        raw,
        source,
        currentRevision: revision,
        requireRevision: true,
      );
      expect(
        parse(await f.services.books.store.read(sharedKey))!.inspection.finding,
        BookSiteFinding.sourceChanged,
      );
      expect(
        parse(
          await f.services.books.store.read(trustedKey),
        )!.inspection.finding,
        BookSiteFinding.sourceChanged,
      );

      final manual = BookSiteChecks(
        f.services.books,
        inspect: (_, _) async =>
            inspectBookSiteHtml(source.endpoint, '<p>普通页面</p>'),
      );
      await f.channels(() async {
        await manual.run([f.first], CancellationToken());
      });
      expect(
        parse(await f.services.books.store.read(sharedKey))!.inspection.finding,
        BookSiteFinding.sampled,
      );
      expect(
        parse(
          await f.services.books.store.read(trustedKey),
        )!.inspection.finding,
        BookSiteFinding.sourceChanged,
      );
      await f.monitor.check().timeout(_timeout);
      expect(
        parse(await f.services.books.store.read(sharedKey))!.inspection.finding,
        BookSiteFinding.sampled,
      );
      expect(
        parse(
          await f.services.books.store.read(trustedKey),
        )!.inspection.finding,
        BookSiteFinding.sampled,
      );

      await f.channels(() async {
        await f.services.books.saveSource(source, {'enabled': false});
        await f.services.books.saveSource(source, {'enabled': true});
      });
      final nextRevision = (await f.services.books.store.siteRevisions.get(
        source.id,
      ))!;
      expect(nextRevision, isNot(revision));
      await f.monitor.check().timeout(_timeout);
      final shared = BookSiteCheck.fromJson(
        await f.services.books.store.read(sharedKey),
        source,
        currentRevision: nextRevision,
        requireRevision: true,
      )!;
      final trusted = BookSiteCheck.fromJson(
        await f.services.books.store.read(trustedKey),
        source,
        currentRevision: nextRevision,
        requireRevision: true,
      )!;
      expect(shared.inspection.finding, BookSiteFinding.sampled);
      expect(trusted.inspection.finding, BookSiteFinding.sampled);
      expect(shared.isDue(DateTime.now()), isFalse);
      await f.setSupervision(false);
      expect(
        (await f.services.books.sources(
          BookKind.text,
          enabledOnly: true,
        )).any((entry) => entry.source.id == source.id),
        isTrue,
      );
      final targetBefore = f.injectedSourceIds
          .where((id) => id == source.id)
          .length;
      await f.monitor.check().timeout(_timeout);
      expect(
        f.injectedSourceIds.where((id) => id == source.id),
        hasLength(targetBefore),
      );
    },
  );

  test(
    'supervised failures persist, back off and detect a recovered host',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      await f.supervise();
      final source = f.first.source;
      final host = source.endpoint.host;
      final key = 'books_supervised_site_check:${source.id}';
      f.server.statuses[host] = HttpStatus.serviceUnavailable;
      await f.monitor.check().timeout(_timeout);
      var raw = await f.services.books.store.read(key);
      var check = BookSiteCheck.fromJson(raw, source)!;
      expect(check.inspection.finding, BookSiteFinding.httpError);
      expect(check.consecutiveFailures, 1);
      expect(check.isDue(DateTime.now()), isFalse);

      await f.services.books.store.write(key, {
        ...check.toJson(),
        'checkedAt': DateTime.now()
            .subtract(const Duration(minutes: 31))
            .millisecondsSinceEpoch,
      });
      await f.monitor.check().timeout(_timeout);
      raw = await f.services.books.store.read(key);
      check = BookSiteCheck.fromJson(raw, source)!;
      expect(check.consecutiveFailures, 2);
      expect(
        check.nextDue.difference(check.checkedAt),
        const Duration(hours: 1),
      );
      final count = f.requested.where((uri) => uri.host == host).length;

      await f.restart();
      await f.monitor.check().timeout(_timeout);
      expect(f.requested.where((uri) => uri.host == host), hasLength(count));
      check = BookSiteCheck.fromJson(
        await f.services.books.store.read(key),
        source,
      )!;
      expect(check.consecutiveFailures, 2);
      await f.services.books.store.write(key, {
        ...check.toJson(),
        'checkedAt': DateTime.now()
            .subtract(const Duration(hours: 2))
            .millisecondsSinceEpoch,
      });
      f.server.statuses.remove(host);
      f.server.pages[host] = '<p>在线赌场 立即下注</p>';
      await f.monitor.check().timeout(_timeout);
      final risk = await f.services.books.riskStore.get(source.id);
      expect(risk!.quarantinedHost, isTrue);
      final recovered = BookSiteCheck.fromJson(
        await f.services.books.store.read(key),
        source,
      )!;
      expect(recovered.consecutiveFailures, 0);
      expect(recovered.needsRetry, isFalse);
      expect(
        recovered.nextDue.difference(recovered.checkedAt),
        const Duration(days: 7),
      );
    },
  );

  test(
    'supervised monitor retries a clue with redirect and retains strong risk',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      await f.supervise();
      final source = f.first.source;
      final host = source.endpoint.host;
      final key = 'books_supervised_site_check:${source.id}';
      const redirect =
          '<meta http-equiv="refresh" content="0;url=https://other.example/">';
      f.server.pages[host] = '$redirect<p>在线赌场</p>';
      await f.monitor.check().timeout(_timeout);
      var check = BookSiteCheck.fromJson(
        await f.services.books.store.read(key),
        source,
      )!;
      expect(check.inspection.finding, BookSiteFinding.gamblingClue);
      expect(check.inspection.redirect, BookSiteRedirect.external);
      expect(check.inspection.gamblingRisk, isFalse);
      expect(check.needsRetry, isTrue);
      expect(await f.services.books.riskStore.get(source.id), isNull);
      final firstCount = f.requested.where((uri) => uri.host == host).length;
      await f.monitor.check().timeout(_timeout);
      expect(
        f.requested.where((uri) => uri.host == host),
        hasLength(firstCount),
      );
      await f.services.books.store.write(key, {
        ...check.toJson(),
        'checkedAt': DateTime.now()
            .subtract(const Duration(minutes: 31))
            .millisecondsSinceEpoch,
      });
      f.server.pages[host] = '$redirect<p>在线赌场 立即下注</p>';
      await f.monitor.check().timeout(_timeout);
      expect(
        f.requested.where((uri) => uri.host == host),
        hasLength(firstCount + 1),
      );
      expect(
        (await f.services.books.riskStore.get(source.id))!.quarantinedHost,
        isTrue,
      );
      check = BookSiteCheck.fromJson(
        await f.services.books.store.read(key),
        source,
      )!;
      expect(check.inspection.gamblingRisk, isTrue);
      expect(check.inspection.redirect, BookSiteRedirect.external);
      expect(check.needsRetry, isTrue);
      expect(f.requested.every((uri) => uri.host != 'other.example'), isTrue);
    },
  );

  test('blacklisted built-ins are not fetched', () async {
    final f = await _Fixture.create();
    addTearDown(f.close);
    await f.services.books.blockSource(f.second.source);
    await f.supervise();
    await f.monitor.check().timeout(_timeout);
    expect(f.requested.map((uri) => uri.host), [f.first.source.endpoint.host]);
    expect(await f.services.books.riskStore.get(f.second.source.id), isNull);
  });

  test('previous adult evidence remains and excludes that built-in', () async {
    final f = await _Fixture.create();
    addTearDown(f.close);
    await f.services.books.markSourceRisk(f.second.source, adult: true);
    final previous = (await f.services.books.riskStore.get(
      f.second.source.id,
    ))!;
    await f.supervise();
    await f.monitor.check().timeout(_timeout);
    expect(f.requested.map((uri) => uri.host), [f.first.source.endpoint.host]);
    final after = (await f.services.books.riskStore.get(f.second.source.id))!;
    expect(after.adult, isTrue);
    expect(after.version, previous.version);
  });

  test(
    'supervision keyword rules exclude a built-in before any request',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      await f.supervise();
      await f.services.supervision.execute(
        SensitiveOperation.supervision,
        () => f.services.supervision.updateRules(
          SupervisionRules(keywords: [f.second.source.name]),
        ),
        password: _password,
      );
      await f.monitor.check().timeout(_timeout);
      expect(f.requested.map((uri) => uri.host), [
        f.first.source.endpoint.host,
      ]);
      expect(await f.services.books.riskStore.get(f.second.source.id), isNull);
    },
  );

  test(
    'the startup timer runs the supervised scan only when enabled',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      await f.supervise();
      await f.monitor.close();
      f.monitor = BookSiteMonitor(
        BookSiteChecks(f.services.books),
        f.services.settings,
        startDelay: const Duration(milliseconds: 10),
        interval: const Duration(hours: 1),
      );
      f.monitor.start();
      final deadline = DateTime.now().add(_timeout);
      while (f.requested.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(f.requested, isNotEmpty);
      await f.monitor.cancelCurrent();
      final count = f.requested.length;
      await f.services.supervision.execute(
        SensitiveOperation.settings,
        () => f.services.settings.update({'backgroundProbe': false}),
        password: _password,
      );
      await f.monitor.check().timeout(_timeout);
      expect(f.requested, hasLength(count));
    },
  );

  test('corrupt supervision state prevents the privileged scanner', () async {
    final f = await _Fixture.create();
    addTearDown(f.close);
    await f.monitor.close();
    await f.services.db.write(
      'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
      [SupervisionController.storageKey, '{}'],
    );
    await f.services.close();
    f.services = await _Fixture._open(f.root, f.server, f.requested);
    f.monitor = f._newMonitor();
    expect(f.services.supervision.corrupted, isTrue);
    await f.monitor.check().timeout(_timeout);
    expect(f.requested, isEmpty);
    await expectLater(
      f.services.books.checkSupervisedBuiltinSites(CancellationToken()),
      throwsA(isA<RequestCancelled>()),
    );
    expect(await f.services.books.riskStore.get(f.first.source.id), isNull);
  });

  for (final change in ['single', 'bulk', 'group', 'remove', 'blacklist']) {
    test(
      '$change source configuration ABA cancels the sampled result',
      () async {
        final f = await _Fixture.create();
        addTearDown(f.close);
        await f.supervise();
        final source = f.first.source;
        final gate = f.server.hold(source.endpoint.host, '<p>在线赌场 立即下注</p>');
        final running = f.monitor.check();
        await gate.started.future.timeout(_timeout);
        await f.channels(() async {
          switch (change) {
            case 'single':
              await f.services.books.saveSource(source, {'enabled': false});
              await f.services.books.saveSource(source, {'enabled': true});
            case 'bulk':
              await f.services.books.setSourcesEnabled(BookKind.text, {
                source.id,
              }, false);
              await f.services.books.setSourcesEnabled(BookKind.text, {
                source.id,
              }, true);
            case 'group':
              await f.services.books.saveSource(source, {'group': '临时分组'});
              await f.services.books.saveSource(source, {
                'group': f.first.group,
              });
            case 'remove':
              await f.services.books.removeSource(source);
              await f.services.books.restoreDefaultSources(BookKind.text);
            case 'blacklist':
              await f.services.books.blockSource(source);
              await f.services.books.unblockSource(source.id);
              await f.services.books.saveSource(source, {'enabled': true});
          }
        });
        gate.release();
        await running.timeout(_timeout);
        expect(await f.services.books.riskStore.get(source.id), isNull);
        expect(
          await f.services.books.store.read(
            'books_supervised_site_check:${source.id}',
          ),
          isNull,
        );
      },
    );
  }

  test(
    'configuration changes before publication roll back a strong finding',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      await f.supervise();
      final source = f.first.source;
      f.server.pages[source.endpoint.host] = '<p>在线赌场 立即下注</p>';
      final entered = Completer<void>();
      final release = Completer<void>();
      var held = false;
      f.services.books.beforeEvidenceMutationForTesting = () async {
        if (held) return;
        held = true;
        entered.complete();
        await release.future;
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        f.services.books.beforeEvidenceMutationForTesting = null;
      });
      final running = f.monitor.check();
      await entered.future.timeout(_timeout);
      await f.channels(() async {
        await f.services.books.saveSource(source, {'enabled': false});
        await f.services.books.saveSource(source, {'enabled': true});
      });
      release.complete();
      await running.timeout(_timeout);
      expect(await f.services.books.riskStore.get(source.id), isNull);
      expect(
        await f.services.books.store.read(
          'books_supervised_site_check:${source.id}',
        ),
        isNull,
      );
    },
  );

  test(
    'supervision and background setting changes cancel in-flight checks',
    () async {
      for (final change in ['supervision', 'setting', 'rules']) {
        final f = await _Fixture.create();
        try {
          await f.supervise();
          final source = f.first.source;
          final gate = f.server.hold(source.endpoint.host, '<p>在线赌场 立即下注</p>');
          final running = f.monitor.check();
          await gate.started.future.timeout(_timeout);
          if (change == 'supervision') {
            await f.setSupervision(false);
            await f.setSupervision(true);
          } else if (change == 'setting') {
            await f.services.supervision.execute(
              SensitiveOperation.settings,
              () async {
                await f.services.settings.update({'backgroundProbe': false});
                await f.services.settings.update({'backgroundProbe': true});
              },
              password: _password,
            );
          } else {
            await f.services.supervision.execute(
              SensitiveOperation.supervision,
              () => f.services.supervision.updateRules(
                SupervisionRules(keywords: [source.name]),
              ),
              password: _password,
            );
            await f.services.supervision.execute(
              SensitiveOperation.supervision,
              () => f.services.supervision.updateRules(SupervisionRules()),
              password: _password,
            );
          }
          gate.release();
          await running.timeout(_timeout);
          expect(
            await f.services.books.riskStore.get(source.id),
            isNull,
            reason: change,
          );
          expect(
            await f.services.books.store.read(
              'books_supervised_site_check:${source.id}',
            ),
            isNull,
            reason: change,
          );
        } finally {
          await f.close();
        }
      }
    },
  );

  test(
    'manual work cancels and drains the supervised background scan',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      await f.supervise();
      final source = f.first.source;
      final gate = f.server.hold(source.endpoint.host, '<p>在线赌场 立即下注</p>');
      final running = f.monitor.check();
      await gate.started.future.timeout(_timeout);
      var entered = false;
      await f.monitor
          .whileManual(CancellationToken(), () async {
            entered = true;
          })
          .timeout(_timeout);
      gate.release();
      await running.timeout(_timeout);
      expect(entered, isTrue);
      expect(await f.services.books.riskStore.get(source.id), isNull);
      expect(
        await f.services.books.store.read(
          'books_supervised_site_check:${source.id}',
        ),
        isNull,
      );
    },
  );

  test(
    'backup restoration cancels a supervised check before writing',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final preview = await f.services.backup.preview(
        await f.services.backup.export(),
      );
      await f.supervise();
      final source = f.first.source;
      final gate = f.server.hold(source.endpoint.host, '<p>在线赌场 立即下注</p>');
      final running = f.monitor.check();
      await gate.started.future.timeout(_timeout);
      await f.services.supervision.execute(
        SensitiveOperation.restore,
        () => f.services.restoreBackup(preview),
        password: _password,
      );
      gate.release();
      await running.timeout(_timeout);
      expect(await f.services.books.riskStore.get(source.id), isNull);
      expect(
        await f.services.books.store.read(
          'books_supervised_site_check:${source.id}',
        ),
        isNull,
      );
    },
  );

  test(
    'cancellation and repository close drain active supervised checks',
    () async {
      for (final closing in [false, true]) {
        final f = await _Fixture.create();
        try {
          await f.supervise();
          final source = f.first.source;
          final gate = f.server.hold(source.endpoint.host, '<p>在线赌场 立即下注</p>');
          final token = CancellationToken();
          final running = f.services.books.checkSupervisedBuiltinSites(token);
          final cancelled = expectLater(
            running,
            throwsA(isA<RequestCancelled>()),
          );
          await gate.started.future.timeout(_timeout);
          if (closing) {
            await f.services.books.close().timeout(_timeout);
          } else {
            token.cancel();
          }
          gate.release();
          await cancelled.timeout(_timeout);
          expect(await f.services.books.riskStore.get(source.id), isNull);
          if (closing) {
            await expectLater(
              f.services.books.checkSupervisedBuiltinSites(CancellationToken()),
              throwsStateError,
            );
          }
        } finally {
          await f.close();
        }
      }
    },
  );
}

void _batchLeaseSupervisedTests() {
  test(
    'supervised policy cancellation does not cancel the caller token',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      await f.supervise();
      final source = f.first.source;
      final gate = f.server.hold(source.endpoint.host, '<p>普通首页</p>');
      addTearDown(gate.release);
      final caller = CancellationToken();
      final running = expectLater(
        f.services.books.checkSupervisedBuiltinSites(caller),
        throwsA(isA<RequestCancelled>()),
      );
      await gate.started.future.timeout(_timeout);
      await f.services.supervision.execute(
        SensitiveOperation.settings,
        () => f.services.settings.update({'backgroundProbe': false}),
        password: _password,
      );
      expect(caller.isCancelled, isFalse);
      gate.release();
      await running.timeout(_timeout);
      expect(caller.isCancelled, isFalse);
    },
  );

  test(
    'an in-flight supervised batch prevents an older overwrite of manual clues',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      await f.supervise();
      final source = f.first.source;
      final gate = f.server.hold(
        source.endpoint.host,
        '<html><body><p>普通首页</p></body></html>',
      );
      addTearDown(gate.release);
      final supervised = f.services.books.checkSupervisedBuiltinSites(
        CancellationToken(),
      );
      await gate.started.future.timeout(_timeout);
      final manual = BookSiteChecks(
        f.services.books,
        inspect: (source, _) async => inspectBookSiteHtml(
          Uri(scheme: 'https', host: source.endpoint.host, path: '/'),
          '<html><body><h1>This domain is for sale</h1>'
          '<h3>Contact the owner</h3><form></form>'
          "<script>location.href='https://other.example/';</script>"
          '</body></html>',
        ),
      );
      await f.channels(() async {
        await expectLater(
          manual.run([f.first], CancellationToken()),
          throwsFormatException,
        );
      });
      gate.release();
      await supervised.timeout(_timeout);
      await f.channels(() async {
        expect((await manual.run([f.first], CancellationToken())).checked, 1);
      });
      final stored = BookSiteCheck.fromJson(
        await f.services.books.store.read('books_site_check:${source.id}'),
        source,
      )!;
      expect(stored.pendingSaleClue, isNotNull);
      expect(
        stored.pendingScriptClues.keys,
        contains(BookPageScriptClue.crossOriginRedirect),
      );
      expect(await f.services.books.riskStore.get(source.id), isNull);
    },
  );

  test(
    'manual batch blocks supervised overlap; later trusted strong evidence is kept',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      await f.supervise();
      final source = f.first.source;
      final started = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final manual = BookSiteChecks(
        f.services.books,
        inspect: (source, _) async {
          started.complete();
          await release.future;
          return inspectBookSiteHtml(
            Uri(scheme: 'https', host: source.endpoint.host, path: '/'),
            '<html><body><h1>This domain is for sale</h1>'
            '<h3>Contact the owner</h3><form></form></body></html>',
          );
        },
      );
      await f.channels(() async {
        final running = manual.run([f.first], CancellationToken());
        await started.future.timeout(_timeout);
        await expectLater(
          f.services.books.checkSupervisedBuiltinSites(CancellationToken()),
          throwsFormatException,
        );
        release.complete();
        expect((await running.timeout(_timeout)).checked, 1);
      });
      f.server.pages[source.endpoint.host] = '<p>在线赌场 立即下注</p>';
      await f.services.books
          .checkSupervisedBuiltinSites(CancellationToken())
          .timeout(_timeout);
      expect(
        (await f.services.books.riskStore.get(source.id))!.quarantinedHost,
        isTrue,
      );
      expect(f.services.books.sourceAllowed(source), isFalse);
    },
  );
}

BookSource _external(String host, String key) => BookSource.fromJson({
  'name': '外部样本 $key',
  'kind': 'text',
  'format': 'feed',
  'url': 'https://$host/feed',
  'sourceKey': 'external:$key',
});

final class _Fixture {
  _Fixture(this.temp, this.services, this.server, this.requested, this.entries);

  final VerifiedTempDirectory temp;
  Directory get root => temp.directory;
  AppServices services;
  final _Server server;
  final List<Uri> requested;
  final List<BookSourceEntry> entries;
  int injectedCalls = 0;
  final injectedSourceIds = <String>[];
  late BookSiteMonitor monitor = _newMonitor();
  BookSourceEntry get first => entries[0];
  BookSourceEntry get second => entries[1];
  BookSourceEntry get disabled => entries[2];

  BookSiteMonitor _newMonitor() {
    final result = BookSiteMonitor(
      BookSiteChecks(
        services.books,
        inspect: (source, _) async {
          injectedCalls++;
          injectedSourceIds.add(source.id);
          return const BookSiteInspection(
            BookSiteFinding.gamblingClue,
            gamblingRisk: true,
          );
        },
      ),
      services.settings,
      startDelay: const Duration(hours: 1),
      interval: const Duration(hours: 1),
    );
    result.start();
    return result;
  }

  static Future<_Fixture> create() async {
    final temp = await VerifiedTempDirectory.create('supervised-site-scan-');
    final root = temp.directory;
    final server = await _Server.start();
    final requested = <Uri>[];
    final services = await _open(root, server, requested);
    final entries = (await services.books.sources(BookKind.text))
        .where((entry) => entry.source.builtin && entry.source.defaultEnabled)
        .toList();
    expect(entries.length, greaterThanOrEqualTo(3));
    expect(
      entries.take(3).map((entry) => entry.source.endpoint.host).toSet(),
      hasLength(3),
    );
    await services.books.setSourcesEnabled(
      BookKind.text,
      entries.map((entry) => entry.source.id).toSet(),
      false,
    );
    await services.books.setSourcesEnabled(BookKind.text, {
      entries[0].source.id,
      entries[1].source.id,
    }, true);
    final result = _Fixture(temp, services, server, requested, entries);
    // Construct before supervision so the same monitor handles the transition.
    result.monitor;
    return result;
  }

  static Future<AppServices> _open(
    Directory root,
    _Server server,
    List<Uri> requested,
  ) async {
    return HttpOverrides.runZoned(
      () async {
        final services = AppServices.scoped(
          root,
          AppDatabase(File('${root.path}/database.sqlite')),
        );
        await services.supervision.load();
        await services.settings.load();
        await services.books.sources(BookKind.text);
        return services;
      },
      createHttpClient: (context) {
        final client = _RealHttpOverrides().createHttpClient(context)
          ..findProxy = (_) => 'DIRECT';
        return _LoopbackClient(client, server.uri, requested);
      },
    );
  }

  Future<void> supervise() async {
    final pending = await services.supervision.prepareCredentials(_password);
    await services.supervision.saveCredentials(pending);
  }

  Future<void> setSupervision(bool enabled) => services.supervision.execute(
    SensitiveOperation.supervision,
    () => services.supervision.setEnabled(enabled),
    password: _password,
  );

  Future<void> channels(Future<void> Function() action) => services.supervision
      .execute(SensitiveOperation.channels, action, password: _password);

  Future<void> restart() async {
    await monitor.close();
    await services.close();
    services = await _open(root, server, requested);
    monitor = _newMonitor();
  }

  Future<void> close() async {
    await monitor.close();
    await services.close();
    await server.close();
    await temp.delete();
  }
}

final class _Gate {
  final started = Completer<void>();
  final _release = Completer<void>();
  void release() {
    if (!_release.isCompleted) _release.complete();
  }
}

final class _Server {
  _Server(this.server);
  final HttpServer server;
  final pages = <String, String>{};
  final statuses = <String, int>{};
  final gates = <String, _Gate>{};
  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}/');

  static Future<_Server> start() async {
    final result = _Server(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    result.server.listen((request) async {
      try {
        final host = request.headers.value('x-fixture-host') ?? '';
        final gate = result.gates[host];
        if (gate != null) {
          if (!gate.started.isCompleted) gate.started.complete();
          await gate._release.future;
        }
        request.response.statusCode = result.statuses[host] ?? HttpStatus.ok;
        request.response.headers.contentType = ContentType.html;
        request.response.write(result.pages[host] ?? '<p>正常阅读</p>');
        await request.response.close();
      } on Object {
        // Cancellation may close the real loopback socket before the reply.
      }
    });
    return result;
  }

  _Gate hold(String host, String html) {
    pages[host] = html;
    return gates[host] = _Gate();
  }

  Future<void> close() async {
    for (final gate in gates.values) {
      gate.release();
    }
    await server.close(force: true);
  }
}

/// The default override implementation constructs dart:io's real client.
final class _RealHttpOverrides extends HttpOverrides {}

/// The application still constructs its normal inspector and HTTP client.
/// Only this test's dart:io client maps the requested public root to loopback.
final class _LoopbackClient implements HttpClient {
  _LoopbackClient(this.client, this.base, this.requested);
  final HttpClient client;
  final Uri base;
  final List<Uri> requested;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    requested.add(url);
    final request = await client.openUrl(method, base.resolve(url.path));
    request.headers.set('x-fixture-host', url.host);
    return request;
  }

  @override
  void close({bool force = false}) => client.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isSetter) return null;
    return super.noSuchMethod(invocation);
  }
}
