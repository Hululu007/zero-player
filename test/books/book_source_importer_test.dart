import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_download_evidence.dart';
import 'package:zero_player/features/books/data/book_source_importer.dart';
import 'package:zero_player/features/books/data/book_source_links.dart';
import 'package:zero_player/features/books/data/book_source_risk_store.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/settings/application/settings_controller.dart';
import 'package:zero_player/features/supervision/application/content_policy.dart';
import 'package:zero_player/features/supervision/application/supervision_controller.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

void main() {
  _commitTests();
  _rollbackTests();
  _riskTests();
  _policyChangeTest();
}

void _commitTests() {
  test(
    'owning subscription updates keep preferences and invalidate old content',
    () async {
      final f = await _Fixture.create();
      final old = _source();
      final revision = _source({'name': '修订书源'});
      final subscription = Uri.parse('https://subscription.example/books');
      await f.store.write('books_source:${old.id}', {
        'source': old.toJson(),
        'enabled': true,
        'favorite': true,
        'group': '自选分组',
        'health': '旧检查结果',
        'checkedAt': 1,
        'subscription': bookSubscriptionId(subscription),
      });
      final epoch = await f.store.ensureContentEpoch(
        old.id,
        bookDownloadSourceFingerprint(old),
      );
      final siteRevision = (await f.store.siteRevisions.ensure({
        old.id,
      }))[old.id];
      final result = await f.importer().importSources(
        [revision, revision],
        builtins: [],
        subscription: subscription,
      );
      expect(result.changes, (added: 0, updated: 1, duplicates: 1, skipped: 0));
      final saved = (await f.store.source(null, old.id))!;
      expect(saved.source.name, '修订书源');
      expect(saved.enabled, isTrue);
      expect(saved.favorite, isTrue);
      expect(saved.group, '自选分组');
      expect(saved.health, isEmpty);
      expect(saved.checkedAt, isNull);
      expect(saved.subscriptionId, bookSubscriptionId(subscription));
      expect((await f.store.subscriptions()).single.count, 2);
      expect((await f.store.contentEpochs())[old.id], epoch + 1);
      expect(await f.store.siteRevisions.get(old.id), isNot(siteRevision));
    },
  );
  test(
    'multi-batch catalog commit records its revision and disables new sources',
    () async {
      final f = await _Fixture.create();
      final sources = List.generate(
        130,
        (i) => _source({'url': 'https://site$i.example/'}),
      );
      final result = await f.importer().importSources(
        sources,
        builtins: [],
        fromCatalog: true,
        catalogRevision: 'catalog-fixture',
        catalogAdultFilter: true,
      );
      expect(result.changes.added, 130);
      final saved = await f.store.sources([]);
      expect(saved, hasLength(130));
      expect(
        saved.every((entry) => entry.fromCatalog && !entry.enabled),
        isTrue,
      );
      expect(await f.store.read('books_catalog_revision'), 'catalog-fixture');
      expect(await f.store.subscriptions(), isEmpty);
    },
  );
}

void _rollbackTests() {
  test(
    'cancellation after a flushed batch rolls back sources and all revisions',
    () async {
      final f = await _Fixture.create();
      final token = CancellationToken();
      final sources = List.generate(
        130,
        (i) => _source({'url': 'https://site$i.example/'}),
      );
      var checked = 0;
      final importer = f.importer(
        allowed: (_) {
          if (++checked == 129) token.cancel();
          return true;
        },
      );
      await expectLater(
        importer.importSources(
          sources,
          builtins: [],
          token: token,
          subscription: Uri.parse('https://subscription.example/books'),
          catalogRevision: 'cancelled',
        ),
        throwsA(isA<RequestCancelled>()),
      );
      expect(checked, 129);
      expect(await f.store.sources([]), isEmpty);
      expect(await f.store.subscriptions(), isEmpty);
      expect(await f.store.read('books_catalog_revision'), isNull);
      expect(
        await f.db.rows(
          "SELECT * FROM app_meta WHERE key GLOB 'books_site_revision:*'",
        ),
        isEmpty,
      );
    },
  );
  test(
    'catalog policy mismatch rejects even an empty import without stamping success',
    () async {
      final f = await _Fixture.create();
      await expectLater(
        f.importer().importSources(
          [],
          builtins: [],
          fromCatalog: true,
          catalogRevision: 'stale-policy',
          catalogAdultFilter: false,
        ),
        throwsA(isA<ContentBlocked>()),
      );
      expect(await f.store.read('books_catalog_revision'), isNull);
    },
  );
}

void _riskTests() {
  test(
    'rejected adult update records installed-host evidence before blacklist rejection',
    () async {
      final f = await _Fixture.create();
      final old = _source({'sourceKey': 'stable-fixture'});
      final changed = _source({
        'sourceKey': 'stable-fixture',
        'url': 'https://other.example/',
        'adultEvidence': true,
      });
      await f.install(old);
      await f.store.write('books_source_blacklist', {old.id: old.name});
      final result = await f
          .importer(allowed: (_) => false)
          .importSources(
            [changed, changed],
            builtins: [],
            subscription: Uri.parse('https://subscription.example/books'),
          );
      expect(result.changes.skipped, 2);
      expect(result.assessments, hasLength(1));
      expect(result.assessments.single.host, old.endpoint.host);
      expect(result.assessments.single.adultHost, isFalse);
      expect((await f.risks.get(old.id))!.adult, isTrue);
      expect(
        (await f.store.source(null, old.id))!.source.endpoint,
        old.endpoint,
      );
      expect(await f.store.subscriptions(), isEmpty);
    },
  );
  test(
    'cancellation during risk write rolls back evidence and leaves installed state intact',
    () async {
      final f = await _Fixture.create();
      final old = _source();
      await f.install(old);
      final token = CancellationToken();
      await expectLater(
        f
            .importer(afterAssessment: () async => token.cancel())
            .importSources(
              [
                _source({'adultEvidence': true}),
              ],
              builtins: [],
              token: token,
            ),
        throwsA(isA<RequestCancelled>()),
      );
      expect(await f.risks.get(old.id), isNull);
      final saved = (await f.store.source(null, old.id))!;
      expect(saved.enabled, isTrue);
      expect(saved.source.adultEvidence, isFalse);
    },
  );
}

void _policyChangeTest() {
  test(
    'policy changes while retaining evidence abort the catalog transaction',
    () async {
      final f = await _Fixture.create();
      final old = _source();
      await f.install(old);
      final importer = f.importer(
        afterAssessment: () => f.settings.update({'filterAdult': false}),
      );
      await expectLater(
        importer.importSources(
          [
            _source({'adultEvidence': true}),
          ],
          builtins: [],
          fromCatalog: true,
          catalogAdultFilter: true,
          catalogRevision: 'stale-during-assessment',
        ),
        throwsA(isA<ContentBlocked>()),
      );
      expect(await f.risks.get(old.id), isNull);
      expect(await f.store.read('books_catalog_revision'), isNull);
      expect(
        (await f.store.source(null, old.id))!.source.adultEvidence,
        isFalse,
      );
      // The fixture changes settings inside the outer transaction. Reload its
      // notifier after rollback, just as a restore owner rebuilds its state.
      await f.settings.load();
      expect(f.policy.filterAdult, isTrue);
    },
  );
}

BookSource _source([Map<String, Object?> changes = const {}]) =>
    BookSource.fromJson({
      'name': '普通书源',
      'kind': 'text',
      'format': 'feed',
      'url': 'https://books.example/',
      ...changes,
    });

final class _Fixture {
  _Fixture(this.db, this.settings, this.supervision, this.policy)
    : store = BookStore(db),
      risks = BookSourceRiskStore(db);
  final AppDatabase db;
  final SettingsController settings;
  final SupervisionController supervision;
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
    return _Fixture(db, settings, supervision, policy);
  }

  Future<void> install(BookSource source) => store.write(
    'books_source:${source.id}',
    {'source': source.toJson(), 'enabled': true},
  );

  BookSourceImporter importer({
    bool Function(BookSource)? allowed,
    Future<void> Function()? afterAssessment,
  }) => BookSourceImporter(
    store: store,
    policy: policy,
    sourceAllowed: allowed ?? (_) => true,
    adultAssessed: (_) => false,
    assessAdult: (source) async {
      final assessment = BookSourceAssessment(
        sourceId: source.id,
        name: source.name,
        host: source.endpoint.host,
        adult: true,
        quarantined: false,
        adultHost: false,
        quarantinedHost: false,
        version: 1,
      );
      await risks.write(assessment);
      await afterAssessment?.call();
      return assessment;
    },
  );
}
