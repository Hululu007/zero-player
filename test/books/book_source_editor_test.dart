import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_download_evidence.dart';
import 'package:zero_player/features/books/data/book_source_editor.dart';
import 'package:zero_player/features/books/data/book_source_import_plan.dart';
import 'package:zero_player/features/books/data/book_source_risk_store.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/settings/application/settings_controller.dart';
import 'package:zero_player/features/supervision/application/content_policy.dart';
import 'package:zero_player/features/supervision/application/supervision_controller.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

void main() {
  _saveTests();
  _removalTests();
  _blacklistTests();
  _selectionTests();
  _hostEvidenceTests();
  _evidenceRollbackTests();
}

void _saveTests() {
  test(
    'group edits retain adult evidence without promoting it to host risk',
    () async {
      final f = await _Fixture.create();
      final source = _source();
      await f.install(source, {'group': '成人'});
      final before = (await f.store.siteRevisions.ensure({
        source.id,
      }))[source.id];
      final retained = await f.editor().save(source, {'group': '普通'});
      expect(retained, isNotNull);
      expect(retained!.adult, isTrue);
      expect(retained.adultHost, isFalse);
      expect((await f.risks.get(source.id))!.version, retained.version);
      expect((await f.store.source(null, source.id))!.group, '普通');
      expect(await f.store.siteRevisions.get(source.id), isNot(before));
      final revision = await f.store.siteRevisions.get(source.id);
      expect(await f.editor().save(source, {'favorite': true}), isNull);
      expect(await f.store.siteRevisions.get(source.id), revision);
    },
  );

  test(
    'late validation failure rolls back group, evidence and site revision',
    () async {
      final f = await _Fixture.create();
      final source = _source();
      await f.install(source, {'group': '成人'});
      final revision = (await f.store.siteRevisions.ensure({
        source.id,
      }))[source.id];
      var checks = 0;
      await expectLater(
        f.editor().save(
          source,
          {'group': '普通'},
          validate: () {
            if (++checks == 3) throw StateError('stale source lease');
          },
        ),
        throwsStateError,
      );
      expect((await f.store.source(null, source.id))!.group, '成人');
      expect(await f.risks.all(), isEmpty);
      expect(await f.store.siteRevisions.get(source.id), revision);
    },
  );

  test(
    'enabling rechecks comic authorization inside the transaction',
    () async {
      final f = await _Fixture.create();
      final source = _source();
      await f.install(source, {'enabled': false});
      var checks = 0;
      await expectLater(
        f.editor(comicAllowed: (_) => ++checks == 1).save(source, {
          'enabled': true,
        }),
        throwsA(isA<ContentBlocked>()),
      );
      expect((await f.store.source(null, source.id))!.enabled, isFalse);
    },
  );
}

void _removalTests() {
  test(
    'removal retains evidence and invalidates content from the removed source',
    () async {
      final f = await _Fixture.create();
      final source = _source();
      await f.install(source, {'group': '成人'});
      final epoch = await f.store.ensureContentEpoch(
        source.id,
        bookDownloadSourceFingerprint(source),
      );
      final retained = await f.editor().remove(source);
      expect(retained!.adult, isTrue);
      expect(await f.store.source(null, source.id), isNull);
      expect((await f.store.contentEpochs())[source.id], epoch + 1);
      expect((await f.risks.get(source.id))!.adultHost, isFalse);
    },
  );

  test(
    'policy rejection after evidence retention rolls back removal and evidence',
    () async {
      final f = await _Fixture.create();
      final source = _source();
      await f.install(source, {'group': '成人'});
      var allowedChecks = 0;
      await expectLater(
        f.editor(allowed: (_) => ++allowedChecks < 3).remove(source),
        throwsA(isA<ContentBlocked>()),
      );
      expect(await f.store.source(null, source.id), isNotNull);
      expect(await f.risks.all(), isEmpty);
    },
  );
}

void _blacklistTests() {
  test(
    'block and unblock keep unrelated aliases and never reenable the source',
    () async {
      final f = await _Fixture.create();
      final source = _source();
      await f.install(source);
      await f.store.write('books_source_blacklist_aliases', {
        'other-alias': 'other',
      });
      await f.editor().block(source);
      expect((await f.store.blockedSources()).keys, contains(source.id));
      expect(
        await f.store.blockedAliases(),
        contains(bookSourceBlacklistAlias(source)),
      );
      expect((await f.store.source(null, source.id))!.enabled, isFalse);
      await f.editor().unblock(source.id);
      expect(await f.store.blockedSources(), isEmpty);
      expect(await f.store.blockedAliases(), {'other-alias'});
      expect((await f.store.source(null, source.id))!.enabled, isFalse);
    },
  );

  test('failed disabling rolls back blacklist and aliases together', () async {
    final f = await _Fixture.create();
    await expectLater(f.editor().block(_source()), throwsFormatException);
    expect(await f.store.blockedSources(), isEmpty);
    expect(await f.store.blockedAliases(), isEmpty);
  });
}

void _selectionTests() {
  test(
    'default restore respects kind, blacklist and bundled default choices',
    () async {
      final f = await _Fixture.create();
      final builtin = _source({'sourceKey': 'builtin'}, true);
      final blocked = _source({'sourceKey': 'blocked'}, true);
      final optional = _source({
        'sourceKey': 'optional',
        'defaultEnabled': false,
      }, true);
      final audio = _source({'kind': 'audio', 'sourceKey': 'audio'});
      final custom = _source();
      await f.install(custom);
      await f.install(audio);
      await f.store.write('books_source:${builtin.id}', {'removed': true});
      await f.store.write('books_source_blacklist', {blocked.id: 'blocked'});
      await f.editor().restoreDefaults(BookKind.text, [
        builtin,
        blocked,
        optional,
      ]);
      expect((await f.store.source(builtin, builtin.id))!.enabled, isTrue);
      expect((await f.store.source(blocked, blocked.id))!.enabled, isFalse);
      expect((await f.store.source(optional, optional.id))!.enabled, isFalse);
      expect((await f.store.source(null, custom.id))!.enabled, isFalse);
      expect((await f.store.source(null, audio.id))!.enabled, isTrue);
    },
  );

  test(
    'bulk enabling rejects the whole selection when one channel is unauthorized',
    () async {
      final f = await _Fixture.create();
      final first = _source();
      final second = _source({'sourceKey': 'second'});
      await f.install(first, {'enabled': false});
      await f.install(second, {'enabled': false});
      final editor = f.editor(comicAllowed: (source) => source.id != second.id);
      await expectLater(
        editor.setEnabled(() => f.store.sources([]), {
          first.id,
          second.id,
        }, true),
        throwsA(isA<ContentBlocked>()),
      );
      expect((await f.store.sources([])).every((e) => !e.enabled), isTrue);
      expect(
        await editor.setEnabled(() => f.store.sources([]), {'missing'}, true),
        isFalse,
      );
    },
  );
}

void _hostEvidenceTests() {
  test(
    'host migration keeps independent evidence and monotonic revisions',
    () async {
      final f = await _Fixture.create();
      final first = _source();
      final second = _source({'url': 'https://other.example/'});
      expect(second.id, first.id);
      final original = await f.risks.addEvidence(
        first,
        adult: true,
        quarantine: false,
        rootPageEvidence: false,
      );
      final migrated = await f.risks.addEvidence(
        second,
        adult: false,
        quarantine: true,
        rootPageEvidence: true,
      );
      final merged = await f.risks.addEvidence(
        second,
        adult: true,
        quarantine: false,
        rootPageEvidence: false,
      );
      expect(original.key, first.id);
      expect(
        migrated.key,
        BookSourceRiskStore.hostKey(first.id, second.endpoint.host),
      );
      expect(merged.version, migrated.version + 1);
      expect(merged.adult, isTrue);
      expect(merged.adultHost, isFalse);
      expect(merged.quarantinedHost, isTrue);
      expect((await f.risks.get(first.id))!.version, original.version);
      expect(await f.risks.all(), hasLength(2));
    },
  );

  test('concurrent evidence writers preserve both findings', () async {
    final f = await _Fixture.create();
    final source = _source();
    await Future.wait([
      f.risks.addEvidence(
        source,
        adult: true,
        quarantine: false,
        rootPageEvidence: true,
      ),
      f.risks.addEvidence(
        source,
        adult: false,
        quarantine: true,
        rootPageEvidence: true,
      ),
    ]);
    final merged = (await f.risks.get(source.id))!;
    expect(merged.version, 2);
    expect(merged.adultHost && merged.quarantinedHost, isTrue);
  });
}

void _evidenceRollbackTests() {
  test(
    'nested evidence write is rolled back with its owning transaction',
    () async {
      final f = await _Fixture.create();
      await expectLater(
        f.db.atomic(() async {
          await f.risks.addEvidence(
            _source(),
            adult: true,
            quarantine: false,
            rootPageEvidence: true,
          );
          throw StateError('owner failed');
        }),
        throwsStateError,
      );
      expect(await f.risks.all(), isEmpty);
    },
  );

  test(
    'damaged host record is preserved when new evidence is rejected',
    () async {
      final f = await _Fixture.create();
      final first = _source();
      final second = _source({'url': 'https://other.example/'});
      await f.risks.addEvidence(
        first,
        adult: true,
        quarantine: false,
        rootPageEvidence: true,
      );
      final key = BookSourceRiskStore.hostKey(first.id, second.endpoint.host);
      await f.db.write('INSERT INTO app_meta(key,value) VALUES(?,?)', [
        'books_source_risk:$key',
        'broken',
      ]);
      await expectLater(
        f.risks.addEvidence(
          second,
          adult: false,
          quarantine: true,
          rootPageEvidence: true,
        ),
        throwsFormatException,
      );
      final raw = await f.db.rows('SELECT value FROM app_meta WHERE key=?', [
        'books_source_risk:$key',
      ]);
      expect(raw.single['value'], 'broken');
      expect((await f.risks.get(first.id))!.adultHost, isTrue);
    },
  );
}

BookSource _source([
  Map<String, Object?> changes = const {},
  bool builtin = false,
]) => BookSource.fromJson({
  'name': '普通书源',
  'kind': 'text',
  'format': 'feed',
  'url': 'https://books.example/',
  'sourceKey': 'editor-fixture',
  ...changes,
}, builtin: builtin);

final class _Fixture {
  _Fixture(this.db, this.policy)
    : store = BookStore(db),
      risks = BookSourceRiskStore(db);
  final AppDatabase db;
  final ContentPolicy policy;
  final BookStore store;
  final BookSourceRiskStore risks;

  static Future<_Fixture> create() async {
    final db = AppDatabase.memory();
    final settings = SettingsController(db);
    final supervision = SupervisionController(db);
    final policy = ContentPolicy(settings, supervision);
    addTearDown(() async {
      policy.dispose();
      supervision.dispose();
      settings.dispose();
      await db.close();
    });
    await settings.load();
    await supervision.load();
    return _Fixture(db, policy);
  }

  Future<void> install(
    BookSource source, [
    Map<String, Object?> state = const {},
  ]) => store.write('books_source:${source.id}', {
    'source': source.toJson(),
    'enabled': true,
    ...state,
  });

  BookSourceEditor editor({
    bool Function(BookSource)? allowed,
    bool Function(BookSource)? comicAllowed,
  }) => BookSourceEditor(
    store: store,
    risks: risks,
    policy: policy,
    sourceAllowed: allowed ?? (_) => true,
    comicAllowed: comicAllowed ?? (_) => true,
  );
}
