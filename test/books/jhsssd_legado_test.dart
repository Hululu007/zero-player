import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/application/book_category_policy.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/data/legado/legado_worker.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/jhsssd_legacy_source_fix.dart';
import 'package:zero_player/features/books/domain/legado_source.dart';
import 'package:zero_player/features/books/domain/legado_source_fingerprint.dart';
import 'package:zero_player/features/settings/application/settings_controller.dart';
import 'package:zero_player/features/supervision/application/content_policy.dart';
import 'package:zero_player/features/supervision/application/supervision_controller.dart';

const _id = '3ea17136a0ff8e7ece79d304346edb613c2230e4c0ce806a0003e4a9b102dcc5';
const _oldDigest =
    '022794ec9f9953e5468daf7c04e4cec7797bc49d50c28e7fe17f473272a193a3';
const _selector = r'[property="og:novel:category"]@content';
late Map _raw;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final archive = await File(
      'assets/catalogs/books/legado/catalog.json.bz2',
    ).readAsBytes();
    final rows =
        (jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive)))
                as Map)['records']
            as List;
    _raw = rows[4651] as Map;
  });
  _registerSourceTests();
  _registerCategoryTests();
}

void _registerSourceTests() {
  test('unrelated source skips fingerprint evaluation', () {
    final malformed = {'rules': 'not a rule map'};
    final result = repairJhsssdLegadoSource({
      'kind': 'text',
      'format': 'html',
      'url': 'https://unrelated.example/',
    }, malformed);
    expect(identical(result, malformed), isTrue);
  });

  test('repairs the archived source and a previously saved disabled copy', () {
    final imported = parseBookSourceRecord(_raw);
    final saved = _oldConfiguration(imported);
    final old = LegadoSource.fromJson(saved['legado'] as Map);
    expect(imported.id, _id);
    expect(imported.endpoint.toString(), 'https://m.jhsssd.com');
    expect(imported.sourceKey, isEmpty);
    expect(legadoSourceFingerprint(old), _oldDigest);
    expect(imported.legado!.rules['infoCategory'], _selector);
    final restored = BookSource.fromJson({...saved, 'defaultEnabled': false});
    expect(restored.id, _id);
    expect(restored.defaultEnabled, isFalse);
    expect(restored.legado!.rules['infoCategory'], _selector);
    final expectedRules = {...old.rules, 'infoCategory': _selector};
    expect(restored.legado!.rules, expectedRules);
    final expectedLegado = {...old.toJson(), 'rules': expectedRules};
    expect(restored.legado!.toJson(), expectedLegado);
  });

  test(
    'same ID custom rules, endpoint and request options remain unchanged',
    () {
      final saved = _oldConfiguration(parseBookSourceRecord(_raw));
      final old = saved['legado'] as Map;
      final variants = <Map<String, Object?>>[
        {
          ...saved,
          'legado': {
            ...old,
            'rules': {...old['rules'] as Map, 'content': '.custom@text'},
          },
        },
        {
          ...saved,
          'legado': {
            ...old,
            'rules': {...old['rules'] as Map, 'infoCategory': '.custom@text'},
          },
        },
        {
          ...saved,
          'legado': {
            ...old,
            'headers': {'X-Example': 'custom'},
          },
        },
        {
          ...saved,
          'legado': {...old, 'library': '// custom'},
        },
        {
          ...saved,
          'legado': {...old, 'comment': 'custom'},
        },
        {
          ...saved,
          'legado': {
            ...old,
            'explore': [
              {'title': '自定义', 'url': '/custom'},
            ],
          },
        },
        {
          ...saved,
          'legado': {...old, 'enabledExplore': false},
        },
        {...saved, 'url': 'https://m.jhsssd.com/'},
        {...saved, 'url': 'https://m.jhsssd.com/custom'},
        {...saved, 'search': '/custom?wd={key}'},
        {
          ...saved,
          'mediaHosts': ['cdn.jhsssd.com'],
        },
      ];
      for (final variant in variants) {
        final expected = LegadoSource.fromJson(variant['legado'] as Map);
        final result = BookSource.fromJson(variant);
        expect(result.id, _id);
        expect(result.legado!.toJson(), expected.toJson());
      }
      final changedKey = {...saved, 'sourceKey': 'custom'};
      final differentSource = BookSource.fromJson(changedKey);
      expect(differentSource.id, isNot(_id));
      expect(
        differentSource.legado!.toJson(),
        LegadoSource.fromJson(old).toJson(),
      );
    },
  );
}

void _registerCategoryTests() {
  test(
    'real engine exposes restricted and ordinary category metadata',
    () async {
      final db = AppDatabase.memory();
      final settings = SettingsController(db);
      final supervision = SupervisionController(db);
      final policy = ContentPolicy(settings, supervision);
      try {
        final source = parseBookSourceRecord(_raw);
        final uri = Uri.parse('https://m.jhsssd.com/fixture');
        final book = Book(source.id, source.kind, '样例作品', '作者甲', uri);
        for (final entry in [('高H', false), ('成人小说', false), ('科幻小说', true)]) {
          final page = await runLegadoJob(
            LegadoJob(
              source,
              uri,
              LegadoOperation.details,
              book: book,
              input:
                  '<meta property="other:category" content="成人小说">'
                  '<meta property="og:novel:category" content="${entry.$1}">',
            ),
            CancellationToken(),
          );
          expect(page.books.single.category, entry.$1);
          expect(
            bookCategoryTextAllowed(policy, page.books.single.category),
            entry.$2,
          );
        }
      } finally {
        policy.dispose();
        await settings.close();
        await supervision.close();
        await db.close();
      }
    },
  );
}

Map<String, Object?> _oldConfiguration(BookSource source) {
  final rules = Map<String, String>.of(source.legado!.rules)
    ..remove('infoCategory');
  return {
    ...source.toJson(),
    'legado': {...source.legado!.toJson(), 'rules': rules},
  };
}
