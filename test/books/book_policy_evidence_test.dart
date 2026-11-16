import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_policy_evidence.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('concurrent observations merge without exposing metadata', () async {
    final db = AppDatabase.memory();
    try {
      final store = BookPolicyEvidenceStore(db);
      final id = List.filled(64, '1').join();
      final keyword = List.filled(64, 'a').join();
      await Future.wait([
        store.merge(id, BookPolicyEvidence(adult: true), () {}),
        store.merge(id, BookPolicyEvidence(keywordHashes: {keyword}), () {}),
      ]);
      final observed = (await store.load())[id]!;
      expect(observed.adult, isTrue);
      expect(observed.keywordHashes, {keyword});
      expect(observed.uncertain, isFalse);
      final raw =
          (await db.rows('SELECT value FROM app_meta WHERE key=?', [
                BookPolicyEvidenceStore.key(id),
              ])).single['value']
              as String;
      expect(jsonDecode(raw), {
        'version': 2,
        'revision': 2,
        'adult': true,
        'keywords': [keyword],
        'texts': <String>[],
        'latest': '',
        'incomplete': false,
      });
    } finally {
      await db.close();
    }
  });

  test('routine chapter updates do not exhaust stable metadata history', () {
    var evidence = BookPolicyEvidence();
    for (var index = 0; index < 40; index++) {
      evidence = evidence.merge(
        BookPolicyEvidence(
          normalizedTexts: {'普通作品作者玄幻'},
          latestText: '普通作品作者玄幻第$index章',
        ),
      );
    }
    expect(evidence.textCoverageIncomplete, isFalse);
    expect(evidence.normalizedTexts, {'普通作品作者玄幻'});
    expect(evidence.latestText, '普通作品作者玄幻第39章');
    final restored = BookPolicyEvidence.decode(jsonEncode(evidence.toJson()));
    expect(restored.uncertain, isFalse);
    expect(restored.latestText, evidence.latestText);
  });

  test('older snapshots cannot restore a reviewed flag', () {
    final old = BookPolicyEvidence(adult: true, revision: 1);
    final reviewed = old.withRevision(2, adult: false);
    expect(reviewed.mergeLoadedSnapshot(old).adult, isFalse);
    expect(reviewed.mergeLoadedSnapshot(old.withRevision(3)).adult, isTrue);
    expect(
      reviewed
          .mergeLoadedSnapshot(BookPolicyEvidence(uncertain: true))
          .uncertain,
      isTrue,
    );
  });

  test(
    'each adult observation advances revision even if contents match',
    () async {
      final db = AppDatabase.memory();
      try {
        final store = BookPolicyEvidenceStore(db);
        final id = List.filled(64, '4').join();
        final evidence = BookPolicyEvidence(adult: true);
        final first = await store.merge(id, evidence, () {});
        final second = await store.merge(id, evidence, () {});
        expect(second.revision, first.revision + 1);
        expect(
          second.withRevision(first.revision).snapshotDigest,
          first.snapshotDigest,
        );
        await expectLater(
          store.clearAdult(
            id: id,
            revision: first.revision,
            digest: first.snapshotDigest,
            authorize: () {},
            validate: () async {},
          ),
          throwsFormatException,
        );
        expect((await store.load())[id]!.adult, isTrue);
      } finally {
        await db.close();
      }
    },
  );

  test(
    'v1 evidence upgrades and review uses the exact stored revision',
    () async {
      final db = AppDatabase.memory();
      try {
        final store = BookPolicyEvidenceStore(db);
        final id = List.filled(64, '3').join();
        await db.write('INSERT INTO app_meta(key,value) VALUES(?,?)', [
          BookPolicyEvidenceStore.key(id),
          jsonEncode({
            'version': 1,
            'adult': true,
            'keywords': <String>[],
            'texts': <String>[],
            'latest': '',
            'incomplete': false,
          }),
        ]);
        final old = (await store.load())[id]!;
        expect(old.revision, 0);
        expect(old.adult, isTrue);
        final cleared = await store.clearAdult(
          id: id,
          revision: old.revision,
          digest: old.snapshotDigest,
          authorize: () {},
          validate: () async {},
        );
        expect(cleared.revision, 1);
        expect(cleared.adult, isFalse);
        final newer = await store.merge(
          id,
          BookPolicyEvidence(adult: true),
          () {},
        );
        expect(newer.revision, 2);
        await expectLater(
          store.clearAdult(
            id: id,
            revision: old.revision,
            digest: old.snapshotDigest,
            authorize: () {},
            validate: () async {},
          ),
          throwsFormatException,
        );
        expect((await store.load())[id]!.adult, isTrue);
      } finally {
        await db.close();
      }
    },
  );

  test(
    'cancellation during write rolls back and damaged records stay closed',
    () async {
      final db = AppDatabase.memory();
      try {
        final store = BookPolicyEvidenceStore(db);
        final id = List.filled(64, '2').join();
        var calls = 0;
        await expectLater(
          store.merge(id, BookPolicyEvidence(adult: true), () {
            if (++calls == 3) throw StateError('cancelled before commit');
          }),
          throwsStateError,
        );
        expect((await store.load()).containsKey(id), isFalse);
        await db.write(
          'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
          [BookPolicyEvidenceStore.key(id), '{invalid'],
        );
        final merged = await store.merge(
          id,
          BookPolicyEvidence(adult: true),
          () {},
        );
        expect(merged.uncertain, isTrue);
        expect((await store.load())[id]!.uncertain, isTrue);
        final malformed = BookPolicyEvidence.decode(
          '{"version":1,"uncertain":"corrupt","adult":false,"keywords":[],"texts":[],"latest":"","incomplete":false}',
        );
        expect(malformed.uncertain, isTrue);
      } finally {
        await db.close();
      }
    },
  );
}
