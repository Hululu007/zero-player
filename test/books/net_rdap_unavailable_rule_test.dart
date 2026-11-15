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

const _sources = <int, (String, String, String)>{
  43: (
    'b269ecd1a1c9ce6693119d5e20fc3ae82998662478c507ba7b4a1604be981ff8',
    'https://m.dushuapp.net/',
    'f45eb9e161496525811883e848ab49a5a191486b4786a264191396aad2cc008d',
  ),
  466: (
    'ca828313e6ceaa40c92460bc887e80428500586838f387e9dee325a104768804',
    'https://www.feiyuefw.net',
    'ae15c4095ae919b8fd53da14f1ce45c51b8f2de3b46cc758bedfabc8bf9e6d9a',
  ),
  1750: (
    'd572a214fd5921004a53bee151be495ec9a6419b911e6f3fcb792fc05de1491e',
    'https://www.zhijiandoukou.net/',
    'afc6d6407f26f9bcaf33c2d908589fe2d7bae7d843e631695b51ac487329e89e',
  ),
  3807: (
    'ebf204ebcbb379cd42b4e3e8ed69b9b648152bca96be6dbd6501b89db12300a5',
    'https://www.zhijiandoukou.net/',
    'afc6d6407f26f9bcaf33c2d908589fe2d7bae7d843e631695b51ac487329e89e',
  ),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only the four actual bundled old versions are unavailable', () async {
    final archive = await _catalog();
    final records = archive['records'] as List;
    for (final entry in _sources.entries) {
      final source = parseBookSourceRecord(records[entry.key]);
      expect(source.id, entry.value.$1, reason: 'record ${entry.key}');
      expect(source.endpoint.toString(), entry.value.$2);
      expect(legadoSourceFingerprint(source.legado!), entry.value.$3);
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
    for (final index in [3252, 3920, 3175]) {
      final counterexample = parseBookSourceRecord(records[index]);
      expect(knownUnavailableBookRule(counterexample), isFalse);
      expect(quarantinedBookSource(counterexample), isFalse);
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
    final selected = parsed.sources
        .where(
          (source) => _sources.values.any((entry) => entry.$1 == source.id),
        )
        .toList();
    expect(selected, hasLength(4));
    expect(selected.every(knownUnavailableBookRule), isTrue);
  });

  test(
    'same-ID revisions, endpoint collisions and other sources remain distinct',
    () async {
      final records = (await _catalog())['records'] as List;
      for (final index in _sources.keys) {
        final old = parseBookSourceRecord(records[index]);
        final revisions = [
          _withLegado(old, {'search': '/updated-search?q={{key}}'}),
          _withLegado(old, {'comment': '新的说明'}),
          _withLegado(old, {'library': '// updated local rule'}),
          _withLegado(old, {
            'rules': {...old.legado!.rules, 'content': '#new-content@html'},
          }),
          BookSource.fromJson({
            ...old.toJson(),
            'url': old.endpoint.replace(path: '/another').toString(),
          }),
          BookSource.fromJson({
            ...old.toJson(),
            'url': old.endpoint.replace(query: 'edition=other').toString(),
          }),
        ];
        for (final revised in revisions) {
          expect(revised.id, old.id, reason: 'record $index');
          expect(knownUnavailableBookRule(revised), isFalse);
          expect(quarantinedBookSource(revised), isFalse);
        }
        final separate = BookSource.fromJson({
          ...old.toJson(),
          'sourceKey': 'independent-source-$index',
        });
        expect(separate.id, isNot(old.id));
        expect(quarantinedBookSource(separate), isFalse);
      }
    },
  );

  test(
    'manual repair retains permissions and does not blacklist orphan caches',
    () async {
      final records = (await _catalog())['records'] as List;
      final oldSources = [
        for (final index in _sources.keys)
          parseBookSourceRecord(records[index]),
      ];
      final root = await Directory.systemTemp.createTemp('net-rdap-old-rules-');
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
      expect((await services.books.importSources(oldSources)).skipped, 4);
      final savedBooks = <(Book, BookChapter)>[];
      for (var index = 0; index < oldSources.length; index++) {
        final old = oldSources[index];
        await services.books.store.write('books_source:${old.id}', {
          'source': old.toJson(),
          'enabled': true,
          'favorite': true,
          'group': '珍藏',
        });
        final book = Book(
          old.id,
          BookKind.text,
          '历史作品$index',
          '',
          old.endpoint.resolve('/book/$index'),
        );
        final chapter = BookChapter(
          '第一章',
          old.endpoint.resolve('/chapter/$index'),
        );
        await services.books.store.saveText(book, chapter, '原有离线正文$index');
        savedBooks.add((book, chapter));
      }
      await services.books.refreshSourceRisks();
      for (var index = 0; index < oldSources.length; index++) {
        final old = oldSources[index];
        final (book, chapter) = savedBooks[index];
        expect(services.books.bookAllowed(book), isFalse);
        await expectLater(
          services.books.readText(book, chapter, CancellationToken()),
          throwsA(isA<ContentBlocked>()),
        );
        expect(await services.books.store.text(book, chapter), '原有离线正文$index');
        final revised = _withLegado(old, {
          'search': '/updated-search?q={{key}}',
        });
        final otherEndpoint = BookSource.fromJson({
          ...revised.toJson(),
          'url': old.endpoint.replace(path: '/another').toString(),
        });
        expect(otherEndpoint.id, old.id);
        expect(
          (await services.books.importSources([otherEndpoint])).skipped,
          1,
        );
        expect(
          (await services.books.importSources([
            revised,
          ], fromCatalog: true)).skipped,
          1,
        );
        expect((await services.books.importSources([revised])).updated, 1);
        final restored = (await services.books.store.source(null, old.id))!;
        expect(restored.enabled, isFalse);
        expect(restored.favorite, isTrue);
        expect(restored.group, '珍藏');
        expect(services.books.bookAllowed(book), isTrue);
        expect(
          await services.books.readText(book, chapter, CancellationToken()),
          '原有离线正文$index',
        );
        await services.books.store.deleteSource(revised);
        await services.books.refreshSourceRisks();
        expect(services.books.bookAllowed(book), isTrue);
        expect(
          await services.books.readText(book, chapter, CancellationToken()),
          '原有离线正文$index',
        );
      }
      await services.settings.update({'filterAdult': true});
      for (final (book, _) in savedBooks) {
        expect(services.books.bookAllowed(book), isFalse);
      }
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
