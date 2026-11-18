import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/persistence/installation_metadata.dart';
import 'package:zero_player/features/books/data/book_policy_evidence.dart';
import 'package:zero_player/features/books/data/book_policy_tracker.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/settings/application/settings_controller.dart';
import 'package:zero_player/features/supervision/application/content_policy.dart';
import 'package:zero_player/features/supervision/application/supervision_controller.dart';

void main() {
  _observationTests();
  _reviewTests();
  _pendingTests();
  _failureTests();
  _snapshotTests();
}

void _observationTests() {
  test(
    'closing an observation twice cannot finish another registration',
    () async {
      final f = await _Fixture.create();
      f.tracker.mergeLoaded({f.book.id: BookPolicyEvidence(adult: true)});
      final first = f.tracker.startObservation(f.book.id);
      final second = f.tracker.startObservation(f.book.id);
      expect(f.tracker.observationSequence(f.book.id), 2);
      first.close();
      first.close();
      second.check();
      expect(first.check, throwsA(isA<RequestCancelled>()));
      expect(f.tracker.reviewableEvidence(f.book.id), isNull);
      second.close();
      expect(f.tracker.reviewableEvidence(f.book.id), isNotNull);
    },
  );

  test(
    'observation completion invalidates a previously displayed review',
    () async {
      final f = await _Fixture.create();
      f.tracker.mergeLoaded({f.book.id: BookPolicyEvidence(adult: true)});
      final row = f.reviewRow();
      expect(f.tracker.matchesReview(row), isTrue);
      final observation = f.tracker.startObservation(f.book.id);
      expect(f.tracker.matchesReview(row), isFalse);
      observation.close();
      expect(f.tracker.matchesReview(row), isFalse);
      expect(f.tracker.matchesReview(f.reviewRow()), isTrue);
    },
  );

  test(
    'shutdown rejects new work and drains existing observations silently',
    () async {
      final f = await _Fixture.create();
      var notifications = 0;
      f.tracker.observationChanges.addListener(() => notifications++);
      final observation = f.tracker.startObservation(f.book.id);
      expect(notifications, 1);
      f.tracker.beginClose();
      expect(
        () => f.tracker.startObservation(f.book.id),
        throwsA(isA<RequestCancelled>()),
      );
      expect(() => f.tracker.startReview(f.book.id), throwsFormatException);
      observation.close();
      expect(notifications, 1);
    },
  );
}

void _reviewTests() {
  test('review lock excludes observations and releases exactly once', () async {
    final f = await _Fixture.create();
    final review = f.tracker.startReview(f.book.id);
    review.notifyStarted();
    expect(
      () => f.tracker.startObservation(f.book.id),
      throwsA(isA<RequestCancelled>()),
    );
    expect(() => f.tracker.startReview(f.book.id), throwsFormatException);
    final started = f.tracker.generation;
    review.close();
    review.close();
    expect(f.tracker.generation, started + 1);
    expect(() => review.publish(BookPolicyEvidence()), throwsStateError);
    f.tracker.startObservation(f.book.id).close();
  });

  test(
    'review publication during shutdown keeps its committed result',
    () async {
      final f = await _Fixture.create();
      f.tracker.mergeLoaded({
        f.book.id: BookPolicyEvidence(adult: true, revision: 2),
      });
      final review = f.tracker.startReview(f.book.id);
      review.notifyStarted();
      f.tracker.beginClose();
      review.publish(BookPolicyEvidence(adult: false, revision: 3));
      review.close();
      await f.settings.update({'filterAdult': true});
      expect(f.tracker.allows(f.book), isTrue);
      expect(f.tracker.reviewableEvidence(f.book.id), isNull);
    },
  );
}

void _pendingTests() {
  test(
    'pending observations block immediately and own separate cleanup',
    () async {
      final f = await _Fixture.create();
      await f.settings.update({'filterAdult': true});
      final first = _Gate(), second = _Gate();
      var firstValid = true, secondValid = true;
      final firstWrite = f.remember(
        f.adult,
        authorize: () {
          if (!firstValid) throw const RequestCancelled();
        },
        afterCommit: first.wait,
      );
      await first.entered.future;
      final secondWrite = f.remember(
        f.adult,
        authorize: () {
          if (!secondValid) throw const RequestCancelled();
        },
        afterCommit: second.wait,
      );
      await second.entered.future;
      expect(f.tracker.pendingCount(f.book.id), 2);
      expect(f.tracker.allows(f.book), isFalse);
      firstValid = false;
      final firstRejected = expectLater(
        firstWrite,
        throwsA(isA<RequestCancelled>()),
      );
      first.release.completeError(const RequestCancelled());
      await firstRejected;
      expect(f.tracker.pendingCount(f.book.id), 1);
      expect(f.tracker.allows(f.book), isFalse);
      secondValid = false;
      final secondRejected = expectLater(
        secondWrite,
        throwsA(isA<RequestCancelled>()),
      );
      second.release.completeError(const RequestCancelled());
      await secondRejected;
      expect(f.tracker.pendingCount(f.book.id), 0);
      expect(f.tracker.allows(f.book), isTrue);
      // Both writes committed before the simulated stale-source failures.
      // The next reload must still honor the durable evidence.
      f.tracker.mergeLoaded(await f.store.load());
      expect(f.tracker.allows(f.book), isFalse);
    },
  );

  test(
    'metadata for another work never enters evidence or pending state',
    () async {
      final f = await _Fixture.create();
      final other = Book(
        f.book.sourceId,
        BookKind.text,
        '成人',
        '',
        Uri.parse('https://books.example/other'),
      );
      await f.remember(other);
      expect(f.tracker.pendingCount(f.book.id), 0);
      expect(await f.store.load(), isEmpty);
    },
  );
}

void _failureTests() {
  test(
    'authorized write failure retains evidence while cancelled input is discarded',
    () async {
      final f = await _Fixture.create();
      await f.settings.update({'filterAdult': true});
      await f.db.customStatement("""
      CREATE TRIGGER reject_work_evidence BEFORE INSERT ON app_meta
      WHEN NEW.key GLOB 'books_book_policy:*'
      BEGIN SELECT RAISE(ABORT, 'fixture storage failure'); END
    """);
      await expectLater(
        f.remember(f.adult),
        throwsA(
          predicate<Object>(
            (error) => error.toString().contains('fixture storage failure'),
          ),
        ),
      );
      expect(f.tracker.pendingCount(f.book.id), 0);
      expect(f.tracker.allows(f.book), isFalse);
      expect(await f.store.load(), isEmpty);
      final other = await _Fixture.create();
      await other.settings.update({'filterAdult': true});
      await expectLater(
        other.remember(
          other.adult,
          authorize: () => throw const RequestCancelled(),
        ),
        throwsA(isA<RequestCancelled>()),
      );
      expect(other.tracker.pendingCount(other.book.id), 0);
      expect(other.tracker.allows(other.book), isTrue);
      expect(await other.store.load(), isEmpty);
    },
  );
}

void _snapshotTests() {
  test(
    'reviewed revision rejects old adult snapshots and preserves damage',
    () async {
      final f = await _Fixture.create();
      f.tracker.mergeLoaded({
        f.book.id: BookPolicyEvidence(adult: true, revision: 4),
      });
      final review = f.tracker.startReview(f.book.id);
      review.publish(BookPolicyEvidence(revision: 5));
      review.close();
      f.tracker.mergeLoaded({
        f.book.id: BookPolicyEvidence(adult: true, revision: 4),
      });
      await f.settings.update({'filterAdult': true});
      expect(f.tracker.allows(f.book), isTrue);
      f.tracker.mergeLoaded({f.book.id: BookPolicyEvidence(uncertain: true)});
      expect(f.tracker.allows(f.book), isFalse);
    },
  );

  test(
    'policy revision changes without mutating observation history',
    () async {
      final f = await _Fixture.create();
      final revision = f.tracker.policyRevision;
      await f.settings.update({'filterAdult': true});
      expect(f.tracker.policyRevision, greaterThan(revision));
      expect(f.tracker.observationSequence(f.book.id), 0);
    },
  );
}

final class _Gate {
  final entered = Completer<void>(), release = Completer<void>();
  Future<void> wait() async {
    entered.complete();
    await release.future;
  }
}

final class _Fixture {
  _Fixture(this.db, this.settings, this.store, this.tracker);
  final AppDatabase db;
  final SettingsController settings;
  final BookPolicyEvidenceStore store;
  final BookPolicyTracker tracker;
  final book = Book(
    'source-fixture',
    BookKind.text,
    '普通作品',
    '',
    Uri.parse('https://books.example/book'),
  );
  late final adult = Book(
    book.sourceId,
    book.kind,
    book.title,
    '',
    book.uri,
    category: '成人',
  );

  static Future<_Fixture> create() async {
    final db = AppDatabase.memory();
    await db.write('INSERT OR REPLACE INTO app_meta VALUES(?,?)', [
      installationAccessKey,
      upgradedInstallationAccess,
    ]);
    final settings = SettingsController(db);
    final supervision = SupervisionController(db);
    final policy = ContentPolicy(settings, supervision);
    final store = BookPolicyEvidenceStore(db);
    final tracker = BookPolicyTracker(policy: policy, store: store);
    addTearDown(() async {
      tracker.dispose();
      policy.dispose();
      supervision.dispose();
      settings.dispose();
      await db.close();
    });
    await settings.load();
    await supervision.load();
    await settings.update({'filterAdult': false});
    return _Fixture(db, settings, store, tracker);
  }

  Future<void> remember(
    Book details, {
    void Function()? authorize,
    Future<void> Function()? afterCommit,
  }) => tracker.rememberMetadata(
    book,
    details,
    bookAllowed: tracker.allows,
    authorize: authorize ?? () {},
    afterCommit: afterCommit,
  );

  BookPolicyReviewEntry reviewRow() {
    final evidence = tracker.reviewableEvidence(book.id)!;
    return BookPolicyReviewEntry(
      book: book,
      revision: evidence.revision,
      digest: evidence.snapshotDigest,
      sourceRevision: 0,
      policyRevision: tracker.policyRevision,
      observationSequence: tracker.observationSequence(book.id),
    );
  }
}
