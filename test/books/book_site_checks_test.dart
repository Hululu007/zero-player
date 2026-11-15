import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/persistence/installation_metadata.dart';
import 'package:zero_player/features/books/application/book_site_checks.dart';
import 'package:zero_player/features/books/application/book_site_monitor.dart';
import 'package:zero_player/features/books/data/book_site_inspection.dart';
import 'package:zero_player/features/books/data/book_source_risk_store.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _storedCheckTests();
  _batchRiskTests();
  _batchFailureTests();
  _inFlightInvalidationTests();
  _riskCommitRaceTests();
  _riskRetentionTests();
  _monitorLifecycleTests();
  _monitorPolicyTests();
  _monitorRetryTests();
}

void _riskCommitRaceTests() {
  for (final afterWrite in [false, true]) {
    test(
      'cancellation ${afterWrite ? 'after insert but before the final transaction check' : 'before the transaction'} rolls back the risk',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.close);
        final source = _source('one', 'cancel-risk.example');
        final entry = (await fixture.add([source])).single;
        final repo = fixture.services.books;
        var policyNotifications = 0;
        void changed() => policyNotifications++;
        fixture.services.contentPolicy.addListener(changed);
        addTearDown(
          () => fixture.services.contentPolicy.removeListener(changed),
        );
        final entered = Completer<void>();
        final release = Completer<void>();
        Future<void> hold() async {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        }

        if (afterWrite) {
          repo.afterSiteRiskWriteForTesting = hold;
        } else {
          repo.beforeEvidenceMutationForTesting = hold;
        }
        addTearDown(() {
          if (!release.isCompleted) release.complete();
          repo.beforeEvidenceMutationForTesting = null;
          repo.afterSiteRiskWriteForTesting = null;
        });
        final token = CancellationToken();
        final checks = BookSiteChecks(
          repo,
          inspect: (_, _) async => const BookSiteInspection(
            BookSiteFinding.gamblingClue,
            gamblingRisk: true,
          ),
        );
        final running = expectLater(
          checks.run([entry], token, enabledOnly: true),
          throwsA(isA<RequestCancelled>()),
        );
        await entered.future.timeout(const Duration(seconds: 5));
        token.cancel();
        release.complete();
        await running.timeout(const Duration(seconds: 5));
        expect(await repo.riskStore.get(source.id), isNull);
        expect(await repo.store.read('books_site_check:${source.id}'), isNull);
        expect(policyNotifications, 0);
        expect(
          (await repo.sourceEntry(BookKind.text, source.id))!.enabled,
          isTrue,
        );
      },
    );
  }

  test(
    'cancellation after commit still publishes the committed restriction',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final source = _source('one', 'committed-risk.example');
      final entry = (await fixture.add([source])).single;
      final repo = fixture.services.books;
      final entered = Completer<void>();
      final release = Completer<void>();
      repo.afterSiteRiskCommitForTesting = () async {
        entered.complete();
        await release.future;
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        repo.afterSiteRiskCommitForTesting = null;
      });
      var notifications = 0;
      void changed() => notifications++;
      fixture.services.contentPolicy.addListener(changed);
      addTearDown(() => fixture.services.contentPolicy.removeListener(changed));
      final token = CancellationToken();
      final checks = BookSiteChecks(
        repo,
        inspect: (_, _) async => const BookSiteInspection(
          BookSiteFinding.gamblingClue,
          gamblingRisk: true,
        ),
      );
      final running = expectLater(
        checks.run([entry], token, enabledOnly: true),
        throwsA(isA<RequestCancelled>()),
      );
      await entered.future.timeout(const Duration(seconds: 5));
      token.cancel();
      release.complete();
      await running.timeout(const Duration(seconds: 5));
      expect((await repo.riskStore.get(source.id))!.quarantined, isTrue);
      expect(repo.sourceAllowed(source), isFalse);
      expect(notifications, greaterThan(0));
      expect(await repo.store.read('books_site_check:${source.id}'), isNull);
    },
  );

  test(
    'filter change before commit discards the old homepage result',
    () async {
      final fixture = await _Fixture.create(adultVerified: true);
      addTearDown(fixture.close);
      await fixture.services.settings.update({'filterAdult': false});
      final source = _source('one', 'filter-commit.example');
      final entry = (await fixture.add([source])).single;
      final repo = fixture.services.books;
      final entered = Completer<void>();
      final release = Completer<void>();
      repo.beforeEvidenceMutationForTesting = () async {
        entered.complete();
        await release.future;
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        repo.beforeEvidenceMutationForTesting = null;
      });
      final checks = BookSiteChecks(
        repo,
        inspect: (_, _) async => const BookSiteInspection(
          BookSiteFinding.gamblingClue,
          gamblingRisk: true,
        ),
      );
      final running = expectLater(
        checks.run([entry], CancellationToken(), enabledOnly: true),
        throwsA(isA<RequestCancelled>()),
      );
      await entered.future.timeout(const Duration(seconds: 5));
      await fixture.services.settings.update({'filterAdult': true});
      release.complete();
      await running.timeout(const Duration(seconds: 5));
      expect(await repo.riskStore.get(source.id), isNull);
      expect(await repo.store.read('books_site_check:${source.id}'), isNull);
    },
  );

  test(
    'supervision enabled before commit cannot accept a supplied finding',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final source = _source('one', 'supervision-commit.example');
      final entry = (await fixture.add([source])).single;
      final repo = fixture.services.books;
      final draft = await fixture.services.supervision.prepareCredentials(
        'test-password-123',
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      repo.beforeEvidenceMutationForTesting = () async {
        entered.complete();
        await release.future;
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        repo.beforeEvidenceMutationForTesting = null;
      });
      final checks = BookSiteChecks(
        repo,
        inspect: (_, _) async => const BookSiteInspection(
          BookSiteFinding.gamblingClue,
          gamblingRisk: true,
        ),
      );
      final running = expectLater(
        checks.run([entry], CancellationToken(), enabledOnly: true),
        throwsA(isA<RequestCancelled>()),
      );
      await entered.future.timeout(const Duration(seconds: 5));
      await fixture.services.supervision.saveCredentials(draft);
      release.complete();
      await running.timeout(const Duration(seconds: 5));
      expect(await repo.riskStore.get(source.id), isNull);
      expect(await repo.store.read('books_site_check:${source.id}'), isNull);
    },
  );

  test(
    'manual check can still mark an otherwise allowed disabled source',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final source = _source('one', 'manual-disabled.example');
      await fixture.add([source]);
      final repo = fixture.services.books;
      await repo.saveSource(source, {'enabled': false});
      final entry = (await repo.sourceEntry(BookKind.text, source.id))!;
      final checks = BookSiteChecks(
        repo,
        inspect: (_, _) async => const BookSiteInspection(
          BookSiteFinding.gamblingClue,
          gamblingRisk: true,
        ),
      );
      final result = await checks.run([entry], CancellationToken());
      expect(result.quarantined, 1);
      expect((await repo.riskStore.get(source.id))!.quarantined, isTrue);
    },
  );

  test(
    'disabling an enabled-only source before commit skips its old result',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final source = _source('one', 'disabled-commit.example');
      final entry = (await fixture.add([source])).single;
      final repo = fixture.services.books;
      final entered = Completer<void>();
      final release = Completer<void>();
      repo.beforeEvidenceMutationForTesting = () async {
        entered.complete();
        await release.future;
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        repo.beforeEvidenceMutationForTesting = null;
      });
      final checks = BookSiteChecks(
        repo,
        inspect: (_, _) async => const BookSiteInspection(
          BookSiteFinding.gamblingClue,
          gamblingRisk: true,
        ),
      );
      final running = checks.run(
        [entry],
        CancellationToken(),
        enabledOnly: true,
      );
      await entered.future.timeout(const Duration(seconds: 5));
      repo.beforeEvidenceMutationForTesting = null;
      await repo.saveSource(source, {'enabled': false});
      release.complete();
      final result = await running.timeout(const Duration(seconds: 5));
      expect(result.checked, 0);
      expect(await repo.riskStore.get(source.id), isNull);
      expect(await repo.store.read('books_site_check:${source.id}'), isNull);
      expect(
        (await repo.sourceEntry(BookKind.text, source.id))!.enabled,
        isFalse,
      );
    },
  );

  test(
    'same host retries a stale mark with the other eligible source',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final one = _source('one', 'shared-stale.example');
      final two = _source('two', 'shared-stale.example');
      final entries = await fixture.add([one, two]);
      final repo = fixture.services.books;
      final entered = Completer<void>();
      final release = Completer<void>();
      final sampleStarted = Completer<void>();
      final sample = Completer<BookSiteInspection>();
      BookSource? sampled;
      var held = false;
      repo.beforeEvidenceMutationForTesting = () async {
        if (held) return;
        held = true;
        entered.complete();
        await release.future;
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        if (!sample.isCompleted) {
          sample.complete(const BookSiteInspection(BookSiteFinding.sampled));
        }
        repo.beforeEvidenceMutationForTesting = null;
      });
      final checks = BookSiteChecks(
        repo,
        inspect: (source, _) {
          sampled = source;
          sampleStarted.complete();
          return sample.future;
        },
      );
      final running = checks.run(
        entries,
        CancellationToken(),
        enabledOnly: true,
      );
      await sampleStarted.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);
      sample.complete(
        const BookSiteInspection(
          BookSiteFinding.gamblingClue,
          gamblingRisk: true,
        ),
      );
      await entered.future.timeout(const Duration(seconds: 5));
      final stale = sampled!;
      final eligible = stale.id == one.id ? two : one;
      final changed = BookSource.fromJson({...stale.toJson(), 'name': '更新的来源'});
      // Bypass the repository on purpose to simulate a restored DB snapshot with
      // no in-memory revision notification while the first marker waits.
      await repo.store.saveSource(stale, {'source': changed.toJson()});
      release.complete();
      await running.timeout(const Duration(seconds: 5));
      expect(await repo.riskStore.get(stale.id), isNull);
      expect((await repo.riskStore.get(eligible.id))!.quarantined, isTrue);
    },
  );

  test(
    'manual review invalidates both pending checks for the same host',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final one = _source('one', 'reviewed-shared.example');
      final two = _source('two', 'reviewed-shared.example');
      final entries = await fixture.add([one, two]);
      final repo = fixture.services.books;
      final committed = Completer<void>();
      final publish = Completer<void>();
      final sampleStarted = Completer<void>();
      final sample = Completer<BookSiteInspection>();
      BookSource? sampled;
      repo.afterSiteRiskCommitForTesting = () async {
        committed.complete();
        await publish.future;
      };
      addTearDown(() {
        if (!publish.isCompleted) publish.complete();
        if (!sample.isCompleted) {
          sample.complete(const BookSiteInspection(BookSiteFinding.sampled));
        }
        repo.afterSiteRiskCommitForTesting = null;
      });
      final checks = BookSiteChecks(
        repo,
        inspect: (source, _) {
          sampled = source;
          sampleStarted.complete();
          return sample.future;
        },
      );
      final running = checks.run(
        entries,
        CancellationToken(),
        enabledOnly: true,
      );
      await sampleStarted.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);
      sample.complete(
        const BookSiteInspection(
          BookSiteFinding.gamblingClue,
          gamblingRisk: true,
        ),
      );
      await committed.future.timeout(const Duration(seconds: 5));
      final assessment = (await repo.riskStore.get(sampled!.id))!;
      final review = BookSourceRiskEntry(
        sourceId: assessment.sourceId,
        name: assessment.name,
        host: assessment.host,
        adult: assessment.adult,
        quarantined: assessment.quarantined,
        fixedQuarantine: false,
        version: assessment.version,
        recordKey: assessment.key,
      );
      final reviewStarted = Completer<void>();
      late Future<void> reviewFuture;
      void reviewAfterPublication() {
        if (reviewStarted.isCompleted) return;
        reviewFuture = repo.clearSourceRisk(review);
        reviewStarted.complete();
      }

      // Begin review exactly when the committed risk is published, before the
      // other worker can reuse the shared host mark or persist its check.
      fixture.services.contentPolicy.addListener(reviewAfterPublication);
      addTearDown(
        () => fixture.services.contentPolicy.removeListener(
          reviewAfterPublication,
        ),
      );
      publish.complete();
      await reviewStarted.future.timeout(const Duration(seconds: 5));
      await reviewFuture.timeout(const Duration(seconds: 5));
      final result = await running.timeout(const Duration(seconds: 5));
      expect(result.checked, 0);
      expect(result.skipped, 2);
      expect((await repo.riskStore.get(sampled!.id))!.quarantined, isFalse);
      expect(await repo.store.read('books_site_check:${one.id}'), isNull);
      expect(await repo.store.read('books_site_check:${two.id}'), isNull);
      expect(await repo.sourceEntry(BookKind.text, one.id), isNotNull);
      expect(await repo.sourceEntry(BookKind.text, two.id), isNotNull);
    },
  );

  test(
    'a failed review preserves evidence and invalidates an older sample',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final assessed = _source('assessed', 'prior-review.example');
      final pending = _source('pending', 'pending-review.example');
      final entries = await fixture.add([assessed, pending]);
      final repo = fixture.services.books;
      await repo.markSourceRisk(assessed, quarantine: true);
      final review = (await repo.sourceRiskEntries()).firstWhere(
        (entry) => entry.sourceId == assessed.id && entry.version > 0,
      );
      final stale = BookSourceRiskEntry(
        sourceId: review.sourceId,
        name: review.name,
        host: review.host,
        adult: review.adult,
        quarantined: review.quarantined,
        fixedQuarantine: review.fixedQuarantine,
        version: review.version + 1,
        recordKey: review.recordKey,
      );
      final started = Completer<void>();
      final response = Completer<BookSiteInspection>();
      addTearDown(() {
        if (!response.isCompleted) {
          response.complete(const BookSiteInspection(BookSiteFinding.sampled));
        }
      });
      final checks = BookSiteChecks(
        repo,
        inspect: (_, _) {
          started.complete();
          return response.future;
        },
      );
      final running = checks.run([
        entries.singleWhere((entry) => entry.source.id == pending.id),
      ], CancellationToken());
      await started.future.timeout(const Duration(seconds: 5));
      await expectLater(
        repo.clearSourceRisk(stale),
        throwsA(isA<FormatException>()),
      );
      response.complete(
        const BookSiteInspection(
          BookSiteFinding.gamblingClue,
          gamblingRisk: true,
        ),
      );
      final result = await running.timeout(const Duration(seconds: 5));
      expect(result.checked, 0);
      expect((await repo.riskStore.get(assessed.id))!.quarantined, isTrue);
      expect(await repo.riskStore.get(pending.id), isNull);
      expect(await repo.store.read('books_site_check:${pending.id}'), isNull);
    },
  );

  test('repository close waits for an already-started review', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final source = _source('closing', 'closing-review.example');
    await fixture.add([source]);
    final repo = fixture.services.books;
    await repo.markSourceRisk(source, quarantine: true);
    final review = (await repo.sourceRiskEntries()).firstWhere(
      (entry) => entry.sourceId == source.id && entry.version > 0,
    );
    final entered = Completer<void>();
    final release = Completer<void>();
    repo.beforeEvidenceMutationForTesting = () async {
      entered.complete();
      await release.future;
    };
    addTearDown(() {
      if (!release.isCompleted) release.complete();
      repo.beforeEvidenceMutationForTesting = null;
    });
    final operation = repo.clearSourceRisk(review);
    await entered.future.timeout(const Duration(seconds: 5));
    var closed = false;
    final closing = repo.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    release.complete();
    await operation.timeout(const Duration(seconds: 5));
    await closing.timeout(const Duration(seconds: 5));
    expect(closed, isTrue);
    expect((await repo.riskStore.get(source.id))!.quarantined, isFalse);
  });
}

void _storedCheckTests() {
  test('stored results expire and are discarded when source rules change', () {
    final source = _source('one', 'one.example');
    expect(bookSiteInspectionTarget(source).toString(), 'https://one.example/');
    final now = DateTime.now();
    final check = BookSiteCheck(
      const BookSiteInspection(BookSiteFinding.sampled),
      now,
      bookSourceCheckFingerprint(source),
    );
    expect(BookSiteCheck.fromJson(check.toJson(), source), isNotNull);
    expect(check.isDue(now.add(const Duration(days: 6))), isFalse);
    expect(check.isDue(now.add(const Duration(days: 7))), isTrue);
    final updated = BookSource.fromJson({...source.toJson(), 'name': '更新后'});
    expect(updated.id, source.id);
    expect(BookSiteCheck.fromJson(check.toJson(), updated), isNull);
  });

  test('unconfirmed results back off and legacy records retry promptly', () {
    final source = _source('one', 'retry.example');
    final now = DateTime.utc(2026, 11, 16);
    const failures = [
      BookSiteFinding.sameSiteRedirect,
      BookSiteFinding.externalRedirect,
      BookSiteFinding.httpError,
      BookSiteFinding.timeout,
      BookSiteFinding.networkError,
      BookSiteFinding.unsupported,
    ];
    for (final finding in failures) {
      final old = BookSiteCheck(
        BookSiteInspection(finding),
        now,
        bookSourceCheckFingerprint(source),
      ).toJson()..remove('consecutiveFailures');
      final legacy = BookSiteCheck.fromJson(old, source)!;
      expect(legacy.needsRetry, isTrue, reason: finding.name);
      expect(legacy.isDue(now.add(const Duration(minutes: 29))), isFalse);
      expect(legacy.isDue(now.add(const Duration(minutes: 30))), isTrue);
      expect(legacy.isDue(now.subtract(const Duration(minutes: 6))), isTrue);
      final next = BookSiteCheck.after(legacy.inspection, now, source, legacy);
      expect(next.consecutiveFailures, 2);
      expect(next.nextDue, now.add(const Duration(hours: 1)));
    }

    var check = BookSiteCheck.after(
      const BookSiteInspection(BookSiteFinding.timeout),
      now,
      source,
      null,
    );
    for (var i = 0; i < 20; i++) {
      check = BookSiteCheck.after(check.inspection, now, source, check);
    }
    expect(check.consecutiveFailures, 7);
    expect(check.nextDue, now.add(const Duration(hours: 24)));
    final saved = check.toJson();
    for (final count in [999999999, -1, 'invalid']) {
      final restored = BookSiteCheck.fromJson({
        ...saved,
        'consecutiveFailures': count,
      }, source)!;
      expect(
        restored.nextDue.difference(now),
        lessThanOrEqualTo(bookSiteMaxRetryInterval),
      );
      expect(restored.isDue(now.add(const Duration(hours: 24))), isTrue);
    }
    final recovered = BookSiteCheck.after(
      const BookSiteInspection(BookSiteFinding.sampled),
      now,
      source,
      check,
    );
    expect(recovered.consecutiveFailures, 0);
    expect(recovered.nextDue, now.add(const Duration(days: 7)));
    final changed = BookSource.fromJson({...source.toJson(), 'name': '新版来源'});
    final newVersion = BookSiteCheck.after(
      check.inspection,
      now,
      changed,
      check,
    );
    expect(newVersion.consecutiveFailures, 1);
  });
}

void _batchRiskTests() {
  test(
    'same host is fetched once and strong evidence covers both sources',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final one = _source('one', 'shared.example');
      final two = _source('two', 'shared.example');
      final entries = await fixture.add([one, two]);
      var calls = 0;
      final checks = BookSiteChecks(
        fixture.services.books,
        inspect: (source, token) async {
          calls++;
          return const BookSiteInspection(
            BookSiteFinding.gamblingClue,
            gamblingRisk: true,
          );
        },
      );
      await checks.run(entries, CancellationToken());
      expect(calls, 1);
      expect(
        await fixture.services.books.sourceEntry(BookKind.text, one.id),
        isNull,
      );
      expect(
        await fixture.services.books.sourceEntry(BookKind.text, two.id),
        isNull,
      );
      final risks = await fixture.services.books.sourceRiskEntries();
      expect(
        risks.any((risk) => risk.host == 'shared.example' && risk.quarantined),
        isTrue,
      );
    },
  );

  test('a risk notification does not cancel checking another host', () async {
    final fixture = await _Fixture.create(adultVerified: true);
    addTearDown(fixture.close);
    final one = _source('one', 'first-risk.example');
    final two = _source('two', 'second-risk.example');
    final entries = await fixture.add([one, two]);
    final token = CancellationToken();
    final policy = fixture.services.contentPolicy;
    var notifications = 0;
    void onPolicyChange() => notifications++;

    policy.addListener(onPolicyChange);
    addTearDown(() => policy.removeListener(onPolicyChange));
    final checks = BookSiteChecks(
      fixture.services.books,
      inspect: (source, token) async => const BookSiteInspection(
        BookSiteFinding.gamblingClue,
        gamblingRisk: true,
      ),
    );
    final result = await checks.run(entries, token);
    expect(result.quarantined, 2);
    expect(notifications, greaterThanOrEqualTo(2));
    expect(token.isCancelled, isFalse);
    expect(
      await fixture.services.books.sourceEntry(BookKind.text, one.id),
      isNull,
    );
    expect(
      await fixture.services.books.sourceEntry(BookKind.text, two.id),
      isNull,
    );
    // The run must remove its listener rather than cancel a completed token.
    await fixture.services.settings.update({'filterAdult': false});
    expect(token.isCancelled, isFalse);
  });
}

void _batchFailureTests() {
  test(
    'one failed site does not stop unrelated checks or change user choices',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final one = _source('one', 'failure.example');
      final two = _source('two', 'working.example');
      final entries = await fixture.add([one, two]);
      final checks = BookSiteChecks(
        fixture.services.books,
        inspect: (source, token) async {
          if (source.id == one.id) throw const FormatException('fixture error');
          return const BookSiteInspection(BookSiteFinding.sampled);
        },
      );
      final result = await checks.run(entries, CancellationToken());
      expect(result.failed, 1);
      expect(result.checked, 1);
      final failed = BookSiteCheck.fromJson(
        await fixture.services.books.store.read('books_site_check:${one.id}'),
        one,
      );
      expect(failed!.inspection.finding, BookSiteFinding.unsupported);
      expect(failed.needsRetry, isTrue);
      expect(failed.consecutiveFailures, 1);
      expect(
        await fixture.services.books.store.read('books_site_check:${two.id}'),
        isNotNull,
      );
      final after = await fixture.services.books.sourceEntry(
        BookKind.text,
        two.id,
      );
      expect(after!.enabled, isTrue);
      expect(after.favorite, isTrue);
    },
  );
}

void _inFlightInvalidationTests() {
  test('an adult-filter round trip still cancels a direct check', () async {
    final fixture = await _Fixture.create(adultVerified: true);
    addTearDown(fixture.close);
    await _expectPolicyRoundTripCancels(
      fixture,
      () => fixture.services.settings.update({'filterAdult': false}),
      () => fixture.services.settings.update({'filterAdult': true}),
    );
  });

  test('a disabled supervision rule round trip still cancels', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final supervision = fixture.services.supervision;
    final credentials = await supervision.prepareCredentials(
      'test-password-123',
    );
    await supervision.saveCredentials(credentials);
    Future<void> authorize(Future<void> Function() action) =>
        supervision.execute(
          SensitiveOperation.supervision,
          action,
          password: 'test-password-123',
        );
    await authorize(() => supervision.setEnabled(false));
    expect(supervision.enabled, isFalse);
    await _expectPolicyRoundTripCancels(
      fixture,
      () => authorize(
        () => supervision.updateRules(SupervisionRules(keywords: ['屏蔽词'])),
      ),
      () => authorize(() => supervision.updateRules(SupervisionRules())),
    );
  });

  for (final remove in [false, true]) {
    test(
      'stale result is discarded if a source is ${remove ? 'deleted' : 'updated'}',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.close);
        final source = _source('one', 'change.example');
        final entry = (await fixture.add([source])).single;
        final started = Completer<void>();
        final response = Completer<BookSiteInspection>();
        final checks = BookSiteChecks(
          fixture.services.books,
          inspect: (source, token) {
            started.complete();
            return response.future;
          },
        );
        final run = checks.run([entry], CancellationToken());
        await started.future;
        if (remove) {
          await fixture.services.books.removeSource(source);
        } else {
          final changed = BookSource.fromJson({
            ...source.toJson(),
            'name': '更新的来源',
          });
          await fixture.services.books.store.saveSource(source, {
            'source': changed.toJson(),
          });
        }
        response.complete(
          const BookSiteInspection(
            BookSiteFinding.gamblingClue,
            gamblingRisk: true,
          ),
        );
        expect((await run).checked, 0);
        expect(
          await fixture.services.books.store.read(
            'books_site_check:${source.id}',
          ),
          isNull,
        );
        expect(
          (await fixture.services.books.sourceRiskEntries()).where(
            (risk) => risk.host == 'change.example',
          ),
          isEmpty,
        );
      },
    );
  }

  test(
    'supervision changing in flight prevents a result or risk write',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final source = _source('one', 'supervision.example');
      final entry = (await fixture.add([source])).single;
      final draft = await fixture.services.supervision.prepareCredentials(
        'test-password-123',
      );
      final started = Completer<void>();
      final response = Completer<BookSiteInspection>();
      final checks = BookSiteChecks(
        fixture.services.books,
        inspect: (source, token) {
          started.complete();
          return response.future;
        },
      );
      final run = checks.run([entry], CancellationToken());
      await started.future;
      await fixture.services.supervision.saveCredentials(draft);
      response.complete(
        const BookSiteInspection(
          BookSiteFinding.gamblingClue,
          gamblingRisk: true,
        ),
      );
      await expectLater(run, throwsA(isA<RequestCancelled>()));
      expect(
        await fixture.services.books.store.read(
          'books_site_check:${source.id}',
        ),
        isNull,
      );
      expect(await fixture.services.books.riskStore.get(source.id), isNull);
    },
  );
}

Future<void> _expectPolicyRoundTripCancels(
  _Fixture fixture,
  Future<void> Function() change,
  Future<void> Function() restore,
) async {
  final source = _source('round-trip', 'policy-round-trip.example');
  final entry = (await fixture.add([source])).single;
  final started = Completer<void>();
  final response = Completer<BookSiteInspection>();
  addTearDown(() {
    if (!response.isCompleted) {
      response.complete(const BookSiteInspection(BookSiteFinding.sampled));
    }
  });
  final token = CancellationToken();
  final checks = BookSiteChecks(
    fixture.services.books,
    inspect: (_, _) {
      started.complete();
      return response.future;
    },
  );
  final originalPolicy = bookSitePolicySnapshot(fixture.services.contentPolicy);
  final running = expectLater(
    checks.run([entry], token, enabledOnly: true),
    throwsA(isA<RequestCancelled>()),
  );
  await started.future.timeout(const Duration(seconds: 5));
  await change().timeout(const Duration(seconds: 15));
  expect(token.isCancelled, isTrue);
  await restore().timeout(const Duration(seconds: 15));
  expect(
    bookSitePolicySnapshot(fixture.services.contentPolicy),
    originalPolicy,
  );
  expect(token.isCancelled, isTrue);
  response.complete(
    const BookSiteInspection(BookSiteFinding.gamblingClue, gamblingRisk: true),
  );
  await running.timeout(const Duration(seconds: 5));
  expect(await fixture.services.books.riskStore.get(source.id), isNull);
  expect(
    await fixture.services.books.store.read('books_site_check:${source.id}'),
    isNull,
  );
}

void _riskRetentionTests() {
  test('an ordinary later check never clears existing risk evidence', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final source = _source('one', 'old-risk.example');
    final entry = (await fixture.add([source])).single;
    await fixture.services.books.markSourceRisk(source, quarantine: true);
    final checks = BookSiteChecks(
      fixture.services.books,
      inspect: (source, token) async =>
          const BookSiteInspection(BookSiteFinding.sampled),
    );
    expect((await checks.run([entry], CancellationToken())).checked, 0);
    final risks = await fixture.services.books.sourceRiskEntries();
    expect(
      risks.any((risk) => risk.host == 'old-risk.example' && risk.quarantined),
      isTrue,
    );
  });
}

void _monitorLifecycleTests() {
  test('monitor close cancels and waits for manual work', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final checks = BookSiteChecks(fixture.services.books);
    final monitor = BookSiteMonitor(
      checks,
      fixture.services.settings,
      startDelay: const Duration(hours: 1),
    );
    monitor.start();
    final token = CancellationToken();
    final started = Completer<void>();
    final operation = monitor.whileManual(token, () async {
      started.complete();
      final stopped = Completer<void>();
      final unlink = token.listen(() => stopped.complete());
      try {
        await stopped.future;
        token.check();
      } finally {
        unlink();
      }
    });
    await started.future;
    final closing = monitor.close();
    await expectLater(operation, throwsA(isA<RequestCancelled>()));
    await closing;
  });

  test(
    'source-risk suspension cancels manual checks even before monitor start',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final checks = BookSiteChecks(fixture.services.books);
      final monitor = BookSiteMonitor(checks, fixture.services.settings);
      addTearDown(monitor.close);
      final token = CancellationToken();
      final started = Completer<void>();
      final operation = monitor.whileManual(token, () async {
        final stopped = Completer<void>();
        final unlink = token.listen(() => stopped.complete());
        started.complete();
        try {
          await stopped.future;
          token.check();
        } finally {
          unlink();
        }
      });
      await started.future;
      final cancelled = expectLater(
        operation,
        throwsA(isA<RequestCancelled>()),
      );
      fixture.services.books.suspendSourceRisks();
      await cancelled;
      await fixture.services.books.resumeSourceRisks();
    },
  );

  test(
    'background monitor cancellation waits for in-flight transport',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      await fixture.add([_source('one', 'background.example')]);
      final started = Completer<void>();
      final checks = BookSiteChecks(
        fixture.services.books,
        inspect: (source, token) async {
          if (!started.isCompleted) started.complete();
          final stopped = Completer<void>();
          final unlink = token.listen(() => stopped.complete());
          try {
            await stopped.future;
            token.check();
            return const BookSiteInspection(BookSiteFinding.sampled);
          } finally {
            unlink();
          }
        },
      );
      final monitor = BookSiteMonitor(
        checks,
        fixture.services.settings,
        startDelay: const Duration(hours: 1),
      );
      monitor.start();
      final running = monitor.check();
      await started.future;
      await monitor.close();
      await running;
    },
  );
}

void _monitorPolicyTests() {
  test('changing adult filtering cancels a running background check', () async {
    final fixture = await _Fixture.create(adultVerified: true);
    addTearDown(fixture.close);
    await fixture.services.settings.update({'filterAdult': false});
    final source = _source('one', 'filter-change.example');
    await fixture.add([source]);
    final started = Completer<void>();
    final checks = BookSiteChecks(
      fixture.services.books,
      inspect: (source, token) async {
        if (!started.isCompleted) started.complete();
        final stopped = Completer<void>();
        final unlink = token.listen(() => stopped.complete());
        try {
          await stopped.future;
          token.check();
          return const BookSiteInspection(BookSiteFinding.sampled);
        } finally {
          unlink();
        }
      },
    );
    final monitor = BookSiteMonitor(
      checks,
      fixture.services.settings,
      startDelay: const Duration(hours: 1),
    );
    monitor.start();
    final running = monitor.check();
    await started.future;
    await fixture.services.settings.update({'filterAdult': true});
    await running;
    expect(
      await fixture.services.books.store.read('books_site_check:${source.id}'),
      isNull,
    );
    await monitor.close();
  });
}

void _monitorRetryTests() {
  test(
    'due failures do not starve older samples and a recovered host is blocked',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final repo = fixture.services.books;
      final failing = List.generate(
        25,
        (i) => _source('retry-$i', 'retry-$i.example'),
      );
      final normal = _source('normal-due', 'normal-due.example');
      final sources = [...failing, normal];
      await fixture.add(sources);
      final ids = sources.map((source) => source.id).toSet();
      for (final kind in BookKind.values) {
        final others = (await repo.sources(kind, enabledOnly: true))
            .where((entry) => !ids.contains(entry.source.id))
            .map((entry) => entry.source.id)
            .toSet();
        await repo.setSourcesEnabled(kind, others, false);
      }
      final now = DateTime.now();
      for (final source in failing) {
        await repo.store.write(
          'books_site_check:${source.id}',
          BookSiteCheck(
            const BookSiteInspection(BookSiteFinding.timeout),
            now.subtract(const Duration(minutes: 31)),
            bookSourceCheckFingerprint(source),
            consecutiveFailures: 1,
          ).toJson(),
        );
      }
      await repo.store.write(
        'books_site_check:${normal.id}',
        BookSiteCheck(
          const BookSiteInspection(BookSiteFinding.sampled),
          now.subtract(const Duration(days: 8)),
          bookSourceCheckFingerprint(normal),
        ).toJson(),
      );
      final requested = <String>[];
      var recovered = false;
      final monitor = BookSiteMonitor(
        BookSiteChecks(
          repo,
          inspect: (source, _) async {
            requested.add(source.id);
            if (source.id == normal.id) {
              return const BookSiteInspection(BookSiteFinding.sampled);
            }
            if (source.id == failing.first.id && recovered) {
              return const BookSiteInspection(
                BookSiteFinding.gamblingClue,
                gamblingRisk: true,
              );
            }
            return const BookSiteInspection(BookSiteFinding.timeout);
          },
        ),
        fixture.services.settings,
        startDelay: const Duration(hours: 1),
        interval: const Duration(hours: 1),
      );
      addTearDown(monitor.close);
      monitor.start();
      await monitor.check().timeout(const Duration(seconds: 10));
      expect(requested, hasLength(20));
      expect(requested, contains(normal.id));
      await monitor.check().timeout(const Duration(seconds: 10));
      expect(requested, hasLength(26));
      expect(requested.toSet(), ids);

      final raw = await repo.store.read('books_site_check:${failing.first.id}');
      final failed = BookSiteCheck.fromJson(raw, failing.first)!;
      expect(failed.consecutiveFailures, 2);
      expect(failed.needsRetry, isTrue);
      await repo.store.write('books_site_check:${failing.first.id}', {
        ...failed.toJson(),
        'checkedAt': now
            .subtract(const Duration(hours: 2))
            .millisecondsSinceEpoch,
      });
      recovered = true;
      await monitor.check().timeout(const Duration(seconds: 10));
      expect((await repo.riskStore.get(failing.first.id))!.quarantined, isTrue);
    },
  );
}

BookSource _source(String key, String host) => BookSource.fromJson({
  'name': '示例 $key',
  'kind': 'text',
  'format': 'feed',
  'url': 'https://$host/feed?token=private',
  'sourceKey': 'fixture:$key',
});

final class _Fixture {
  _Fixture(this.root, this.services);
  final Directory root;
  final AppServices services;

  static Future<_Fixture> create({bool adultVerified = false}) async {
    final root = await Directory.systemTemp.createTemp('book-site-check-');
    final services = AppServices.scoped(root, AppDatabase.memory());
    if (adultVerified) {
      await services.db.write(
        'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
        [installationAccessKey, upgradedInstallationAccess],
      );
    }
    await services.supervision.load();
    await services.settings.load();
    return _Fixture(root, services);
  }

  Future<List<BookSourceEntry>> add(List<BookSource> sources) async {
    final changes = await services.books.importSources(sources);
    expect(changes.added, sources.length);
    for (final source in sources) {
      await services.books.saveSource(source, {
        'enabled': true,
        'favorite': true,
      });
    }
    final entries = await services.books.sources(BookKind.text);
    return entries
        .where((entry) => sources.any((s) => s.id == entry.source.id))
        .toList();
  }

  Future<void> close() async {
    await services.close();
    await root.delete(recursive: true);
  }
}
