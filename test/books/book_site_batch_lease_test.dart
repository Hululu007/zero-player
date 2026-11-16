import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/application/book_site_checks.dart';
import 'package:zero_player/features/books/data/book_site_inspection.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/domain/book.dart';

import '../../test_support/verified_temp_directory.dart';

const _timeout = Duration(seconds: 8);
const _sale =
    '<html><body><h1>This domain is for sale</h1>'
    '<h3>Contact the owner</h3><form></form></body></html>';

BookSource _source(String name, String host) => BookSource.fromJson({
  'name': name,
  'kind': 'text',
  'format': 'feed',
  'url': 'https://$host/feed',
  'sourceKey': 'lease:$name',
});

Uri _root(BookSource source) =>
    Uri(scheme: 'https', host: source.endpoint.host, path: '/');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'different manual instances cannot overwrite an in-flight strong result',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final one = _source('一', 'lease-one.example');
      final two = _source('二', 'lease-two.example');
      final entries = await f.add([one, two]);
      final byId = {for (final entry in entries) entry.source.id: entry};
      final started = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final first = BookSiteChecks(
        f.services.books,
        inspect: (_, _) async {
          started.complete();
          await release.future;
          return const BookSiteInspection(
            BookSiteFinding.gamblingClue,
            gamblingRisk: true,
          );
        },
      );
      final second = BookSiteChecks(
        f.services.books,
        inspect: (source, _) async =>
            inspectBookSiteHtml(_root(source), '<html><body>普通</body></html>'),
      );
      final running = first.run([byId[one.id]!], CancellationToken());
      await started.future.timeout(_timeout);
      await expectLater(
        second.run([byId[two.id]!], CancellationToken()),
        throwsFormatException,
      );
      release.complete();
      final result = await running.timeout(_timeout);
      expect(result.quarantined, 1);
      expect(
        (await f.services.books.riskStore.get(one.id))!.quarantinedHost,
        isTrue,
      );
      expect(f.services.books.sourceAllowed(one), isFalse);
      expect(
        (await second.run([byId[two.id]!], CancellationToken())).checked,
        1,
      );
    },
  );

  test(
    'one batch still reuses a host sample for independent source ids',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final one = _source('同域一', 'lease-shared.example');
      final two = _source('同域二', 'lease-shared.example');
      final entries = await f.add([one, two]);
      var calls = 0;
      final checks = BookSiteChecks(
        f.services.books,
        inspect: (source, _) async {
          calls++;
          return inspectBookSiteHtml(_root(source), _sale);
        },
      );
      expect((await checks.run(entries, CancellationToken())).checked, 2);
      expect(calls, 1);
      final stored = await checks.load(entries);
      expect(stored[one.id]!.pendingSaleClue, isNotNull);
      expect(stored[two.id]!.pendingSaleClue, isNotNull);
      expect(await f.services.books.riskStore.get(one.id), isNull);
      expect(await f.services.books.riskStore.get(two.id), isNull);
    },
  );

  test('an exceptional batch releases the lease and permits retry', () async {
    final f = await _Fixture.create();
    addTearDown(f.close);
    final source = _source('异常', 'lease-error.example');
    final entry = (await f.add([source])).single;
    final failing = BookSiteChecks(
      f.services.books,
      inspect: (_, _) async => throw StateError('controlled'),
    );
    final callerToken = CancellationToken();
    await expectLater(failing.run([entry], callerToken), throwsStateError);
    expect(callerToken.isCancelled, isTrue);
    final retry = BookSiteChecks(
      f.services.books,
      inspect: (_, _) async =>
          const BookSiteInspection(BookSiteFinding.sampled),
    );
    expect((await retry.run([entry], CancellationToken())).checked, 1);
  });

  test(
    'manual caller cancellation reaches the same active request token',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final source = _source('取消', 'lease-cancel.example');
      final entry = (await f.add([source])).single;
      final started = Completer<void>();
      final cancelled = Completer<void>();
      final callerToken = CancellationToken();
      final checks = BookSiteChecks(
        f.services.books,
        inspect: (_, token) async {
          expect(identical(token, callerToken), isTrue);
          final unlink = token.listen(() {
            if (!cancelled.isCompleted) cancelled.complete();
          });
          started.complete();
          try {
            await cancelled.future;
            token.check();
            throw StateError('cancelled request should not complete');
          } finally {
            unlink();
          }
        },
      );
      final running = expectLater(
        checks.run([entry], callerToken),
        throwsA(isA<RequestCancelled>()),
      );
      await started.future.timeout(_timeout);
      callerToken.cancel();
      await running.timeout(_timeout);
      final retry = BookSiteChecks(
        f.services.books,
        inspect: (_, _) async =>
            const BookSiteInspection(BookSiteFinding.sampled),
      );
      expect((await retry.run([entry], CancellationToken())).checked, 1);
    },
  );

  test(
    'close cancels a direct batch and waits through committed risk publication',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final source = _source('关闭', 'lease-close.example');
      final entry = (await f.add([source])).single;
      final committed = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final repo = f.services.books;
      repo.afterSiteRiskCommitForTesting = () async {
        committed.complete();
        await release.future;
      };
      final checks = BookSiteChecks(
        repo,
        inspect: (_, _) async => const BookSiteInspection(
          BookSiteFinding.gamblingClue,
          gamblingRisk: true,
        ),
      );
      final running = expectLater(
        checks.run([entry], CancellationToken()),
        throwsA(isA<RequestCancelled>()),
      );
      await committed.future.timeout(_timeout);
      expect((await repo.riskStore.get(source.id))!.quarantinedHost, isTrue);
      var closed = false;
      final closing = repo.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      await expectLater(
        BookSiteChecks(repo).run([], CancellationToken()),
        throwsStateError,
      );
      release.complete();
      await running.timeout(_timeout);
      await closing.timeout(_timeout);
      expect(repo.sourceAllowed(source), isFalse);
    },
  );

  test(
    'close drains a direct batch after a cancellation listener throws',
    () async {
      final f = await _Fixture.create();
      final failure = StateError('controlled cancellation failure');
      addTearDown(() => _closeAfterExpectedFailure(f, failure));
      final source = _source('监听器异常', 'lease-listener.example');
      final entry = (await f.add([source])).single;
      final caller = CancellationToken()..listen(() => throw failure);
      final started = Completer<void>(), cancelled = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final checks = BookSiteChecks(
        f.services.books,
        inspect: (_, token) async {
          expect(identical(token, caller), isTrue);
          final unlink = token.listen(() {
            if (!cancelled.isCompleted) cancelled.complete();
          });
          started.complete();
          try {
            await release.future;
            token.check();
            throw StateError('cancelled request should not complete');
          } finally {
            unlink();
          }
        },
      );
      final running = expectLater(
        checks.run([entry], caller),
        throwsA(isA<RequestCancelled>()),
      );
      await started.future.timeout(_timeout);
      final repo = f.services.books;
      var finished = false;
      final closing = expectLater(
        repo.close(),
        throwsA(same(failure)),
      ).then((_) => finished = true);
      await cancelled.future.timeout(_timeout);
      expect(caller.isCancelled, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      release.complete();
      await running.timeout(_timeout);
      await closing.timeout(_timeout);
      expect(
        () => repo.sourceConfigurationChanges.addListener(() {}),
        throwsA(isA<FlutterError>()),
      );
    },
  );

  test(
    'throwing close listener cannot suppress committed risk publication',
    () async {
      final f = await _Fixture.create();
      final failure = StateError('controlled close failure');
      addTearDown(() => _closeAfterExpectedFailure(f, failure));
      final source = _source('已提交', 'lease-commit-listener.example');
      final entry = (await f.add([source])).single;
      var laterListener = false;
      final caller = CancellationToken()
        ..listen(() => throw failure)
        ..listen(() => laterListener = true);
      final committed = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final repo = f.services.books;
      repo.afterSiteRiskCommitForTesting = () async {
        committed.complete();
        await release.future;
      };
      final checks = BookSiteChecks(
        repo,
        inspect: (_, _) async => const BookSiteInspection(
          BookSiteFinding.gamblingClue,
          gamblingRisk: true,
        ),
      );
      final running = expectLater(
        checks.run([entry], caller),
        throwsA(isA<RequestCancelled>()),
      );
      await committed.future.timeout(_timeout);
      expect((await repo.riskStore.get(source.id))!.quarantinedHost, isTrue);
      var finished = false;
      final closing = expectLater(
        repo.close(),
        throwsA(same(failure)),
      ).then((_) => finished = true);
      await Future<void>.delayed(Duration.zero);
      expect(laterListener, isTrue);
      expect(finished, isFalse);
      release.complete();
      await running.timeout(_timeout);
      await closing.timeout(_timeout);
      expect(repo.sourceAllowed(source), isFalse);
      expect(
        () => repo.sourceConfigurationChanges.addListener(() {}),
        throwsA(isA<FlutterError>()),
      );
    },
  );
}

Future<void> _closeAfterExpectedFailure(
  _Fixture fixture,
  Object expected,
) async {
  try {
    await fixture.services.close();
  } catch (error) {
    if (!identical(error, expected)) rethrow;
  } finally {
    await fixture.temp.delete();
  }
}

final class _Fixture {
  _Fixture(this.temp, this.services);
  final VerifiedTempDirectory temp;
  final AppServices services;

  static Future<_Fixture> create() async {
    final temp = await VerifiedTempDirectory.create('book-site-lease-');
    final services = AppServices.scoped(temp.directory, AppDatabase.memory());
    await services.supervision.load();
    await services.settings.load();
    return _Fixture(temp, services);
  }

  Future<List<BookSourceEntry>> add(List<BookSource> sources) async {
    await services.books.importSources(sources);
    return (await services.books.sources(BookKind.text))
        .where((entry) => sources.any((source) => source.id == entry.source.id))
        .toList();
  }

  Future<void> close() async {
    await services.close();
    await temp.delete();
  }
}
