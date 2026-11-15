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
  4681: (
    '17ee3b392858318a4354a4be959522d20aacc994f62ef212f6c106ece1120c61',
    'https://book.zri.moe',
    '9c1334fa8f94c82bf4cd918caddb4079e6f35083c77c880581274b7d6a922535',
  ),
  4675: (
    '3abb61dc94096774b7f9236f0195456acb2e75d05478cd1e407ca5734c1fa14f',
    'https://book.zri.moe',
    '1fe969cc7e2d0d5a3f9b5efd2aecedebbcc376b5b15c3fdada001f640e563365',
  ),
  4663: (
    '42cc09c78ea74e2db2fc2e71f767ccb5381dbed4543f198b4e0f33546631f378',
    'https://book.zri.moe/',
    '9c1334fa8f94c82bf4cd918caddb4079e6f35083c77c880581274b7d6a922535',
  ),
  4683: (
    '9a7596d1ca9b5957561a744dff5f87f688183a10550e803baeee903ec04e1b1d',
    'https://book.zri.moe/zhbyjm',
    '9c1334fa8f94c82bf4cd918caddb4079e6f35083c77c880581274b7d6a922535',
  ),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the four bundled versions are filtered without blocking their host',
    () async {
      final archive = await _catalog();
      final records = archive['records'] as List;
      for (final entry in _sources.entries) {
        final source = parseBookSourceRecord(records[entry.key]);
        expect(source.id, entry.value.$1, reason: 'record ${entry.key}');
        expect(source.endpoint.toString(), entry.value.$2);
        expect(source.kind, BookKind.text);
        expect(source.format, BookFormat.html);
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
            (source) => _sources.values.any((item) => item.$1 == source.id),
          )
          .toList();
      expect(selected, hasLength(4));
      expect(selected.every(knownUnavailableBookRule), isTrue);
    },
  );

  test(
    'same-ID revisions, different entrypoints and types stay distinct',
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
        for (final replacement in [
          {'kind': 'audio'},
          {'format': 'feed'},
        ]) {
          final otherType = BookSource.fromJson({
            ...old.toJson(),
            ...replacement,
          });
          expect(knownUnavailableBookRule(otherType), isFalse);
          expect(quarantinedBookSource(otherType), isFalse);
        }
      }
    },
  );

  test(
    'a reviewed same-entry revision restores access without an orphan ban',
    () async {
      final records = (await _catalog())['records'] as List;
      final oldSources = [
        for (final index in _sources.keys)
          parseBookSourceRecord(records[index]),
      ];
      final root = await Directory.systemTemp.createTemp('moe-rdap-old-rules-');
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

      final saved = <(Book, BookChapter)>[];
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
        saved.add((book, chapter));
      }
      await services.books.refreshSourceRisks();
      for (var index = 0; index < oldSources.length; index++) {
        final old = oldSources[index];
        final (book, chapter) = saved[index];
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
      for (final (book, _) in saved) {
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
