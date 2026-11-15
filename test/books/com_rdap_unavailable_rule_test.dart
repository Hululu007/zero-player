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

const _id = '3ea1299b20ba9e4cad740893944b9717f315f10aa3e9ca1eb972174ea415772f';
const _endpoint = 'https://www.aslwx.com/';
const _fingerprint =
    '310116cd3aba678fdece2a014720d550d35c73b07880d21effc5a62bb6f85045';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'only the selected bundled source version is temporarily unavailable',
    () async {
      final archive = await _catalog();
      final records = archive['records'] as List;
      for (final index in [123, 314]) {
        final source = parseBookSourceRecord(records[index]);
        expect(source.id, _id, reason: 'record $index');
        expect(source.kind, BookKind.text);
        expect(source.format, BookFormat.html);
        expect(source.endpoint.toString(), _endpoint);
        expect(legadoSourceFingerprint(source.legado!), _fingerprint);
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
      final imported = parseBookSourceRecords([
        for (final pack in manifest['packs'] as List)
          for (final index in packs[pack['id']] as List) records[index as int],
      ]);
      final selected = imported.sources
          .where((item) => item.id == _id)
          .toList();
      expect(selected, hasLength(1));
      expect(selected.single.endpoint.toString(), _endpoint);
      expect(legadoSourceFingerprint(selected.single.legado!), _fingerprint);
      expect(knownUnavailableBookRule(selected.single), isTrue);
    },
  );

  test(
    'different endpoint, rule, identity, kind and format remain distinct',
    () async {
      final records = (await _catalog())['records'] as List;
      final old = parseBookSourceRecord(records[123]);
      final revisions = [
        _withLegado(old, {'search': '/new-search?q={{key}}'}),
        _withLegado(old, {'comment': '新的说明'}),
        _withLegado(old, {'library': '// a different local rule'}),
        _withLegado(old, {
          'headers': {'User-Agent': 'updated'},
        }),
        _withLegado(old, {'enabledExplore': false}),
        _withLegado(old, {'bookUrlPattern': '/new-book/.*'}),
        _withLegado(old, {
          'explore': [
            {'title': '新版分类', 'url': '/categories'},
          ],
        }),
        _withLegado(old, {
          'rules': {...old.legado!.rules, 'content': '#new-content@html'},
        }),
        for (final url in [
          'https://aslwx.com/',
          'https://www.aslwx.com/another',
          'https://www.aslwx.com/?edition=other',
        ])
          BookSource.fromJson({...old.toJson(), 'url': url}),
      ];
      for (final revised in revisions) {
        expect(revised.id, old.id);
        expect(knownUnavailableBookRule(revised), isFalse);
        expect(quarantinedBookSource(revised), isFalse);
      }
      for (final change in [
        {'sourceKey': 'independent-aslwx-source'},
        {'kind': 'audio'},
        {'format': 'feed'},
      ]) {
        final separate = BookSource.fromJson({...old.toJson(), ...change});
        expect(separate.id, isNot(old.id));
        expect(knownUnavailableBookRule(separate), isFalse);
        expect(quarantinedBookSource(separate), isFalse);
      }
    },
  );

  test(
    'manual same-endpoint repair restores disabled source and preserves cache',
    () async {
      final records = (await _catalog())['records'] as List;
      final old = parseBookSourceRecord(records[123]);
      final root = await Directory.systemTemp.createTemp('com-rdap-old-rule-');
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
      expect(services.books.sourceAllowed(old), isFalse);
      expect(services.books.bookAllowed(book), isFalse);
      await expectLater(
        services.books.readText(book, chapter, CancellationToken()),
        throwsA(isA<ContentBlocked>()),
      );
      expect(await services.books.store.text(book, chapter), '原有离线正文');

      final revised = _withLegado(old, {'search': '/new-search?q={{key}}'});
      final otherEndpoint = BookSource.fromJson({
        ...revised.toJson(),
        'url': old.endpoint.replace(path: '/another').toString(),
      });
      expect(otherEndpoint.id, old.id);
      expect((await services.books.importSources([otherEndpoint])).skipped, 1);
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
  final bytes = await File(
    'assets/catalogs/books/legado/catalog.json.bz2',
  ).readAsBytes();
  return jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(bytes))) as Map;
}
