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
import 'package:zero_player/features/books/domain/sanyou_legacy_quarantine.dart';

import '../../test_support/verified_temp_directory.dart';

const _id = 'bc379d9cf7ee312a6d9813e14830fdc689be5b2371fa025529586fc3a67aec1d';
const _otherId =
    '6a45e0819c4f731d5a6edffd650e0b22eb49c8e2eccd5de320e0ae2c701c67e9';
const _rule =
    '719bcc073e57846c8fa64d94d46537f5fc764f7588af24e29c6fffdf8b210834';
const _otherRule =
    'c7ccae8b1f6031b071e57473cb987969c6a075bdd65b6767d6d1375d4d7c9e58';

Future<Map> _catalog() async {
  final bytes = await File(
    'assets/catalogs/books/legado/catalog.json.bz2',
  ).readAsBytes();
  return jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(bytes))) as Map;
}

BookSource _withRules(BookSource source, Map<String, Object?> changes) =>
    BookSource.fromJson({
      ...source.toJson(),
      'legado': {...source.legado!.toJson(), ...changes},
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestWidgetsFlutterBinding.ensureInitialized();
  test('both independently sampled selected archive versions match', () async {
    final catalog = await _catalog();
    final records = catalog['records'] as List;
    final source = parseBookSourceRecord(records[3134]);
    expect(source.id, _id);
    expect(source.sourceKey, isEmpty);
    expect(source.endpoint.toString(), 'https://www.3uxiaoshuo.com/');
    expect(source.kind, BookKind.text);
    expect(source.format, BookFormat.html);
    expect(legadoSourceFingerprint(source.legado!), _rule);
    expect(unavailableSanyouLegacySource(source), isTrue);
    expect(knownUnavailableBookRule(source), isTrue);
    expect(quarantinedBookSource(source), isTrue);
    final manifest =
        jsonDecode(
              await File(
                'assets/catalogs/books/legado/manifest.json',
              ).readAsString(),
            )
            as Map;
    final packs = catalog['packs'] as Map;
    final selected = parseBookSourceRecords([
      for (final pack in manifest['packs'] as List)
        for (final index in packs[pack['id']] as List) records[index as int],
    ]).sources.where((s) => s.id == _id).toList();
    expect(selected, hasLength(1));
    expect(unavailableSanyouLegacySource(selected.single), isTrue);
    expect(quarantinedBookHost(source.endpoint.host), isFalse);
    expect(quarantinedBookSourceId(source.id), isFalse);
    final other = parseBookSourceRecord(records[918]);
    expect(other.id, _otherId);
    expect(other.sourceKey, '3uxiaoshuo.com#%23@%E9%81%87%E7%9F%A5');
    expect(legadoSourceFingerprint(other.legado!), _otherRule);
    expect(unavailableSanyouLegacySource(other), isTrue);
    expect(knownUnavailableBookRule(other), isTrue);
    expect(quarantinedBookSource(other), isTrue);
    expect(other.legado!.rules['searchList'], '.item');
    expect(other.legado!.rules.containsKey('exploreList'), isFalse);
    final otherSelected = parseBookSourceRecords([
      for (final pack in manifest['packs'] as List)
        for (final index in packs[pack['id']] as List) records[index as int],
    ]).sources.where((s) => s.id == _otherId).toList();
    expect(otherSelected, hasLength(1));
    expect(unavailableSanyouLegacySource(otherSelected.single), isTrue);
    expect(quarantinedBookSourceId(other.id), isFalse);
  });

  test(
    'source changes, same-host identities and orphan histories do not match',
    () async {
      final records = (await _catalog())['records'] as List;
      final source = parseBookSourceRecord(records[3134]);
      final sameHost = parseBookSourceRecord(records[918]);
      expect(sameHost.id, _otherId);
      expect(sameHost.endpoint.host, source.endpoint.host);
      expect(unavailableSanyouLegacySource(sameHost), isTrue);
      for (final original in [source, sameHost]) {
        final changed = [
          _withRules(original, {'search': '/new-search?q={{key}}'}),
          _withRules(original, {
            'rules': {...original.legado!.rules, 'content': '#updated@text'},
          }),
          _withRules(original, {
            'headers': {...original.legado!.headers, 'Accept': 'text/html'},
          }),
          _withRules(original, {
            'explore': [
              {'title': '新分类', 'url': '/new-category'},
            ],
          }),
          BookSource.fromJson({
            ...original.toJson(),
            'url': 'https://www.3uxiaoshuo.com/new',
          }),
        ];
        for (final revised in changed) {
          expect(revised.id, original.id);
          expect(unavailableSanyouLegacySource(revised), isFalse);
          expect(knownUnavailableBookRule(revised), isFalse);
          expect(quarantinedBookSource(revised), isFalse);
        }
        final disabled = BookSource.fromJson({
          ...original.toJson(),
          'defaultEnabled': false,
        });
        expect(disabled.defaultEnabled, isFalse);
        expect(unavailableSanyouLegacySource(disabled), isTrue);
        expect(quarantinedBookSourceId(original.id), isFalse);
      }
      final independent = BookSource.fromJson({
        ...source.toJson(),
        'sourceKey': 'independent-sanyou',
      });
      expect(independent.id, isNot(anyOf(_id, _otherId)));
      expect(independent.endpoint.host, source.endpoint.host);
      expect(unavailableSanyouLegacySource(independent), isFalse);
      expect(knownUnavailableBookRule(independent), isFalse);
      expect(quarantinedBookSource(independent), isFalse);
      final reordered = _withRules(source, {
        'rules': Map.fromEntries(
          source.legado!.rules.entries.toList().reversed,
        ),
      });
      expect(legadoSourceFingerprint(reordered.legado!), _rule);
      expect(unavailableSanyouLegacySource(reordered), isTrue);
    },
  );

  for (final index in [3134, 918]) {
    test(
      'manual replacement of quarantined record $index preserves preferences',
      () async {
        final temporary = await VerifiedTempDirectory.create(
          'sanyou-source-recovery-',
        );
        final services = AppServices.scoped(
          temporary.directory,
          AppDatabase.memory(),
        );
        addTearDown(() async {
          await services.close();
          await temporary.delete();
        });
        await services.settings.load();
        await services.supervision.load();
        final original = parseBookSourceRecord(
          ((await _catalog())['records'] as List)[index],
        );
        final candidate = _withRules(original, {
          'rules': {...original.legado!.rules, 'content': '#reviewed@text'},
        });
        expect(candidate.id, original.id);
        expect(knownUnavailableBookRule(original), isTrue);
        expect(quarantinedBookSource(candidate), isFalse);
        await services.books.store.write('books_source:${original.id}', {
          'source': original.toJson(),
          'enabled': true,
          'favorite': true,
          'group': '珍藏分组',
          'health': '旧解析结果',
          'checkedAt': 123,
          'subscription': 'subscription-fixture',
          'catalog': true,
        });
        await services.books.refreshSourceRisks();
        expect(
          await services.books.sourceEntry(BookKind.text, original.id),
          isNull,
        );
        final changes = await services.books.importSources([candidate]);
        expect(changes.updated, 1);
        final saved = (await services.books.store.source(null, original.id))!;
        expect(saved.enabled, isFalse);
        expect(saved.favorite, isTrue);
        expect(saved.group, '珍藏分组');
        expect(saved.subscriptionId, 'subscription-fixture');
        expect(saved.fromCatalog, isTrue);
        expect(saved.health, isEmpty);
        expect(saved.checkedAt, isNull);
        expect(knownUnavailableBookRule(saved.source), isFalse);
        expect(quarantinedBookSourceId(original.id), isFalse);
        expect(quarantinedBookHost(original.endpoint.host), isFalse);
      },
    );
  }
}
