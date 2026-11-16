import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/application/book_category_policy.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/data/legado/legado_worker.dart';
import 'package:zero_player/features/books/domain/biquge7_legacy_source_fix.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/legado_source.dart';
import 'package:zero_player/features/books/domain/legado_source_fingerprint.dart';
import 'package:zero_player/features/settings/application/settings_controller.dart';
import 'package:zero_player/features/supervision/application/content_policy.dart';
import 'package:zero_player/features/supervision/application/supervision_controller.dart';

const _ids = <int, String>{
  828: '03ce53f0b6632695058a7553e513b103e5aae06c34979992769d32e06af05fa8',
  3002: 'ad35798f5b42bac39ba862133be63224081484921a86a8e8e6b5570e65ca63a3',
};
const _oldDigests = <int, String>{
  828: '0a48023c241f6f1f78c6864403ae3fa68db2f8b877be0fa3981b3fd5cd1f8914',
  3002: 'e0768b6f273fc63bb1f09fc7bfb2514b749a3d15f0eb934bf797c1f6cdfac7cf',
};
late List _records;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final archive = await File(
      'assets/catalogs/books/legado/catalog.json.bz2',
    ).readAsBytes();
    _records =
        (jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive)))
                as Map)['records']
            as List;
  });
  _registerIdentityTests();
  _registerCategoryTests();
}

void _registerIdentityTests() {
  test('unrelated endpoints skip Legado fingerprint evaluation', () {
    final malformed = {'rules': 'not a rule map'};
    final result = repairBiquge7LegadoSource({
      'kind': 'text',
      'format': 'html',
      'url': 'https://unrelated.example/',
    }, malformed);
    expect(identical(result, malformed), isTrue);
  });

  test('repairs only each exact archived or saved category rule', () {
    final oldByIndex = <int, Map<String, Object?>>{};
    for (final index in _ids.keys) {
      final raw = _records[index] as Map;
      final imported = parseBookSourceRecord(raw);
      final saved = _oldConfiguration(imported, raw);
      final legacy = LegadoSource.fromJson(saved['legado'] as Map);
      oldByIndex[index] = saved;
      expect(imported.id, _ids[index]);
      expect(legadoSourceFingerprint(legacy), _oldDigests[index]);
      final restored = BookSource.fromJson(saved);
      expect(
        restored.legado!.rules['infoCategory'],
        r'[property$=category]@content',
      );
      expect(restored.legado!.rules.length, legacy.rules.length);
      for (final entry in legacy.rules.entries) {
        if (entry.key != 'infoCategory') {
          expect(restored.legado!.rules[entry.key], entry.value);
        }
      }
      final disabled = BookSource.fromJson({...saved, 'defaultEnabled': false});
      expect(disabled.defaultEnabled, isFalse);
      expect(
        disabled.legado!.rules['infoCategory'],
        r'[property$=category]@content',
      );
      _expectCustomVariants(saved, _ids[index]!);
    }
    for (final pair in [(828, 3002), (3002, 828)]) {
      final mixed = BookSource.fromJson({
        ...oldByIndex[pair.$1]!,
        'legado': oldByIndex[pair.$2]!['legado'],
      });
      expect(mixed.id, _ids[pair.$1]);
      expect(mixed.legado!.rules['infoCategory'], contains('[property~='));
    }
  });
}

void _expectCustomVariants(Map<String, Object?> saved, String id) {
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
      'legado': {...old, 'explore': []},
    },
    {
      ...saved,
      'legado': {...old, 'enabledExplore': false},
    },
    {
      ...saved,
      'discoveryCategories': [
        {'title': '自定义', 'url': '/custom'},
      ],
    },
    {...saved, 'url': 'https://www.biquge7.xyz/custom'},
  ];
  for (final variant in variants) {
    final source = BookSource.fromJson(variant);
    expect(source.id, id);
    final category = (variant['legado'] as Map)['rules'] as Map;
    expect(source.legado!.rules['infoCategory'], category['infoCategory']);
  }
}

void _registerCategoryTests() {
  test(
    'real engine preserves restricted and ordinary synthetic categories',
    () async {
      final db = AppDatabase.memory();
      final settings = SettingsController(db);
      final supervision = SupervisionController(db);
      final policy = ContentPolicy(settings, supervision);
      try {
        for (final index in _ids.keys) {
          final source = parseBookSourceRecord(_records[index] as Map);
          final uri = Uri.parse('https://www.biquge7.xyz/fixture/');
          final book = Book(source.id, source.kind, '样例作品', '作者甲', uri);
          for (final entry in [
            ('高H', false),
            ('成人小说', false),
            ('科幻小说', true),
          ]) {
            final page = await runLegadoJob(
              LegadoJob(
                source,
                uri,
                LegadoOperation.details,
                book: book,
                input:
                    '<meta property="og:novel:book_name" content="样例作品">'
                    '<meta property="og:novel:author" content="作者甲">'
                    '<meta property="og:novel:category" content="${entry.$1}">'
                    '<meta property="og:novel:status" content="连载">',
              ),
              CancellationToken(),
            );
            expect(page.books.single.category, entry.$1);
            expect(
              bookCategoryTextAllowed(policy, page.books.single.category),
              entry.$2,
            );
          }
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

Map<String, Object?> _oldConfiguration(BookSource source, Map raw) => {
  ...source.toJson(),
  'legado': {
    ...source.legado!.toJson(),
    'rules': {
      ...source.legado!.rules,
      'infoCategory': (raw['ruleBookInfo'] as Map)['kind'],
    },
  },
};
