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
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/domain/book.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _storedCheckTests();
  _batchRiskTests();
  _batchFailureTests();
  _inFlightInvalidationTests();
  _riskRetentionTests();
  _monitorLifecycleTests();
  _monitorPolicyTests();
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
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final one = _source('one', 'first-risk.example');
    final two = _source('two', 'second-risk.example');
    final entries = await fixture.add([one, two]);
    final token = CancellationToken();
    final policy = fixture.services.contentPolicy;
    var snapshot = bookSitePolicySnapshot(policy);
    var notifications = 0;
    void onPolicyChange() {
      notifications++;
      final next = bookSitePolicySnapshot(policy);
      if (next != snapshot) token.cancel();
      snapshot = next;
    }

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
      expect(
        await fixture.services.books.store.read('books_site_check:${one.id}'),
        isNull,
      );
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
      await expectLater(run, throwsA(isA<FormatException>()));
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
