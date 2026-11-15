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
const _additional = <int, (String, String, BookKind, String)>{
  738: (
    '74c6719633e7baf3719840878666e428727b0679d7d79d72833443228cbaeb13',
    'https://open.bxzwapp.com',
    BookKind.comic,
    'bb10adc2c55354161b811cb00b1a917bb613a28ed85cd8c16e8163e4e5e7efee',
  ),
  456: (
    '11a8812a1ceaac805c31c4e30befd21f90bc597e6fe6a2ccf7ce0a99d16146e2',
    'https://www.iswsk.com',
    BookKind.text,
    '049d7b8649ec6ead8748c0e258969db8edcc2089f98fc3964d3c69987a99a696',
  ),
  914: (
    'ab389794201d206745ffd96ed9dad49cae0ac2908390aa8eb4af643d6df5a439',
    'https://api.kuduwxw.com/',
    BookKind.text,
    '685feb62d8918f6e77f8e11c6a25a898986d624a76122b62af03ac2b25d05d3a',
  ),
  1673: (
    'e0747de2a83fbf4a88e0525909fbb3dfaecf6af4b449c571e02e7aa57c3b95de',
    'https://api.kuduwxw.com/',
    BookKind.text,
    'e2e35e9ca83046a84d5af983cd13d5aeaa4043acff7c61bc979ef8642db97d99',
  ),
  165: (
    'b011c359cb7052cbad501935630e7b78b6b574e31e526771505022da8b7adef7',
    'https://api.meiguixsapp.com/',
    BookKind.text,
    '976b186a4cf7345f0da849bb85aae6a2e118f9eb9d1bee09488bfe6cd08b3e3b',
  ),
  1788: (
    '09ab5c51cd9ae2d950ca405915a0531c580ddaf24c9363159e4cbc33ca44dcb0',
    'https://www.uuhanman.com',
    BookKind.comic,
    '26d69123c17c0745d24025a3d195e4885aadea3f62cfe218e4d44507190336f0',
  ),
  429: (
    'a149908f17a173f78f4ccd72d4487345831cb1e37ed4935f0b3e4a97ddaaf560',
    'https://m.yjzhy.com',
    BookKind.text,
    '00adb73b6015d56efe64f2f2dc32bfb5a0c6719e9824b2ae69da8b4b605272c9',
  ),
  2911: (
    'e2693c7e336bccb184165046d837782c1573099afb264ba6bed38eedfd9f4b0a',
    'https://book.yuntuxs.com/',
    BookKind.text,
    '030f6f801ab5edbadddcd187370db83395c82ff313509eb237e5ee7a938d0929',
  ),
  684: (
    '496c33059ab2a13f4d3962393458b3e69423df00c14cd40342605ec8943aec8c',
    'https://get.aoyekanshu.com',
    BookKind.text,
    '6f923b60d82cf28829ab61a8864feaf7c73f01affc70d96922337144cbef8621',
  ),
  1590: (
    '2aca3269bc95693ff09dd4daf52a30924628935f0d7f76070e8a49af90b56444',
    'https://www.hanmandq.com/',
    BookKind.comic,
    'ff8cf322b697f97d8841d3083463bdd3529b41fb9f9da7e7a85a5437ba682038',
  ),
  3232: (
    '007c637e232cbc6c7f43b91853f7efd265e3bd22ced3e5a50ee54072f78c90fa',
    'https://www.xichubao.com/',
    BookKind.text,
    'e434994bb437993079d8c48cb6d18b986c84d74731102be76707ed3c9055236b',
  ),
  969: (
    'd8e028d511f6bd397a19776fc7c74a47122fdd2c5a05deb6d25a2234e359bc00',
    'https://www.xichubao.com',
    BookKind.text,
    '620650cc0fe360be0b53b5766f1e103324bd985147234190551f0bf1989c93fa',
  ),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'additional domains match exactly the selected bundled versions',
    () async {
      final archive = await _catalog();
      final records = archive['records'] as List;
      for (final entry in _additional.entries) {
        final source = parseBookSourceRecord(records[entry.key]);
        final (id, endpoint, kind, digest) = entry.value;
        expect(source.id, id, reason: 'record ${entry.key}');
        expect(source.endpoint.toString(), endpoint);
        expect(source.kind, kind);
        expect(source.format, BookFormat.html);
        expect(legadoSourceFingerprint(source.legado!), digest);
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
      for (final entry in _additional.entries) {
        final matches = imported.sources
            .where((source) => source.id == entry.value.$1)
            .toList();
        expect(matches, hasLength(1), reason: 'record ${entry.key}');
        expect(matches.single.endpoint.toString(), entry.value.$2);
        expect(legadoSourceFingerprint(matches.single.legado!), entry.value.$4);
        expect(knownUnavailableBookRule(matches.single), isTrue);
      }
    },
  );

  test(
    'additional old versions do not quarantine revisions or identity collisions',
    () async {
      final rows = (await _catalog())['records'] as List;
      for (final index in _additional.keys) {
        final old = parseBookSourceRecord(rows[index]);
        final revisions = [
          _withLegado(old, {'search': '/new-search?q={{key}}'}),
          _withLegado(old, {'comment': '新的说明'}),
          _withLegado(old, {'library': '// new local library'}),
          _withLegado(old, {
            'headers': {'User-Agent': 'updated'},
          }),
          _withLegado(old, {'enabledExplore': !old.legado!.enabledExplore}),
          _withLegado(old, {'bookUrlPattern': '/new-book/.*'}),
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
            'url': old.endpoint.replace(path: '/different').toString(),
          }),
          BookSource.fromJson({
            ...old.toJson(),
            'url': old.endpoint.replace(query: 'edition=other').toString(),
          }),
        ];
        for (final revised in revisions) {
          expect(revised.id, old.id, reason: 'record $index');
          expect(
            knownUnavailableBookRule(revised),
            isFalse,
            reason: 'record $index',
          );
          expect(
            quarantinedBookSource(revised),
            isFalse,
            reason: 'record $index',
          );
        }
        final otherId = BookSource.fromJson({
          ...old.toJson(),
          'sourceKey': 'independent-$index',
        });
        expect(otherId.id, isNot(old.id));
        expect(quarantinedBookSource(otherId), isFalse);
        for (final change in [
          {'kind': old.kind == BookKind.text ? 'comic' : 'text'},
          {'format': 'feed'},
        ]) {
          final otherType = BookSource.fromJson({...old.toJson(), ...change});
          expect(otherType.id, isNot(old.id));
          expect(knownUnavailableBookRule(otherType), isFalse);
        }
      }

      final selectedYj = parseBookSourceRecord(rows[429]);
      final olderYj = parseBookSourceRecord(rows[1958]);
      expect(olderYj.id, selectedYj.id);
      expect(olderYj.endpoint, selectedYj.endpoint);
      expect(olderYj.legado!.enabledExplore, isFalse);
      expect(knownUnavailableBookRule(olderYj), isFalse);
      final selectedYuntu = parseBookSourceRecord(rows[2911]);
      final olderYuntu = parseBookSourceRecord(rows[3515]);
      expect(olderYuntu.id, selectedYuntu.id);
      expect(olderYuntu.endpoint.toString(), 'https://book.yuntuxs.com');
      expect(knownUnavailableBookRule(olderYuntu), isFalse);

      final firstQingyu = parseBookSourceRecord(rows[914]);
      final secondQingyu = parseBookSourceRecord(rows[1673]);
      expect(firstQingyu.id, isNot(secondQingyu.id));
      expect(firstQingyu.endpoint, secondQingyu.endpoint);
      final hybrid = BookSource.fromJson({
        ...firstQingyu.toJson(),
        'legado': secondQingyu.legado!.toJson(),
      });
      expect(hybrid.id, firstQingyu.id);
      expect(knownUnavailableBookRule(hybrid), isFalse);

      final xichuWithSlash = parseBookSourceRecord(rows[3232]);
      final xichuWithoutSlash = parseBookSourceRecord(rows[969]);
      final xichuOldVariant = parseBookSourceRecord(rows[2924]);
      expect(xichuWithSlash.id, isNot(xichuWithoutSlash.id));
      expect(xichuWithSlash.endpoint.toString(), 'https://www.xichubao.com/');
      expect(xichuWithoutSlash.endpoint.toString(), 'https://www.xichubao.com');
      expect(xichuOldVariant.id, xichuWithoutSlash.id);
      expect(xichuOldVariant.endpoint, xichuWithoutSlash.endpoint);
      expect(xichuWithoutSlash.legado!.enabledExplore, isTrue);
      expect(xichuOldVariant.legado!.enabledExplore, isFalse);
      expect(knownUnavailableBookRule(xichuOldVariant), isFalse);
      expect(quarantinedBookSource(xichuOldVariant), isFalse);
      for (final pair in [
        (xichuWithSlash, xichuWithoutSlash),
        (xichuWithoutSlash, xichuWithSlash),
      ]) {
        final differentEndpoint = BookSource.fromJson({
          ...pair.$1.toJson(),
          'url': pair.$2.endpoint.toString(),
        });
        final differentRules = BookSource.fromJson({
          ...pair.$1.toJson(),
          'legado': pair.$2.legado!.toJson(),
        });
        expect(differentEndpoint.id, pair.$1.id);
        expect(differentRules.id, pair.$1.id);
        expect(knownUnavailableBookRule(differentEndpoint), isFalse);
        expect(knownUnavailableBookRule(differentRules), isFalse);
      }
    },
  );

  test(
    'new text and comic sources allow manual same-endpoint repair',
    () async {
      final records = (await _catalog())['records'] as List;
      final oldSources = [
        for (final index in [738, 914, 684, 1590, 969, 3232])
          parseBookSourceRecord(records[index]),
      ];
      final root = await Directory.systemTemp.createTemp(
        'com-rdap-extra-repair-',
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
      await services.settings.update({'filterAdult': false});
      expect(
        (await services.books.importSources(oldSources)).skipped,
        oldSources.length,
      );
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
        final book = Book(
          old.id,
          old.kind,
          '历史作品',
          '',
          old.endpoint.resolve('/book/1'),
        );
        expect(services.books.sourceAllowed(old), isFalse);
        expect(services.books.bookAllowed(book), isFalse);
        final revised = _withLegado(old, {'search': '/new-search?q={{key}}'});
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
        await services.books.store.deleteSource(revised);
        await services.books.refreshSourceRisks();
        expect(services.books.bookAllowed(book), isTrue);
      }
    },
  );

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
