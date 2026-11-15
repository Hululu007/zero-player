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

const _oldId =
    '827f2fea6fcae97d0fde45d48abffc4ffd50afd13f6bc8b6b721041ddeb95dc4';
const _oldFingerprint =
    'c58f2700582d62767afd6fec65ffe4e9f48cb8de847879895a725501ee04be27';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('both bundled records and the selected version match exactly', () async {
    final archive = await _catalog();
    final records = archive['records'] as List;
    for (final index in [1014, 2859]) {
      final source = parseBookSourceRecord(records[index]);
      expect(source.id, _oldId);
      expect(source.endpoint.toString(), 'https://www.taotaoshu8.com/');
      expect(legadoSourceFingerprint(source.legado!), _oldFingerprint);
      expect(knownUnavailableBookRule(source), isTrue);
      expect(quarantinedBookSource(source), isTrue);
      expect(quarantinedBookHost(source.endpoint.host), isFalse);
      expect(quarantinedBookSourceId(source.id), isFalse);
      final renamed = BookSource.fromJson({
        ...source.toJson(),
        'name': '自定义名称',
        'group': '自定义分组',
      });
      expect(knownUnavailableBookRule(renamed), isTrue);
      final reordered = _withLegado(source, {
        'rules': Map.fromEntries(
          source.legado!.rules.entries.toList().reversed,
        ),
      });
      expect(knownUnavailableBookRule(reordered), isTrue);
    }

    final manifest =
        jsonDecode(
              await File(
                'assets/catalogs/books/legado/manifest.json',
              ).readAsString(),
            )
            as Map;
    final packs = archive['packs'] as Map;
    final parsed = parseBookSourceRecords([
      for (final pack in manifest['packs'] as List)
        for (final index in packs[pack['id']] as List) records[index as int],
    ]);
    final matching = parsed.sources
        .where((source) => source.endpoint.host == 'www.taotaoshu8.com')
        .toList();
    expect(matching, hasLength(1));
    expect(matching.single.id, _oldId);
    expect(knownUnavailableBookRule(matching.single), isTrue);
  });

  test(
    'same ID collisions and any changed request field remain available',
    () async {
      final records = (await _catalog())['records'] as List;
      final old = parseBookSourceRecord(records[1014]);
      final variants = <BookSource>[
        _withLegado(old, {'search': '/new-search?q={{key}}'}),
        _withLegado(old, {'comment': '新的说明'}),
        _withLegado(old, {'library': '// a different local rule'}),
        _withLegado(old, {
          'headers': {'User-Agent': 'updated'},
        }),
        _withLegado(old, {'enabledExplore': false}),
        _withLegado(old, {'bookUrlPattern': '/book/.*'}),
        _withLegado(old, {
          'explore': [
            {'title': '新版分类', 'url': '/categories'},
          ],
        }),
        _withLegado(old, {
          'rules': {...old.legado!.rules, 'content': '#new-content@html'},
        }),
        BookSource.fromJson({
          ...old.toJson(),
          'url': 'https://taotaoshu8.com/',
        }),
        BookSource.fromJson({
          ...old.toJson(),
          'url': 'https://www.taotaoshu8.com/another',
        }),
        BookSource.fromJson({
          ...old.toJson(),
          'url': 'https://www.taotaoshu8.com/?edition=other',
        }),
      ];
      for (final revised in variants) {
        expect(revised.id, old.id);
        expect(knownUnavailableBookRule(revised), isFalse);
        expect(quarantinedBookSource(revised), isFalse);
      }
      final separate = BookSource.fromJson({
        ...old.toJson(),
        'sourceKey': 'another-source',
      });
      expect(separate.id, isNot(old.id));
      expect(quarantinedBookSource(separate), isFalse);
    },
  );

  test(
    'manual recovery requires the same endpoint and leaves it disabled',
    () async {
      final records = (await _catalog())['records'] as List;
      final old = parseBookSourceRecord(records[1014]);
      final revised = _withLegado(old, {'search': '/new-search?q={{key}}'});
      final otherEndpoint = BookSource.fromJson({
        ...revised.toJson(),
        'url': 'https://taotaoshu8.com/',
      });
      expect(otherEndpoint.id, old.id);
      final root = await Directory.systemTemp.createTemp('taotaoshu-old-rule-');
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
      expect((await services.books.importSources([old])).skipped, 1);

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
      final chapter = BookChapter('第一章', old.endpoint.resolve('/chapter/1'));
      await services.books.store.saveText(book, chapter, '原有离线正文');
      await services.books.refreshSourceRisks();
      expect(services.books.bookAllowed(book), isFalse);
      await expectLater(
        services.books.readText(book, chapter, CancellationToken()),
        throwsA(isA<ContentBlocked>()),
      );
      expect(await services.books.store.text(book, chapter), '原有离线正文');

      expect((await services.books.importSources([otherEndpoint])).skipped, 1);
      expect(
        (await services.books.importSources([
          revised,
        ], fromCatalog: true)).skipped,
        1,
      );
      expect(
        (await services.books.store.source(null, old.id))!.source.endpoint,
        old.endpoint,
      );
      expect((await services.books.importSources([revised])).updated, 1);
      final saved = (await services.books.store.source(null, old.id))!;
      expect(saved.enabled, isFalse);
      expect(saved.favorite, isTrue);
      expect(saved.group, '珍藏');
      expect(knownUnavailableBookRule(saved.source), isFalse);
      expect(services.books.bookAllowed(book), isTrue);
      expect(
        await services.books.readText(book, chapter, CancellationToken()),
        '原有离线正文',
      );

      await services.books.store.deleteSource(revised);
      await services.books.refreshSourceRisks();
      expect(services.books.bookAllowed(book), isTrue);
      expect(
        await services.books.readText(book, chapter, CancellationToken()),
        '原有离线正文',
      );
      await services.settings.update({'filterAdult': true});
      expect(services.books.bookAllowed(book), isFalse);
    },
  );
}

BookSource _withLegado(BookSource source, Map<String, Object> changes) =>
    BookSource.fromJson({
      ...source.toJson(),
      'legado': {...source.legado!.toJson(), ...changes},
    });

Future<Map> _catalog() async {
  final archive = await File(
    'assets/catalogs/books/legado/catalog.json.bz2',
  ).readAsBytes();
  return jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive))) as Map;
}
