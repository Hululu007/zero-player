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

const _sourceId =
    '1f9aaa829a5d0312520cbcce9a4b9b84c7c12cd1d9f0adc6faecb042a9b15c17';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled source retains adult evidence by exact ID', () async {
    final archive = await _catalog();
    final record = (archive['records'] as List)[4653] as Map;
    expect(record['bookSourceName'], '渣女小说');
    expect(record['exploreUrl'], contains('耽美肉文'));
    expect(record['exploreUrl'], contains('情欲小说'));
    final source = parseBookSourceRecord(record);
    expect(source.id, _sourceId);
    expect(source.endpoint.host, 'zhanvxs.net');
    expect(adultBookLabels(source.name, source.group), isFalse);
    expect(adultBookHost(source.endpoint.host), isFalse);
    expect(adultBundledSourceId(source.id), isTrue);
    expect(adultBookSource(source), isTrue);

    final other = _otherSource(source);
    expect(other.endpoint.host, source.endpoint.host);
    expect(other.id, isNot(source.id));
    expect(adultBookSource(other), isFalse);
    final renamed = BookSource.fromJson({
      ...source.toJson(),
      'name': '普通名称',
      'group': '小说',
    });
    expect(renamed.id, source.id);
    expect(adultBookSource(renamed), isTrue);

    // Legacy root identities strip www.; this is the same ID, not a host rule.
    final sameIdAlias = BookSource.fromJson({
      ...source.toJson(),
      'url': 'https://www.zhanvxs.net/',
    });
    expect(sameIdAlias.id, source.id);
    expect(adultBookHost(sameIdAlias.endpoint.host), isFalse);
    expect(adultBookSource(sameIdAlias), isTrue);
  });

  test('catalog deduplication keeps the selected source adult label', () async {
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
    final source = imported.sources.singleWhere(
      (source) => source.id == _sourceId,
    );
    expect(source.endpoint.host, 'zhanvxs.net');
    expect(source.adultEvidence, isTrue);
    expect(adultBookSource(source), isTrue);
  });

  test(
    'adult filtering hides source and offline book without blocking other IDs',
    () async {
      final source = parseBookSourceRecord(
        ((await _catalog())['records'] as List)[4653],
      );
      final other = _otherSource(source);
      final root = await Directory.systemTemp.createTemp('zhanv-adult-source-');
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

      // A previously installed source and its offline book remain restricted.
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

BookSource _otherSource(BookSource source) => BookSource.fromJson({
  ...source.toJson(),
  'name': '独立普通小说源',
  'group': '小说',
  'sourceKey': 'independent-general-zhanv-source',
  'adultEvidence': false,
  'legado': {
    'search': '/general?q={{key}}',
    'rules': {
      'searchList': '.book',
      'searchTitle': 'a@text',
      'searchLink': 'a@href',
      'chapters': '.chapters a',
      'chapterTitle': '@text',
      'chapterUrl': '@href',
      'content': '#content@html',
    },
  },
});

Future<Map> _catalog() async {
  final bytes = await File(
    'assets/catalogs/books/legado/catalog.json.bz2',
  ).readAsBytes();
  return jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(bytes))) as Map;
}
