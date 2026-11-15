import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/persistence/installation_metadata.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/data/book_source_links.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_source_risk.dart';
import 'package:zero_player/features/books/domain/known_untrusted_book_rules.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'manual same-source replacement preserves metadata and stays disabled',
    () async {
      final fixture = await _Fixture.create(adultAccess: true);
      addTearDown(fixture.close);
      await fixture.services.settings.update({'filterAdult': false});
      final raw = await _auditedSource();
      final old = BookSource.fromJson({...raw.toJson(), 'adultEvidence': true});
      final candidate = _replacement(raw);
      expect(old.id, candidate.id);
      expect(knownUntrustedBookRule(old), isTrue);
      expect(quarantinedBookSource(candidate), isFalse);
      await fixture.installOld(old);
      final changes = await fixture.services.books.importSources([candidate]);
      expect(changes.updated, 1);
      final saved = (await fixture.services.books.store.source(null, old.id))!;
      expect(saved.source.adultEvidence, isTrue);
      expect(knownUntrustedBookRule(saved.source), isFalse);
      expect(saved.enabled, isFalse);
      expect(saved.favorite, isTrue);
      expect(saved.group, '珍藏分组');
      expect(saved.subscriptionId, 'subscription-fixture');
      expect(saved.fromCatalog, isTrue);
      expect(saved.health, isEmpty);
      expect(saved.checkedAt, isNull);
      await fixture.services.settings.update({'filterAdult': true});
      expect(
        await fixture.services.books.sourceEntry(BookKind.text, old.id),
        isNull,
      );
    },
  );

  test('manual replacement also recovers a reviewed wesrc rule', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final old = await _auditedSource(535);
    final candidate = _replacement(old);
    expect(old.id, candidate.id);
    expect(knownUnsafeBookRule(old), isTrue);
    expect(knownUnsafeBookRule(candidate), isFalse);
    await fixture.installOld(old);
    expect(
      (await fixture.services.books.importSources([candidate])).updated,
      1,
    );
    final saved = (await fixture.services.books.store.source(null, old.id))!;
    expect(saved.enabled, isFalse);
    expect(knownUnsafeBookRule(saved.source), isFalse);
  });

  test(
    'same ID at a different complete endpoint cannot replace old rules',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final old = await _auditedSource();
      await fixture.installOld(old);
      final candidate = _replacement(old);
      final alternate = BookSource.fromJson({
        ...candidate.toJson(),
        'url': candidate.endpoint
            .replace(host: 'www.${candidate.endpoint.host}')
            .toString(),
      });
      expect(alternate.id, old.id);
      expect(alternate.endpoint, isNot(old.endpoint));
      final changes = await fixture.services.books.importSources([alternate]);
      expect(changes.updated, 0);
      expect(
        knownUntrustedBookRule(
          (await fixture.services.books.store.source(null, old.id))!.source,
        ),
        isTrue,
      );
    },
  );

  test(
    'supervised import cannot replace quarantined rules even with a grant',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final old = await _auditedSource();
      await fixture.installOld(old);
      final draft = await fixture.services.supervision.prepareCredentials(
        'fixture-password',
      );
      await fixture.services.supervision.saveCredentials(draft);
      final changes = await fixture.services.supervision.execute(
        SensitiveOperation.channels,
        () => fixture.services.books.importSources([_replacement(old)]),
        password: 'fixture-password',
      );
      expect(changes.updated, 0);
      expect(
        knownUntrustedBookRule(
          (await fixture.services.books.store.source(null, old.id))!.source,
        ),
        isTrue,
      );
    },
  );

  test(
    'blacklist and persistent adult evidence prevent replacement while restricted',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final old = await _auditedSource();
      await fixture.installOld(old);
      await fixture.services.books.markSourceRisk(old, adult: true);
      final restricted = await fixture.services.books.importSources([
        _replacement(old),
      ]);
      expect(restricted.updated, 0);
      expect(
        (await fixture.services.books.riskStore.get(old.id))!.adult,
        isTrue,
      );
      await fixture.services.books.store.write('books_source_blacklist', {
        old.id: old.name,
      });
      await fixture.services.books.refreshSourceRisks();
      final blocked = await fixture.services.books.importSources([
        _replacement(old),
      ]);
      expect(blocked.updated, 0);
      expect(
        knownUntrustedBookRule(
          (await fixture.services.books.store.source(null, old.id))!.source,
        ),
        isTrue,
      );
    },
  );

  test(
    'a fixed host quarantine cannot be cleared by replacing a rule',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final raw = await _auditedSource();
      final old = BookSource.fromJson({
        ...raw.toJson(),
        'url': 'https://m.60ks.com/',
      });
      final candidate = _replacement(old);
      expect(knownUnsafeBookRule(old), isTrue);
      expect(quarantinedBookHost(candidate.endpoint.host), isTrue);
      await fixture.installOld(old);
      expect(
        (await fixture.services.books.importSources([candidate])).updated,
        0,
      );
      expect(
        knownUnsafeBookRule(
          (await fixture.services.books.store.source(null, old.id))!.source,
        ),
        isTrue,
      );
    },
  );

  for (final catalog in [true, false]) {
    test(
      'automatic ${catalog ? 'catalog' : 'subscription'} cannot repair reviewed rule',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.close);
        final old = await _auditedSource();
        final subscription = Uri.parse(
          'https://subscription.example/sources.json',
        );
        await fixture.installOld(
          old,
          subscriptionId: catalog ? null : bookSubscriptionId(subscription),
          catalog: catalog,
        );
        final candidate = BookSource.fromJson({
          ..._replacement(old).toJson(),
          'updatedAt': old.updatedAt + 1,
        });
        final changes = await fixture.services.books.importSources(
          [candidate],
          fromCatalog: catalog,
          subscription: catalog ? null : subscription,
        );
        expect(changes.updated, 0);
        expect(
          knownUntrustedBookRule(
            (await fixture.services.books.store.source(null, old.id))!.source,
          ),
          isTrue,
        );
      },
    );
  }
}

Future<BookSource> _auditedSource([int index = 12]) async {
  final bytes = await File(
    'assets/catalogs/books/legado/catalog.json.bz2',
  ).readAsBytes();
  final data =
      jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(bytes))) as Map;
  return parseBookSourceRecord((data['records'] as List)[index]);
}

BookSource _replacement(BookSource source) {
  final raw = source.toJson()..remove('adultEvidence');
  return BookSource.fromJson({
    ...raw,
    'name': '已修订规则',
    'legado': {
      ...source.legado!.toJson(),
      'rules': {'content': 'p@text', 'searchList': '.book'},
    },
  });
}

final class _Fixture {
  _Fixture(this.root, this.services);
  final Directory root;
  final AppServices services;

  static Future<_Fixture> create({bool adultAccess = false}) async {
    final root = await Directory.systemTemp.createTemp('book-sha-recovery-');
    final services = AppServices.scoped(root, AppDatabase.memory());
    if (adultAccess) {
      await services.db.write('INSERT OR REPLACE INTO app_meta VALUES(?,?)', [
        installationAccessKey,
        upgradedInstallationAccess,
      ]);
    }
    await services.settings.load();
    await services.supervision.load();
    return _Fixture(root, services);
  }

  Future<void> installOld(
    BookSource source, {
    String? subscriptionId = 'subscription-fixture',
    bool catalog = true,
  }) async {
    await services.books.store.write('books_source:${source.id}', {
      'source': source.toJson(),
      'enabled': true,
      'favorite': true,
      'group': '珍藏分组',
      'health': '旧解析结果',
      'checkedAt': 123,
      'subscription': ?subscriptionId,
      'catalog': catalog,
    });
    await services.books.refreshSourceRisks();
  }

  Future<void> close() async {
    await services.close();
    await root.delete(recursive: true);
  }
}
