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

const _recordIds = <int, String>{
  1952: '66013fbe61a22b463af0e4f026901e3d9edde413f5985f8b309393ede0b2b764',
  1979: 'c3728b14bdf623a3d93a4db8814ce6d121e3b498d33cd3d9d212484663fbb1dc',
  2164: '5de6055cefc4b0beb12832c615e1063bff07c5abce9ce7d9afd37ccd8a48dd0d',
  4154: '4d7296a10b257ff1b57d4933083198fb8b9a638868afbfb88aa7d5bbff2884e5',
  4275: '21ad5d2f3e7c66fdaa4b31008cd46b52e2b32228961459c135ae866206b40ddf',
  4341: '290bf6f2ed83af236dd136be2509c0c2ab48a34716ce9bbeb8e08b820afa8fb3',
  4359: '021caeaebf0bbdbe1b647c58c66214fbb5d723987a9880b4a13baafceeef033a',
  4361: 'aafb8d8470d14758abdd08865f28bbd68c896706e666d429263fd3698d3fbe2f',
  4390: '0a344963c3d4c7bf1f047281708bbe01e76a1681b0a32f430fcfd4375a67eae9',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only the nine exact bundled source versions are unavailable', () async {
    final records = await _records();
    for (final entry in _recordIds.entries) {
      final source = parseBookSourceRecord(records[entry.key]);
      expect(source.id, entry.value, reason: 'record ${entry.key}');
      expect(source.endpoint.host, 'www.iqiyi.com');
      expect(
        source.legado!.search,
        'https://www.iqiyi.com/manhua/search-keyword={{key}}_{{page}}',
      );
      expect(
        source.legado!.rules['searchList'],
        'class.stacksList@tag.li||class.cartoon-hot-ul@tag.li',
      );
      expect(
        source.legado!.categories.any(
          (category) => category.address.contains('/manhua/weekly_update/'),
        ),
        isTrue,
      );
      expect(knownUnavailableBookRule(source), isTrue, reason: source.id);
      expect(quarantinedBookSource(source), isTrue, reason: source.id);
      // The unavailable search does not establish a dangerous historical ID.
      expect(quarantinedBookSourceId(source.id), isFalse, reason: source.id);
      expect(quarantinedBookHost(source.endpoint.host), isFalse);

      final renamed = BookSource.fromJson({
        ...source.toJson(),
        'name': '自定义名称',
        'group': '自定义分组',
      });
      expect(renamed.id, source.id);
      expect(knownUnavailableBookRule(renamed), isTrue);
      final reordered = _withRules(
        source,
        Map.fromEntries(source.legado!.rules.entries.toList().reversed),
      );
      expect(knownUnavailableBookRule(reordered), isTrue);
    }
  });

  test(
    'the current bundled import contains exactly these nine old versions',
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
      final combined = <Object?>[];
      for (final pack in manifest['packs'] as List) {
        final refs = (packs[pack['id']] as List).cast<int>();
        expect(refs.length, pack['count']);
        combined.addAll(refs.map((index) => records[index]));
      }
      final imported = parseBookSourceRecords(combined);
      final blocked = imported.sources
          .where((source) => source.endpoint.host == 'www.iqiyi.com')
          .where(knownUnavailableBookRule)
          .map((source) => source.id)
          .toSet();
      expect(blocked, _recordIds.values.toSet());
    },
  );

  test('custom revisions and same-host sources are not swept in', () async {
    final records = await _records();
    final original = parseBookSourceRecord(records[4359]);
    final changedSearch = BookSource.fromJson({
      ...original.toJson(),
      'legado': {
        ...original.legado!.toJson(),
        'search': '/updated-search?key={{key}}',
      },
    });
    final changedContent = _withRules(original, {
      ...original.legado!.rules,
      'content': 'updated-content-rule',
    });
    final changedDiscovery = BookSource.fromJson({
      ...original.toJson(),
      'legado': {
        ...original.legado!.toJson(),
        'explore': [
          {'title': '新分类', 'url': '/updated-discovery'},
        ],
      },
    });
    final changedEndpoint = BookSource.fromJson({
      ...original.toJson(),
      'url': 'https://www.iqiyi.com/updated',
    });
    for (final revised in [
      changedSearch,
      changedContent,
      changedDiscovery,
      changedEndpoint,
    ]) {
      expect(revised.id, original.id);
      expect(knownUnavailableBookRule(revised), isFalse);
      expect(quarantinedBookSource(revised), isFalse);
    }
    final anotherId = BookSource.fromJson({
      ...original.toJson(),
      'sourceKey': 'independent-iqiyi-source',
    });
    expect(anotherId.id, isNot(original.id));
    expect(quarantinedBookSource(anotherId), isFalse);

    // Record 4275 uses the legacy host-derived ID, which can collide with a
    // different custom comic source on the same host and format.
    final legacy = parseBookSourceRecord(records[4275]);
    expect(legacy.sourceKey, isEmpty);
    final collision = BookSource.fromJson({
      ...legacy.toJson(),
      'url': 'https://www.iqiyi.com/another-comic',
      'legado': {
        ...legacy.legado!.toJson(),
        'search': '/another-search?key={{key}}',
      },
    });
    expect(collision.id, legacy.id);
    expect(quarantinedBookSource(collision), isFalse);
    expect(quarantinedBookSourceId(collision.id), isFalse);
  });

  test(
    'old sources are blocked while repair and orphan cache keep their boundaries',
    () async {
      final records = await _records();
      final old = parseBookSourceRecord(records[4359]);
      final revised = BookSource.fromJson({
        ...old.toJson(),
        'legado': {...old.legado!.toJson(), 'search': '/updated?q={{key}}'},
      });
      final root = await Directory.systemTemp.createTemp('iqiyi-old-rule-');
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
      final imported = await services.books.importSources([old]);
      expect(imported.skipped, 1);

      await services.books.store.write('books_source:${old.id}', {
        'source': old.toJson(),
        'enabled': true,
        'favorite': true,
        'group': '珍藏',
      });
      final book = Book(
        old.id,
        BookKind.text,
        '历史作品',
        '',
        old.endpoint.resolve('/book/1'),
      );
      final saved = BookChapter('第一章', old.endpoint.resolve('/chapter/1'));
      await services.books.store.saveText(book, saved, '原有离线正文');
      await services.books.refreshSourceRisks();
      expect(services.books.bookAllowed(book), isFalse);
      await expectLater(
        services.books.readText(book, saved, CancellationToken()),
        throwsA(isA<ContentBlocked>()),
      );
      expect(await services.books.store.text(book, saved), '原有离线正文');

      final recovery = await services.books.importSources([revised]);
      expect(recovery.updated, 1);
      final entry = (await services.books.store.source(null, old.id))!;
      expect(entry.enabled, isFalse);
      expect(entry.favorite, isTrue);
      expect(entry.group, '珍藏');
      expect(services.books.bookAllowed(book), isTrue);
      expect(
        await services.books.readText(book, saved, CancellationToken()),
        '原有离线正文',
      );

      await services.books.store.deleteSource(revised);
      await services.books.refreshSourceRisks();
      expect(services.books.bookAllowed(book), isTrue);
      expect(
        await services.books.readText(book, saved, CancellationToken()),
        '原有离线正文',
      );
      final missing = BookChapter('未缓存章节', old.endpoint.resolve('/chapter/2'));
      await expectLater(
        services.books.readText(book, missing, CancellationToken()),
        throwsFormatException,
      );
      await services.settings.update({'filterAdult': true});
      expect(services.books.bookAllowed(book), isFalse);
    },
  );
}

BookSource _withRules(BookSource source, Map<String, String> rules) =>
    BookSource.fromJson({
      ...source.toJson(),
      'legado': {...source.legado!.toJson(), 'rules': rules},
    });

Future<List> _records() async {
  return (await _catalog())['records'] as List;
}

Future<Map> _catalog() async {
  final archive = await File(
    'assets/catalogs/books/legado/catalog.json.bz2',
  ).readAsBytes();
  return jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive))) as Map;
}
