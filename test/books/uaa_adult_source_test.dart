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
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

const _adultId =
    'f55889c694e46c91b0cb834eb5a36c861eb49963e8f86c042f164732dbdb6f06';
const _dynamicId =
    'f44c7e7d83ca20312dd48786f9bb53448cbbf8bfd737f5bff7108798d7c97ddd';
const _comicId =
    'e7830aff2d331cabbbe123bd8d94cfe614181793ee4f8fbe0e02327effb376db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bundled novel adult evidence is scoped to the exact source ID',
    () async {
      final records = (await _catalog())['records'] as List;
      final raw = records[3903] as Map;
      expect(raw['exploreUrl'], contains('肉量·全部'));
      expect(raw['exploreUrl'], contains('porn=1'));
      expect(raw['exploreUrl'], contains('porn=4'));
      final source = parseBookSourceRecord(raw);
      final comparison = parseBookSourceRecord(records[989]);
      final dynamic = parseBookSourceRecord(records[1860]);
      final comic = parseBookSourceRecord(records[3352]);
      expect(source.id, _adultId);
      expect(dynamic.id, _dynamicId);
      expect(comic.id, _comicId);
      expect(source.endpoint.host, 'api.uaa.com');
      expect(dynamic.endpoint.host, source.endpoint.host);
      expect(comic.endpoint.host, source.endpoint.host);
      expect(
        source.legado!.categories.map((entry) => entry.title),
        contains('肉量·全部'),
      );
      expect(adultBundledSourceId(source.id), isTrue);
      expect(adultBookSource(source), isTrue);
      expect(adultBookSource(comparison), isTrue);
      expect(adultBookHost(source.endpoint.host), isFalse);
      expect(adultBookSource(dynamic), isFalse);
      expect(adultBookSource(comic), isFalse);
      final renamed = BookSource.fromJson({
        ...source.toJson(),
        'name': '普通名称',
        'group': '小说',
      });
      expect(renamed.id, source.id);
      expect(adultBookSource(renamed), isTrue);
    },
  );

  test(
    'catalog deduplication retains the adult evidence for the selected ID',
    () async {
      final archive = await _catalog();
      final records = archive['records'] as List;
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
          for (final index in packs[pack['id']] as List) records[index as int],
      ]);
      final selected = imported.sources.singleWhere(
        (source) => source.id == _adultId,
      );
      expect(selected.endpoint.host, 'api.uaa.com');
      expect(selected.adultEvidence, isTrue);
      expect(adultBookSource(selected), isTrue);
    },
  );

  test(
    'adult filtering hides the novel source and cache without blocking other IDs',
    () async {
      final records = (await _catalog())['records'] as List;
      final source = parseBookSourceRecord(records[3903]);
      final other = parseBookSourceRecord(records[1860]);
      final root = await Directory.systemTemp.createTemp('uaa-adult-source-');
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
      final changes = await services.books.importSources([source, other]);
      expect(changes.skipped, 1);
      expect(changes.added, 1);
      await services.books.store.write('books_source:${source.id}', {
        'source': source.toJson(),
        'enabled': true,
      });
      final book = Book(
        source.id,
        BookKind.text,
        '普通标题',
        '',
        source.endpoint.resolve('/book/1'),
      );
      final chapter = BookChapter('第一章', source.endpoint.resolve('/chapter/1'));
      await services.books.store.saveText(book, chapter, '原有离线正文');
      await services.books.refreshSourceRisks();
      expect(services.books.sourceAllowed(source), isFalse);
      expect(services.books.sourceAllowed(other), isTrue);
      expect(
        await services.books.sourceEntry(BookKind.text, source.id),
        isNull,
      );
      expect(
        await services.books.sourceEntry(BookKind.text, other.id),
        isNotNull,
      );
      expect(services.books.bookAllowed(book), isFalse);
      await expectLater(
        services.books.readText(book, chapter, CancellationToken()),
        throwsA(isA<ContentBlocked>()),
      );
      expect(await services.books.store.text(book, chapter), '原有离线正文');

      await services.settings.update({'filterAdult': false});
      expect(services.books.sourceAllowed(source), isTrue);
      expect(
        await services.books.readText(book, chapter, CancellationToken()),
        '原有离线正文',
      );
      await services.books.removeSource(source);
      await services.settings.update({'filterAdult': true});
      expect(services.books.bookAllowed(book), isFalse);
      await expectLater(
        services.books.readText(book, chapter, CancellationToken()),
        throwsA(isA<ContentBlocked>()),
      );
      expect(services.books.sourceAllowed(other), isTrue);
    },
  );
}

Future<Map> _catalog() async {
  final bytes = await File(
    'assets/catalogs/books/legado/catalog.json.bz2',
  ).readAsBytes();
  return jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(bytes))) as Map;
}
