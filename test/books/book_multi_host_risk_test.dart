import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/persistence/installation_metadata.dart';
import 'package:zero_player/features/books/application/book_site_checks.dart';
import 'package:zero_player/features/books/data/book_site_inspection.dart';
import 'package:zero_player/features/books/data/book_source_risk_store.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'subscription host change retains both findings across restart',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      await fixture.installLegacyAdult();
      await fixture.updateSubscription();
      final summary = await fixture.scanNewHost();
      expect(summary.checked, 1);
      expect(summary.failed, 0);
      expect(summary.quarantined, 1);
      await fixture.expectEvidence();

      final risks = await fixture.services.books.sourceRiskEntries();
      final old = risks.singleWhere((risk) => risk.host == 'risk.example');
      final current = risks.singleWhere(
        (risk) => risk.host == 'www.risk.example',
      );
      expect(old.adult, isTrue);
      expect(old.quarantined, isFalse);
      expect(current.adult, isFalse);
      expect(current.adultRestricted, isTrue);
      expect(current.quarantined, isTrue);
      expect(current.recordKey, isNot(old.recordKey));
      expect(fixture.services.books.sourceRiskEntryAllowed(current), isTrue);
      await fixture.verifyHostBoundaries();

      await fixture.restart();
      await fixture.expectEvidence();
      await fixture.verifyHostBoundaries();
      await fixture.services.settings.update({'filterAdult': true});
      expect(
        fixture.services.books.sourceAllowed(_alias('risk.example')),
        isFalse,
      );
      expect(
        fixture.services.books.sourceAllowed(_alias('www.risk.example')),
        isFalse,
      );
      expect(
        fixture.services.books.sourceAllowed(_alias('other.risk.example')),
        isTrue,
      );
      expect(fixture.services.books.sourceRiskEntryAllowed(current), isFalse);
      expect(
        (await fixture.services.books.sourceRiskEntries()).where(
          (risk) => risk.sourceId == fixture.old.id,
        ),
        isEmpty,
      );
    },
  );

  test('only an authorized current review clears one host record', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    await fixture.installLegacyAdult();
    await fixture.updateSubscription();
    await fixture.scanNewHost();
    var review = (await fixture.services.books.sourceRiskEntries()).singleWhere(
      (risk) => risk.host == 'www.risk.example',
    );

    // The new host has no adult finding, but its source ID is adult restricted.
    await fixture.services.settings.update({'filterAdult': true});
    await expectLater(
      fixture.services.books.clearSourceRisk(review),
      throwsA(isA<ContentBlocked>()),
    );
    await fixture.expectEvidence();
    await fixture.services.settings.update({'filterAdult': false});

    final draft = await fixture.services.supervision.prepareCredentials(
      'fixture-password',
    );
    await fixture.services.supervision.saveCredentials(draft);
    await expectLater(
      fixture.services.supervision.execute(
        SensitiveOperation.channels,
        () => fixture.services.books.clearSourceRisk(review),
        password: 'fixture-password',
      ),
      throwsA(isA<ContentBlocked>()),
    );
    await fixture.services.supervision.execute(
      SensitiveOperation.supervision,
      () => fixture.services.supervision.setEnabled(false),
      password: 'fixture-password',
    );
    await fixture.expectEvidence();

    await fixture.services.books.clearSourceRisk(review);
    expect(
      (await fixture.services.books.riskStore.get(fixture.old.id))!.adult,
      isTrue,
    );
    expect(
      fixture.services.books.sourceAllowed(_alias('www.risk.example')),
      isTrue,
    );
    await fixture.services.books.markSourceRisk(
      fixture.updated,
      quarantine: true,
    );
    await expectLater(
      fixture.services.books.clearSourceRisk(review),
      throwsFormatException,
    );
    await fixture.expectEvidence();

    // A record cannot be redirected to the other host by changing its key.
    review = (await fixture.services.books.sourceRiskEntries()).singleWhere(
      (risk) => risk.host == 'www.risk.example',
    );
    final forged = BookSourceRiskEntry(
      sourceId: review.sourceId,
      name: review.name,
      host: 'risk.example',
      adult: review.adult,
      quarantined: review.quarantined,
      fixedQuarantine: false,
      version: review.version,
      recordKey: review.recordKey,
    );
    await expectLater(
      fixture.services.books.clearSourceRisk(forged),
      throwsFormatException,
    );
    await fixture.expectEvidence();
  });

  test(
    'a simultaneous review and new finding cannot erase the finding',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      await fixture.installLegacyAdult();
      await fixture.updateSubscription();
      await fixture.scanNewHost();
      final review = (await fixture.services.books.sourceRiskEntries())
          .singleWhere((risk) => risk.host == 'www.risk.example');
      Future<void> reviewIfCurrent() async {
        try {
          await fixture.services.books.clearSourceRisk(review);
        } on FormatException {
          // The new finding was committed first, making this review stale.
        }
      }

      await Future.wait([
        reviewIfCurrent(),
        fixture.services.books.markSourceRisk(
          fixture.updated,
          quarantine: true,
        ),
      ]);
      await fixture.expectEvidence();
      expect(
        fixture.services.books.sourceAllowed(_alias('www.risk.example')),
        isFalse,
      );
      await fixture.restart();
      await fixture.expectEvidence();
    },
  );

  test(
    'adult filtering rejects a subscription update of a marked source',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      await fixture.installLegacyAdult();
      await fixture.services.settings.update({'filterAdult': true});
      final changes = await fixture.services.books.importSources([
        fixture.updated,
      ], subscription: fixture.subscription);
      expect(changes.updated, 0);
      expect(changes.skipped, 1);
      expect(
        (await fixture.services.books.store.source(
          null,
          fixture.old.id,
        ))!.source.endpoint,
        fixture.old.endpoint,
      );
      expect(
        (await fixture.services.books.riskStore.get(fixture.old.id))!.adult,
        isTrue,
      );
      expect(
        await fixture.services.books.riskStore.getRecord(
          BookSourceRiskStore.hostKey(
            fixture.old.id,
            fixture.updated.endpoint.host,
          ),
        ),
        isNull,
      );
    },
  );

  test('a damaged host record fails closed and is not overwritten', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    await fixture.installLegacyAdult();
    await fixture.updateSubscription();
    final key = BookSourceRiskStore.hostKey(
      fixture.old.id,
      fixture.updated.endpoint.host,
    );
    await fixture.services.db.write(
      'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
      ['books_source_risk:$key', '{damaged'],
    );
    await fixture.services.books.refreshSourceRisks();
    expect(fixture.services.books.sourceAllowed(fixture.updated), isFalse);
    await expectLater(
      fixture.services.books.markSourceRisk(fixture.updated, quarantine: true),
      throwsFormatException,
    );
    final damaged = (await fixture.services.books.sourceRiskEntries())
        .singleWhere((risk) => risk.recordKey == key);
    await expectLater(
      fixture.services.books.clearSourceRisk(damaged),
      throwsFormatException,
    );
    await fixture.restart();
    expect(fixture.services.books.sourceAllowed(fixture.updated), isFalse);
    expect(
      (await fixture.services.books.riskStore.get(fixture.old.id))!.adult,
      isTrue,
    );
  });
}

BookSource _source(String host) => BookSource.fromJson({
  'name': '普通来源',
  'kind': 'text',
  'format': 'feed',
  'url': 'https://$host/feed',
});

BookSource _alias(String host) => BookSource.fromJson({
  'name': '另一来源',
  'kind': 'text',
  'format': 'feed',
  'url': 'https://$host/other',
});

final class _Fixture {
  _Fixture(this.root, this.services);
  final Directory root;
  AppServices services;
  final old = _source('risk.example');
  final updated = _source('www.risk.example');
  final subscription = Uri.parse('https://subscription.example/list');

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('book-multi-host-');
    final services = AppServices.scoped(
      root,
      AppDatabase(File('${root.path}/db.sqlite')),
    );
    await services.db.write(
      'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
      [installationAccessKey, upgradedInstallationAccess],
    );
    await services.supervision.load();
    await services.settings.load();
    await services.settings.update({'filterAdult': false});
    return _Fixture(root, services);
  }

  Future<void> installLegacyAdult() async {
    expect(old.id, updated.id);
    expect(
      (await services.books.importSources([
        old,
      ], subscription: subscription)).added,
      1,
    );
    await services.books.saveSource(old, {'enabled': true});
    // Exactly the single-record schema written before host-specific records.
    await services.db.write(
      'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
      [
        'books_source_risk:${old.id}',
        jsonEncode({
          'name': old.name,
          'host': old.endpoint.host,
          'adult': true,
          'quarantined': false,
          'adultHost': true,
          'quarantinedHost': false,
          'version': 7,
        }),
      ],
    );
    await services.books.refreshSourceRisks();
  }

  Future<void> updateSubscription() async {
    final changes = await services.books.importSources([
      updated,
    ], subscription: subscription);
    expect(changes.updated, 1);
    expect(
      (await services.books.store.source(null, old.id))!.source.endpoint,
      updated.endpoint,
    );
  }

  Future<BookSiteCheckSummary> scanNewHost() async {
    final entry = (await services.books.sourceEntry(
      BookKind.text,
      updated.id,
    ))!;
    final checks = BookSiteChecks(
      services.books,
      inspect: (source, token) async => const BookSiteInspection(
        BookSiteFinding.gamblingClue,
        gamblingRisk: true,
      ),
    );
    return checks.run([entry], CancellationToken());
  }

  Future<void> expectEvidence() async {
    final legacy = (await services.books.riskStore.get(old.id))!;
    final added = (await services.books.riskStore.getRecord(
      BookSourceRiskStore.hostKey(old.id, updated.endpoint.host),
    ))!;
    expect(legacy.host, old.endpoint.host);
    expect(legacy.version, 7);
    expect(legacy.adult, isTrue);
    expect(legacy.quarantined, isFalse);
    expect(added.host, updated.endpoint.host);
    expect(added.adult, isFalse);
    expect(added.quarantined, isTrue);
    expect(added.quarantinedHost, isTrue);
  }

  Future<void> verifyHostBoundaries() async {
    await services.books.ensureSourceRiskLoaded();
    expect(services.books.sourceAllowed(updated), isFalse);
    expect(services.books.sourceAllowed(_alias('risk.example')), isTrue);
    expect(services.books.sourceAllowed(_alias('www.risk.example')), isFalse);
    expect(services.books.sourceAllowed(_alias('other.risk.example')), isTrue);
  }

  Future<void> restart() async {
    await services.close();
    services = AppServices.scoped(
      root,
      AppDatabase(File('${root.path}/db.sqlite')),
    );
    await services.supervision.load();
    await services.settings.load();
    await services.books.ensureSourceRiskLoaded();
  }

  Future<void> close() async {
    await services.close();
    await root.delete(recursive: true);
  }
}
