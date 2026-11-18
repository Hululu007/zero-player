import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/persistence/installation_metadata.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/data/books_repository.dart';
import 'package:zero_player/features/books/data/book_policy_evidence.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _sourceCommitRaces();
  _configurationAndSuspensionRaces();
  _workEvidenceRace();
}

void _sourceCommitRaces() {
  test(
    'an old reload cannot erase a finding committed after its reads',
    () async {
      final f = await _Fixture.create();
      final paused = await f.pauseReload();
      await f.services.books.markSourceRisk(f.source, quarantine: true);
      expect(f.services.books.sourceAllowed(f.source), isFalse);
      paused.release.complete();
      await paused.done;
      expect(paused.reads, greaterThanOrEqualTo(3));
      expect(f.services.books.sourceRisksReady, isTrue);
      expect(f.services.books.sourceAllowed(f.source), isFalse);
      expect(
        (await f.services.books.sourceRiskEntries())
            .singleWhere((row) => row.sourceId == f.source.id)
            .quarantined,
        isTrue,
      );
      expect(
        (await f.services.books.riskStore.get(f.source.id))!.quarantined,
        isTrue,
      );
    },
  );

  test(
    'an old reload cannot restore a finding cleared after its reads',
    () async {
      final f = await _Fixture.create();
      await f.services.books.markSourceRisk(f.source, quarantine: true);
      final row = (await f.services.books.sourceRiskEntries()).singleWhere(
        (row) => row.sourceId == f.source.id,
      );
      final paused = await f.pauseReload();
      await f.services.books.clearSourceRisk(row);
      expect(f.services.books.sourceAllowed(f.source), isTrue);
      paused.release.complete();
      await paused.done;
      expect(paused.reads, greaterThanOrEqualTo(3));
      expect(f.services.books.sourceAllowed(f.source), isTrue);
      expect(f.services.books.sourceRiskEntryAllowed(row), isFalse);
      expect(
        (await f.services.books.sourceRiskEntries()).where(
          (row) => row.sourceId == f.source.id,
        ),
        isEmpty,
      );
      final persisted = (await f.services.books.riskStore.get(f.source.id))!;
      expect(persisted.quarantined, isFalse);
      expect(persisted.version, greaterThan(row.version));
    },
  );
}

void _configurationAndSuspensionRaces() {
  test(
    'a configuration commit invalidates an older source and group snapshot',
    () async {
      final f = await _Fixture.create();
      final paused = await f.pauseReload();
      await f.services.books.saveSource(f.source, {'group': '成人小说'});
      paused.release.complete();
      await paused.done;
      await f.services.settings.update({'filterAdult': true});
      final entry = (await f.services.books.store.source(null, f.source.id))!;
      expect(entry.group, '成人小说');
      expect(f.services.books.sourceEntryAllowed(entry), isFalse);
      final book = Book(
        f.source.id,
        BookKind.text,
        '普通作品',
        '',
        f.source.endpoint.resolve('/book'),
      );
      expect(f.services.books.bookAllowed(book), isFalse);
      expect(
        await f.services.books.sourceEntry(BookKind.text, f.source.id),
        isNull,
      );
    },
  );

  test(
    'suspension during reload refuses publication until resume rereads',
    () async {
      final f = await _Fixture.create();
      final paused = await f.pauseReload();
      final blocked = expectLater(paused.done, throwsA(isA<ContentBlocked>()));
      f.services.books.suspendSourceRisks();
      expect(f.services.books.sourceRisksSuspended, isTrue);
      expect(f.services.books.sourceAllowed(f.source), isFalse);
      paused.release.complete();
      await blocked;
      expect(f.services.books.sourceRisksReady, isFalse);
      f.services.books.beforeSourceRiskPublishForTesting = null;
      await f.services.books.resumeSourceRisks();
      expect(f.services.books.sourceRisksReady, isTrue);
      expect(f.services.books.sourceAllowed(f.source), isTrue);
    },
  );
}

void _workEvidenceRace() {
  test('a source reload cannot restore reviewed work evidence', () async {
    final f = await _Fixture.create();
    final book = Book(
      f.source.id,
      BookKind.text,
      '普通作品',
      '',
      f.source.endpoint.resolve('/book'),
    );
    await f.services.books.store.saveBook(book);
    final evidence = BookPolicyEvidenceStore(f.services.db);
    await evidence.merge(book.id, BookPolicyEvidence(adult: true), () {});
    await f.services.books.refreshSourceRisks();
    final review = (await f.services.books.bookPolicyReviewEntries()).single;
    final paused = await f.pauseReload();
    await f.services.books.clearBookAdultEvidence(review);
    paused.release.complete();
    await paused.done;
    expect(paused.reads, greaterThanOrEqualTo(3));
    await f.services.settings.update({'filterAdult': true});
    expect(f.services.books.bookAllowed(book), isTrue);
    expect((await evidence.load())[book.id]!.adult, isFalse);
    expect(
      (await evidence.load())[book.id]!.revision,
      greaterThan(review.revision),
    );
  });
}

final class _PausedReload {
  final entered = Completer<void>();
  final release = Completer<void>();
  late final Future<void> done;
  int reads = 0;

  Future<void> beforePublish() async {
    if (++reads != 1) return;
    entered.complete();
    await release.future;
  }
}

final class _Fixture {
  _Fixture(this.services);
  final AppServices services;
  final source = BookSource.fromJson({
    'name': '快照测试源',
    'kind': 'text',
    'format': 'feed',
    'url': 'https://snapshot.example/',
    'sourceKey': 'snapshot-race',
  });

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('book-source-snapshot-');
    final services = AppServices.scoped(root, AppDatabase.memory());
    addTearDown(() async {
      await services.close();
      await root.delete(recursive: true);
    });
    await services.db.write('INSERT OR REPLACE INTO app_meta VALUES(?,?)', [
      installationAccessKey,
      upgradedInstallationAccess,
    ]);
    await services.settings.load();
    await services.supervision.load();
    await services.settings.update({'filterAdult': false});
    final f = _Fixture(services);
    await services.books.importSources([f.source]);
    await services.books.saveSource(f.source, {'enabled': true});
    return f;
  }

  Future<_PausedReload> pauseReload() async {
    final paused = _PausedReload();
    services.books.beforeSourceRiskPublishForTesting = paused.beforePublish;
    // Always unblock on failed assertions before disposing shared services.
    addTearDown(() async {
      if (!paused.release.isCompleted) paused.release.complete();
      services.books.beforeSourceRiskPublishForTesting = null;
      try {
        await paused.done;
      } on ContentBlocked {
        // Expected when the fixture suspends the in-flight reload.
      }
    });
    paused.done = services.books.refreshSourceRisks();
    await paused.entered.future;
    return paused;
  }
}
