import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
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
  950: (
    '2c42e8be93e8d9a0cba17e082bb31665d2dc717c98054dcc596a318b81775211',
    'https://www.shenxianfaka.top/',
    '70961df18d8d9eacd34a07a5d9944a0bebfe87196ab98fc25fbfe25aa39be010',
  ),
  3062: (
    '2fa11264c96f40e2d97174ab5dc0393039f3235dad0d0c71b49fdbcee5d788c9',
    'https://stxt.top',
    'b8efdaed3bfc90cfdbd4b69a28b7b7d00685883b0a079b794ee121e3f8e46312',
  ),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only the two exact archived source versions are unavailable', () async {
    final catalog = await _catalog();
    final records = catalog['records'] as List;
    for (final item in _sources.entries) {
      final source = parseBookSourceRecord(records[item.key]);
      expect(source.id, item.value.$1);
      expect(source.endpoint.toString(), item.value.$2);
      expect(source.kind, BookKind.text);
      expect(source.format, BookFormat.html);
      expect(legadoSourceFingerprint(source.legado!), item.value.$3);
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

      final revised = _withLegado(source, {'search': '/revised?q={{key}}'});
      final differentComment = _withLegado(source, {'comment': '自定义修订'});
      final differentRules = _withLegado(source, {
        'rules': {...source.legado!.rules, 'content': '.custom@text'},
      });
      final differentPath = BookSource.fromJson({
        ...source.toJson(),
        'url': source.endpoint.replace(path: '/other').toString(),
      });
      final differentHost = BookSource.fromJson({
        ...source.toJson(),
        'url': source.endpoint
            .replace(
              host: source.endpoint.host.startsWith('www.')
                  ? source.endpoint.host.substring(4)
                  : 'www.${source.endpoint.host}',
            )
            .toString(),
      });
      for (final other in [
        revised,
        differentComment,
        differentRules,
        differentPath,
        differentHost,
      ]) {
        expect(other.id, source.id);
        expect(knownUnavailableBookRule(other), isFalse);
        expect(quarantinedBookSource(other), isFalse);
      }
      final differentId = BookSource.fromJson({
        ...source.toJson(),
        'sourceKey': 'fixture:independent',
      });
      expect(differentId.id, isNot(source.id));
      expect(quarantinedBookSource(differentId), isFalse);
      for (final fields in [
        {'kind': 'audio'},
        {'format': 'feed'},
      ]) {
        final otherType = BookSource.fromJson({...source.toJson(), ...fields});
        expect(knownUnavailableBookRule(otherType), isFalse);
      }
    }
    for (final index in [1646, 3551]) {
      final source = parseBookSourceRecord(records[index]);
      expect(knownUnavailableBookRule(source), isFalse);
    }
    final manifest =
        jsonDecode(
              await File(
                'assets/catalogs/books/legado/manifest.json',
              ).readAsString(),
            )
            as Map;
    final packs = catalog['packs'] as Map;
    final imported = parseBookSourceRecords([
      for (final pack in manifest['packs'] as List)
        for (final index in packs[pack['id']] as List) records[index as int],
    ]);
    final selected = imported.sources
        .where((source) => _sources.values.any((item) => item.$1 == source.id))
        .toList();
    expect(selected, hasLength(2));
    expect(selected.every(knownUnavailableBookRule), isTrue);
  });

  test(
    'manual same-entry repair preserves metadata and does not block orphans',
    () async {
      final records = (await _catalog())['records'] as List;
      final oldSources = [
        for (final index in _sources.keys)
          parseBookSourceRecord(records[index]),
      ];
      final tempBase = await Directory.systemTemp.resolveSymbolicLinks();
      final root = await Directory.systemTemp.createTemp('top-rdap-old-rules-');
      final originalRoot = await root.resolveSymbolicLinks();
      final services = AppServices.scoped(root, AppDatabase.memory());
      addTearDown(() async {
        try {
          await services.close();
        } finally {
          final actualRoot = await root.resolveSymbolicLinks();
          if (path.normalize(actualRoot).toLowerCase() !=
                  path.normalize(originalRoot).toLowerCase() ||
              path.normalize(path.dirname(actualRoot)).toLowerCase() !=
                  path.normalize(tempBase).toLowerCase() ||
              !path.basename(actualRoot).startsWith('top-rdap-old-rules-')) {
            throw StateError(
              'Temporary test directory escaped its expected parent',
            );
          }
          await root.delete(recursive: true);
        }
      });
      await services.db.write('INSERT OR REPLACE INTO app_meta VALUES(?,?)', [
        installationAccessKey,
        upgradedInstallationAccess,
      ]);
      await services.settings.load();
      await services.supervision.load();
      await services.settings.update({'filterAdult': false});
      expect((await services.books.importSources(oldSources)).skipped, 2);

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
        await services.books.refreshSourceRisks();
        expect(services.books.bookAllowed(book), isFalse);
        await expectLater(
          services.books.readText(book, chapter, CancellationToken()),
          throwsA(isA<ContentBlocked>()),
        );
        expect(await services.books.store.text(book, chapter), '原有离线正文$index');

        final revised = _withLegado(old, {'search': '/revised?q={{key}}'});
        final differentPath = BookSource.fromJson({
          ...revised.toJson(),
          'url': old.endpoint.replace(path: '/other').toString(),
        });
        expect(
          (await services.books.importSources([differentPath])).skipped,
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
