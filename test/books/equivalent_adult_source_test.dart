import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/persistence/installation_metadata.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_source_risk.dart';
import 'package:zero_player/features/books/domain/legado_source_fingerprint.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

const _pairs = <(int, int, int, String, String, String)>[
  (
    4715,
    4730,
    4704,
    'fd43c18e3b6b2020f3f7823c48ae7691362f156e2c3b3a1523d5a7fb5c1bbfbf',
    '5c917c26905991075f4d33ffdc650a6f525e5e80f10837da497af751686cab1a',
    '3362f0d0995def1ce468318bff5d6e9427b53005878fe251bee1b442366779ac',
  ),
  (
    788,
    4564,
    4583,
    'db5de6085b56eafa7738c7515a7c18a4111f1cf9f46c76df6640e46b681e48fa',
    'f13fda5de688afbafbe3ac0e5f3d0b6cbeb858fc022c42b44f25a734e0e51374',
    '9a895fce740a4da47c3077073cf9bf59fb80ace3fc11d3623152a982c990e522',
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'two exact bundled rule equivalents retain ID-scoped adult evidence',
    () async {
      final rows = (await _catalog())['records'] as List;
      expect((rows[484] as Map)['bookSourceName'], contains('🔞'));
      expect((rows[788] as Map)['bookSourceName'], contains('🔞'));
      final labelledOld = parseBookSourceRecord(rows[484]);
      for (final pair in _pairs) {
        final labelled = parseBookSourceRecord(rows[pair.$1]);
        final candidate = parseBookSourceRecord(rows[pair.$2]);
        final other = parseBookSourceRecord(rows[pair.$3]);
        expect(labelled.id, pair.$4);
        expect(candidate.id, pair.$5);
        expect(candidate.id, isNot(labelled.id));
        expect(candidate.endpoint, labelled.endpoint);
        expect(candidate.kind, labelled.kind);
        expect(candidate.format, labelled.format);
        expect(legadoSourceFingerprint(labelled.legado!), pair.$6);
        expect(legadoSourceFingerprint(candidate.legado!), pair.$6);
        expect(adultBookSource(labelled), isTrue);
        expect(adultBundledSourceId(candidate.id), isTrue);
        expect(adultBookSource(candidate), isTrue);
        expect(other.endpoint.host, candidate.endpoint.host);
        expect(other.id, isNot(candidate.id));
        expect(legadoSourceFingerprint(other.legado!), isNot(pair.$6));
        expect(adultBookHost(other.endpoint.host), isFalse);
        expect(adultBookSource(other), isFalse);
        final revised = BookSource.fromJson({
          ...candidate.toJson(),
          'legado': {
            ...candidate.legado!.toJson(),
            'search': '/changed?q={{key}}',
          },
        });
        expect(revised.id, candidate.id);
        expect(adultBookSource(revised), isTrue);
      }
      expect(labelledOld.id, _pairs.first.$4);
    },
  );

  test(
    'catalog selection persists adult evidence for both independent IDs',
    () async {
      final archive = await _catalog();
      final rows = archive['records'] as List;
      final packs = archive['packs'] as Map;
      final manifest =
          jsonDecode(
                await File(
                  'assets/catalogs/books/legado/manifest.json',
                ).readAsString(),
              )
              as Map;
      final imported = parseBookSourceRecords([
        for (final pack in manifest['packs'] as List)
          for (final index in packs[pack['id']] as List) rows[index as int],
      ]);
      for (final pair in _pairs) {
        final candidate = imported.sources.singleWhere(
          (item) => item.id == pair.$5,
        );
        expect(candidate.adultEvidence, isTrue);
        expect(adultBookSource(candidate), isTrue);
      }
    },
  );

  test(
    'filtering blocks each source and offline book, not another same-host ID',
    () async {
      final rows = (await _catalog())['records'] as List;
      final candidates = [
        for (final pair in _pairs) parseBookSourceRecord(rows[pair.$2]),
      ];
      final others = [
        for (final pair in _pairs) parseBookSourceRecord(rows[pair.$3]),
      ];
      final root = await Directory.systemTemp.createTemp(
        'equivalent-adult-ids-',
      );
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
      expect(services.contentPolicy.filterAdult, isTrue);
      final changes = await services.books.importSources([
        ...candidates,
        ...others,
      ]);
      expect(changes.skipped, 2);
      expect(changes.added, 2);
      final books = <(Book, BookChapter)>[];
      for (var i = 0; i < candidates.length; i++) {
        final source = candidates[i];
        await services.books.store.write('books_source:${source.id}', {
          'source': source.toJson(),
          'enabled': true,
        });
        final book = Book(
          source.id,
          BookKind.text,
          '普通标题$i',
          '',
          source.endpoint.resolve('/book/$i'),
        );
        final chapter = BookChapter(
          '第一章',
          source.endpoint.resolve('/chapter/$i'),
        );
        await services.books.store.saveText(book, chapter, '原有离线正文$i');
        books.add((book, chapter));
      }
      await services.books.refreshSourceRisks();
      for (var i = 0; i < candidates.length; i++) {
        final source = candidates[i];
        final (book, chapter) = books[i];
        expect(services.books.sourceAllowed(source), isFalse);
        expect(services.books.sourceAllowed(others[i]), isTrue);
        expect(services.books.bookAllowed(book), isFalse);
        await expectLater(
          services.books.readText(book, chapter, CancellationToken()),
          throwsA(isA<ContentBlocked>()),
        );
        expect(await services.books.store.text(book, chapter), '原有离线正文$i');
      }
      await services.settings.update({'filterAdult': false});
      for (var i = 0; i < candidates.length; i++) {
        final (book, chapter) = books[i];
        expect(
          await services.books.readText(book, chapter, CancellationToken()),
          '原有离线正文$i',
        );
        await services.books.removeSource(candidates[i]);
      }
      await services.settings.update({'filterAdult': true});
      for (var i = 0; i < candidates.length; i++) {
        final (book, chapter) = books[i];
        expect(services.books.bookAllowed(book), isFalse);
        await expectLater(
          services.books.readText(book, chapter, CancellationToken()),
          throwsA(isA<ContentBlocked>()),
        );
        expect(services.books.sourceAllowed(others[i]), isTrue);
      }
    },
  );
}

Future<Map> _catalog() async {
  final bytes = await File(
    'assets/catalogs/books/legado/catalog.json.bz2',
  ).readAsBytes();
  return jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(bytes))) as Map;
}
