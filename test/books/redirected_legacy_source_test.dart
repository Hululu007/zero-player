import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_source_risk.dart';
import 'package:zero_player/features/books/domain/legado_source_fingerprint.dart';

const _sources = <int, (String, String, String)>{
  3107: (
    '579f77abbbbe0d480ebcf75b9aca291c573954fac9496263f2747ac0dd2e0156',
    'https://m.newbiquge.org',
    'c9fdc25ee7e1a4cabee2d83860b0d38b5d92bbdeb0a5627490ee8c9613cbf181',
  ),
  3041: (
    'd4b04ca5fb5f99ec4197fa67c2555cbac933b04534fd16f41eefec29c21d3d29',
    'https://www.3ubook.com',
    '384f712065d76ffc451e03883e1b56bb1f76f427d29f3f9cce3363d7c55af81c',
  ),
};

Future<Map> _catalog() async {
  final bytes = await File(
    'assets/catalogs/books/legado/catalog.json.bz2',
  ).readAsBytes();
  return jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(bytes))) as Map;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only the selected source versions are unavailable', () async {
    final archive = await _catalog();
    final records = archive['records'] as List;
    final manifest =
        jsonDecode(
              await File(
                'assets/catalogs/books/legado/manifest.json',
              ).readAsString(),
            )
            as Map;
    final packs = archive['packs'] as Map;
    final selected = parseBookSourceRecords([
      for (final pack in manifest['packs'] as List)
        for (final index in packs[pack['id']] as List) records[index as int],
    ]).sources;

    for (final entry in _sources.entries) {
      final old = parseBookSourceRecord(records[entry.key]);
      final (id, endpoint, fingerprint) = entry.value;
      expect(old.id, id);
      expect(old.endpoint.toString(), endpoint);
      expect(legadoSourceFingerprint(old.legado!), fingerprint);
      final selectedVersions = selected.where((source) => source.id == id);
      expect(selectedVersions, hasLength(1));
      expect(selectedVersions.single.endpoint.toString(), endpoint);
      expect(
        legadoSourceFingerprint(selectedVersions.single.legado!),
        fingerprint,
      );
      expect(knownUnavailableBookRule(old), isTrue);
      expect(quarantinedBookSource(old), isTrue);
      expect(quarantinedBookHost(old.endpoint.host), isFalse);
      expect(quarantinedBookSourceId(old.id), isFalse);

      final revisions = [
        BookSource.fromJson({
          ...old.toJson(),
          'legado': {...old.legado!.toJson(), 'search': '/new?q={{key}}'},
        }),
        BookSource.fromJson({
          ...old.toJson(),
          'url': old.endpoint.replace(path: '/different').toString(),
        }),
        BookSource.fromJson({
          ...old.toJson(),
          'sourceKey': 'other-${entry.key}',
        }),
      ];
      for (final revised in revisions) {
        expect(knownUnavailableBookRule(revised), isFalse);
        expect(quarantinedBookSource(revised), isFalse);
      }
    }
  });

  test(
    'manual repaired version keeps prior data and remains disabled',
    () async {
      final records = (await _catalog())['records'] as List;
      final oldSources = [
        for (final index in _sources.keys)
          parseBookSourceRecord(records[index]),
      ];
      final root = await Directory.systemTemp.createTemp('redirected-source-');
      final services = AppServices.scoped(root, AppDatabase.memory());
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      await services.settings.load();
      await services.supervision.load();
      expect((await services.books.importSources(oldSources)).skipped, 2);

      for (final old in oldSources) {
        await services.books.store.write('books_source:${old.id}', {
          'source': old.toJson(),
          'enabled': true,
          'favorite': true,
          'group': '珍藏',
        });
      }
      await services.books.refreshSourceRisks();
      for (final old in oldSources) {
        final revised = BookSource.fromJson({
          ...old.toJson(),
          'legado': {...old.legado!.toJson(), 'search': '/new?q={{key}}'},
        });
        expect(
          (await services.books.importSources([
            revised,
          ], fromCatalog: true)).skipped,
          1,
        );
        expect((await services.books.importSources([revised])).updated, 1);
        final saved = (await services.books.store.source(null, old.id))!;
        expect(saved.enabled, isFalse);
        expect(saved.favorite, isTrue);
        expect(saved.group, '珍藏');
        expect(knownUnavailableBookRule(saved.source), isFalse);
      }
    },
  );
}
