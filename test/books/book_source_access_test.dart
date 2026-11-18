import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/persistence/installation_metadata.dart';
import 'package:zero_player/features/books/data/book_source_access.dart';
import 'package:zero_player/features/books/data/book_source_risk_store.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/settings/application/settings_controller.dart';
import 'package:zero_player/features/supervision/application/content_policy.dart';
import 'package:zero_player/features/supervision/application/supervision_controller.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

void main() {
  _snapshotTests();
  _restrictionTests();
  _reviewTests();
}

void _snapshotTests() {
  test(
    'unloaded and suspended sources fail closed until a fresh publish',
    () async {
      final f = await _Fixture.create();
      final source = _source();
      expect(f.access.sourceAllowed(source), isFalse);
      f.publish([source]);
      expect(f.access.sourceAllowed(source), isTrue);
      final loading = f.access.beginReload();
      expect(f.access.sourceAllowed(source), isFalse);
      f.access.suspend();
      expect(
        () => f.publish([source], generation: loading),
        throwsA(isA<ContentBlocked>()),
      );
      expect(f.access.beginReload, throwsA(isA<ContentBlocked>()));
      f.access.resume();
      expect(f.publish([source], generation: loading), isFalse);
      expect(f.access.ready, isFalse);
      expect(f.publish([source]), isTrue);
      expect(f.access.sourceAllowed(source), isTrue);
    },
  );

  test(
    'published collections cannot be changed through caller inputs',
    () async {
      final f = await _Fixture.create();
      final source = _source();
      final entries = [_entry(source)];
      final assessments = <String, BookSourceAssessment>{};
      final blocked = <String>{};
      expect(
        f.access.publish(
          generation: f.access.beginReload(),
          entries: entries,
          assessments: assessments,
          blocked: blocked,
        ),
        isTrue,
      );
      entries.clear();
      assessments[source.id] = _risk(source, quarantine: true);
      blocked.add(source.id);
      expect(f.access.entry(source.id)?.source, same(source));
      expect(f.access.sourceAllowed(source), isTrue);
      expect(f.access.riskEntries(), isEmpty);
    },
  );

  test('a committed finding rejects all fields of an older reload', () async {
    final f = await _Fixture.create();
    final source = _source();
    f.publish([source]);
    final old = f.access.beginReload();
    final finding = _risk(source, quarantine: true);
    f.access.rememberAssessment(finding);
    expect(f.publish([], generation: old), isFalse);
    expect(f.access.entry(source.id), isNotNull);
    expect(
      f.access.assessedQuarantined(source.id, source.endpoint.host),
      isTrue,
    );
    f.publish([source], risks: [finding]);
    expect(f.access.sourceAllowed(source), isFalse);
  });

  test(
    'blacklist publication blocks immediately and invalidates stale reload',
    () async {
      final f = await _Fixture.create();
      final source = _source();
      f.publish([source]);
      final old = f.access.generation;
      f.access.block(source.id);
      expect(f.access.ready, isTrue);
      expect(f.access.sourceAllowed(source), isFalse);
      expect(f.publish([source], generation: old), isFalse);
      expect(f.access.blocked(source.id), isTrue);
      // Only a current database snapshot may publish the committed unblock.
      f.publish([source]);
      expect(f.access.sourceAllowed(source), isTrue);
    },
  );
}

void _restrictionTests() {
  test(
    'source labels restrict the ID while root findings restrict exact hosts',
    () async {
      final f = await _Fixture.create();
      final source = _source();
      final alias = _source({'sourceKey': 'alias', 'kind': 'audio'});
      final sibling = _source({
        'url': 'https://www.books.example/',
        'sourceKey': 'sibling',
      });
      f.publish([source, alias, sibling]);
      f.access.rememberAssessment(_risk(source, adult: true, hostWide: false));
      await f.settings.update({'filterAdult': true});
      expect(f.access.sourceAllowed(source), isFalse);
      expect(f.access.sourceAllowed(alias), isTrue);
      f.access.rememberAssessment(_risk(source, adult: true, version: 2));
      expect(f.access.sourceAllowed(alias), isFalse);
      expect(f.access.sourceAllowed(sibling), isTrue);
      await f.settings.update({'filterAdult': false});
      expect(f.access.sourceAllowed(source), isTrue);
      f.access.rememberAssessment(_risk(source, quarantine: true, version: 3));
      expect(f.access.sourceAllowed(alias), isFalse);
      expect(f.access.sourceAllowed(sibling), isTrue);
    },
  );

  test('stored groups and declared media hosts use current policy', () async {
    final f = await _Fixture.create();
    final source = _source();
    final media = _source({
      'sourceKey': 'media',
      'url': 'https://media.example/',
    });
    final usesMedia = _source({
      'sourceKey': 'reader',
      'mediaHosts': ['media.example'],
    });
    f.publish([source, media, usesMedia]);
    final grouped = _entry(source, group: '成人小说');
    f.access.rememberAssessment(_risk(media, adult: true));
    await f.settings.update({'filterAdult': true});
    expect(f.access.sourceAllowed(source), isTrue);
    expect(f.access.entryAllowed(grouped), isFalse);
    expect(f.access.sourceAllowed(usesMedia), isFalse);
    await f.settings.update({'filterAdult': false});
    expect(f.access.entryAllowed(grouped), isTrue);
    expect(f.access.sourceAllowed(usesMedia), isTrue);
  });

  test(
    'review tombstones reject late findings without clearing other hosts',
    () async {
      final f = await _Fixture.create();
      final source = _source();
      final other = _source({'url': 'https://www.books.example/'});
      final old = _risk(source, adult: true, version: 4);
      final current = _risk(
        other,
        quarantine: true,
        version: 2,
        key: BookSourceRiskStore.hostKey(source.id, other.endpoint.host),
      );
      f.publish([other], risks: [old, current]);
      f.access.rememberAssessment(_risk(other, version: 3, key: current.key));
      final generation = f.access.generation;
      f.access.rememberAssessment(current);
      expect(f.access.generation, generation);
      expect(
        f.access.assessedQuarantined(other.id, other.endpoint.host),
        isFalse,
      );
      expect(f.access.assessedAdult(other.id, source.endpoint.host), isTrue);
      expect(
        f.access.riskEntries().where((row) => row.host == other.endpoint.host),
        isNotEmpty,
      );
      // The ID is still adult restricted by the independent old-host finding.
      await f.settings.update({'filterAdult': true});
      expect(f.access.sourceAllowed(other), isFalse);
    },
  );
}

void _reviewTests() {
  test(
    'review rows retain host scope and reject changed evidence or policy',
    () async {
      final f = await _Fixture.create();
      final source = _source();
      final other = _source({'url': 'https://www.books.example/'});
      final old = _risk(source, adult: true);
      final current = _risk(
        other,
        quarantine: true,
        key: BookSourceRiskStore.hostKey(source.id, other.endpoint.host),
      );
      f.publish([other], risks: [old, current]);
      final rows = f.access.riskEntries();
      final row = rows.singleWhere((row) => row.host == other.endpoint.host);
      expect(row.adult, isFalse);
      expect(row.adultRestricted, isTrue);
      expect(row.quarantined, isTrue);
      expect(f.access.riskEntryAllowed(row), isTrue);
      final forged = BookSourceRiskEntry(
        sourceId: row.sourceId,
        name: row.name,
        host: source.endpoint.host,
        adult: row.adult,
        adultRestricted: row.adultRestricted,
        quarantined: row.quarantined,
        fixedQuarantine: row.fixedQuarantine,
        version: row.version,
        recordKey: row.recordKey,
      );
      expect(f.access.riskEntryAllowed(forged), isFalse);
      await f.settings.update({'filterAdult': true});
      expect(f.access.riskEntries(), isEmpty);
      expect(f.access.riskEntryAllowed(row), isFalse);
      await f.settings.update({'filterAdult': false});
      f.access.rememberAssessment(
        _risk(other, quarantine: true, version: 2, key: current.key),
      );
      expect(f.access.riskEntryAllowed(row), isFalse);
      expect(
        f.access.riskEntryAllowed(
          f.access.riskEntries().singleWhere(
            (row) => row.host == other.endpoint.host,
          ),
        ),
        isTrue,
      );
    },
  );

  test(
    'fixed quarantine remains distinct from a manually reviewable finding',
    () async {
      final f = await _Fixture.create();
      final source = _source({'url': 'https://jpxgyw.cc/'});
      f.publish([source]);
      final row = f.access.riskEntries().single;
      expect(row.fixedQuarantine, isTrue);
      expect(row.version, 0);
      expect(
        BookSourceAccess.fixedRisk(source.id, source.endpoint.host, source),
        isTrue,
      );
      expect(f.access.sourceAllowed(source), isFalse);
      f.access.invalidate(unload: true);
      expect(f.access.riskEntryAllowed(row), isFalse);
      expect(f.access.riskEntries(), isEmpty);
    },
  );
}

BookSource _source([Map<String, Object?> changes = const {}]) =>
    BookSource.fromJson({
      'name': '普通来源',
      'kind': 'text',
      'format': 'feed',
      'url': 'https://books.example/',
      'sourceKey': 'snapshot-fixture',
      ...changes,
    });

BookSourceEntry _entry(BookSource source, {String group = ''}) =>
    BookSourceEntry(source, true, false, group, '', null);

BookSourceAssessment _risk(
  BookSource source, {
  bool adult = false,
  bool quarantine = false,
  bool hostWide = true,
  int version = 1,
  String? key,
}) => BookSourceAssessment(
  sourceId: source.id,
  name: source.name,
  host: source.endpoint.host,
  adult: adult,
  quarantined: quarantine,
  adultHost: adult && hostWide,
  quarantinedHost: quarantine && hostWide,
  version: version,
  recordKey: key,
);

final class _Fixture {
  _Fixture(this.settings, this.access);
  final SettingsController settings;
  final BookSourceAccess access;

  static Future<_Fixture> create() async {
    final db = AppDatabase.memory();
    await db.write('INSERT OR REPLACE INTO app_meta VALUES(?,?)', [
      installationAccessKey,
      upgradedInstallationAccess,
    ]);
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
    await settings.update({'filterAdult': false});
    return _Fixture(settings, BookSourceAccess(policy));
  }

  bool publish(
    List<BookSource> sources, {
    int? generation,
    List<BookSourceAssessment> risks = const [],
  }) => access.publish(
    generation: generation ?? access.beginReload(),
    entries: sources.map(_entry),
    assessments: {for (final risk in risks) risk.key: risk},
    blocked: const [],
  );
}
