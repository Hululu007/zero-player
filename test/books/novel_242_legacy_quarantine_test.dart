import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_source_risk.dart';
import 'package:zero_player/features/books/domain/legado_source_fingerprint.dart';

const _id = '67a2a1f1f3cb1fe0abba50885d93798631ac0776df9eaba887ebb6f5c0f55870';
const _fingerprint =
    '20ee8d7bb248e4657460b7b95eb51da6810e7a4d83ccc4e55992d899696642d5';

Future<Map> _catalog() async {
  final bytes = await File(
    'assets/catalogs/books/legado/catalog.json.bz2',
  ).readAsBytes();
  return jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(bytes))) as Map;
}

BookSource _withLegado(BookSource source, Map<String, Object?> changes) =>
    BookSource.fromJson({
      ...source.toJson(),
      'legado': {...source.legado!.toJson(), ...changes},
    });

void main() {
  test('the exact selected 242 novel version is unavailable', () async {
    final archive = await _catalog();
    final records = archive['records'] as List;
    final old = parseBookSourceRecord(records[2940]);
    expect(old.id, _id);
    expect(old.kind, BookKind.text);
    expect(old.format, BookFormat.html);
    expect(old.endpoint.toString(), 'https://www.242xs.info/');
    expect(legadoSourceFingerprint(old.legado!), _fingerprint);
    expect(knownUnavailableBookRule(old), isTrue);
    expect(quarantinedBookSource(old), isTrue);
    expect(quarantinedBookHost(old.endpoint.host), isFalse);
    expect(quarantinedBookSourceId(old.id), isFalse);

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
    ]).sources.where((source) => source.id == _id).toList();
    expect(selected, hasLength(1));
    expect(selected.single.endpoint.toString(), old.endpoint.toString());
    expect(legadoSourceFingerprint(selected.single.legado!), _fingerprint);
    expect(knownUnavailableBookRule(selected.single), isTrue);
  });

  test(
    'revisions and same-host identities are not broadly quarantined',
    () async {
      final records = (await _catalog())['records'] as List;
      final old = parseBookSourceRecord(records[2940]);
      final revisions = [
        _withLegado(old, {'search': '/new-search?q={{key}}'}),
        _withLegado(old, {
          'rules': {...old.legado!.rules, 'content': '#revised@html'},
        }),
        _withLegado(old, {
          'explore': [
            {'title': '新版分类', 'url': '/new-category'},
          ],
        }),
        BookSource.fromJson({
          ...old.toJson(),
          'url': old.endpoint.replace(path: '/different').toString(),
        }),
        BookSource.fromJson({
          ...old.toJson(),
          'url': old.endpoint.replace(host: '242xs.info').toString(),
        }),
      ];
      for (final revised in revisions) {
        expect(revised.id, _id);
        expect(knownUnavailableBookRule(revised), isFalse);
        expect(quarantinedBookSource(revised), isFalse);
      }
      final otherIdentity = BookSource.fromJson({
        ...old.toJson(),
        'sourceKey': 'independent-242-source',
      });
      expect(otherIdentity.id, isNot(_id));
      expect(knownUnavailableBookRule(otherIdentity), isFalse);
      expect(quarantinedBookSource(otherIdentity), isFalse);

      final reordered = _withLegado(old, {
        'rules': Map.fromEntries(old.legado!.rules.entries.toList().reversed),
      });
      expect(legadoSourceFingerprint(reordered.legado!), _fingerprint);
      expect(knownUnavailableBookRule(reordered), isTrue);
    },
  );
}
