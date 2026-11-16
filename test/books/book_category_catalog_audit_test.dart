import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/persistence/installation_metadata.dart';
import 'package:zero_player/features/books/application/book_category_policy.dart';
import 'package:zero_player/features/books/data/book_import.dart';

// This is a bounded lexical audit of the selected bundled sources' saved
// static discovery labels. It does not fetch pages, execute discovery scripts,
// inspect user data, or establish that an unmatched source is safe. Keywords
// only select labels for review; a match alone is not an adult classification.
final _reviewTerms = RegExp(
  r'色情|情色|成人|肉文|肉漫|黄文|黄漫|黃文|黃漫|春宫|春宮|黄片|黃片|无码|無碼|'
  r'限制级|限制級|高\s*h|h\s*(?:文|小说|小說|漫)|情欲|情慾|hentai|nsfw|porn|'
  r'18\s*[+禁]|十八禁|r\s*18|强奸|強姦|性[爱愛]|自慰|乱伦|亂倫|艳情|豔情|'
  r'卖淫|賣淫|色欲|色慾|性爱|媚药|媚藥|淫乱|淫亂|禁忌之恋|禁忌之戀|群交|性奴|'
  r'bdsm|sm调教|sm調教',
  caseSensitive: false,
);

const _po18Id =
    '870b827acc3fd539dfef41d0a83dacf6699922b14f7ee3145abdc51de54d3f1c';
const _po18Restricted = {'不限·高H', '連載·高H', '完結·高H'};

// These matches are deliberately not inferred to be adult: two are ambiguous
// romance labels, while the third describes general adult education.
const _ambiguousOrOrdinary = <(String, String)>{
  ('2cd3bfc71dd8519440c0a5ef5881d1440870635e167ab843df8680ddffe92fc4', '禁忌之恋'),
  ('a8ab7fbe1df5ba8cbf622958009ec4be6145e217194cb0d897b1d543d0bd6d32', '禁忌之恋'),
  ('f0a6c5facb5c7d6d48154f9b1ebe05dbf89149a3e25c5c6e278123a7c79100ce', '成人教育'),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bounded static category review uses the actual content policy offline',
    () async {
      final tempBase = await Directory.systemTemp.resolveSymbolicLinks();
      final root = await Directory.systemTemp.createTemp(
        'book-category-catalog-audit-',
      );
      final originalRoot = await root.resolveSymbolicLinks();
      final services = AppServices.scoped(root, AppDatabase.memory());
      var requests = 0;
      try {
        await HttpOverrides.runZoned(() async {
          await services.db.write(
            'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
            [installationAccessKey, upgradedInstallationAccess],
          );
          await services.settings.load();
          await services.supervision.load();
          await services.books.ensureSourceRiskLoaded();
          expect(services.contentPolicy.filterAdult, isTrue);
          await _verifyCatalog(services);
          expect(requests, 0);
        }, createHttpClient: (_) => _NoNetwork(() => requests++));
      } finally {
        try {
          await services.close();
        } finally {
          final actualRoot = await root.resolveSymbolicLinks();
          if (path.normalize(actualRoot).toLowerCase() !=
                  path.normalize(originalRoot).toLowerCase() ||
              path.normalize(path.dirname(actualRoot)).toLowerCase() !=
                  path.normalize(tempBase).toLowerCase() ||
              !path
                  .basename(actualRoot)
                  .startsWith('book-category-catalog-audit-')) {
            throw StateError(
              'Temporary audit directory escaped its expected parent',
            );
          }
          await root.delete(recursive: true);
        }
      }
    },
  );
}

Future<void> _verifyCatalog(AppServices services) async {
  final bytes = await File(
    'assets/catalogs/books/legado/catalog.json.bz2',
  ).readAsBytes();
  final catalog =
      jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(bytes))) as Map;
  final records = catalog['records'] as List;
  final packs = catalog['packs'] as Map;
  final manifest =
      jsonDecode(
            await File(
              'assets/catalogs/books/legado/manifest.json',
            ).readAsString(),
          )
          as Map;
  final imported = parseBookSourceRecords([
    for (final pack in manifest['packs'] as List)
      for (final index in packs[pack['id']] as List) records[index as int],
  ]);
  final ledger =
      jsonDecode(
            await File(
              'docs/implementation/legado-source-ledger-20261115.json',
            ).readAsString(),
          )
          as Map;
  final byId = <String, Map>{
    for (final row in ledger['sources'] as List)
      (row as Map)['source_id'] as String: row,
  };
  expect(imported.sources.length, 2139);
  expect(
    imported.sources.map((source) => source.id).toSet(),
    byId.keys.toSet(),
  );

  var categoryCount = 0;
  var candidateCount = 0;
  var po18Matches = 0;
  final exceptionsSeen = <(String, String)>{};
  final unexpected = <(String, int, String)>[];
  for (final source in imported.sources) {
    final sourceAllowed = services.books.sourceAllowed(source);
    final categories = [
      ...?source.legado?.categories,
      ...source.discoveryCategories,
    ];
    categoryCount += categories.length;
    for (final category in categories) {
      if (!_reviewTerms.hasMatch('${category.title} ${category.group}')) {
        continue;
      }
      candidateCount++;
      final allowed = bookCategoryAllowed(services.contentPolicy, category);
      final key = (source.id, category.title);
      if (_ambiguousOrOrdinary.contains(key)) {
        exceptionsSeen.add(key);
        expect(allowed, isTrue, reason: 'ordinary or ambiguous catalog label');
      }
      if (source.id == _po18Id && _po18Restricted.contains(category.title)) {
        po18Matches++;
        expect(allowed, isFalse, reason: 'explicit mixed catalog label');
      }
      if (sourceAllowed && allowed && !_ambiguousOrOrdinary.contains(key)) {
        unexpected.add((
          source.id,
          byId[source.id]!['selected_record_index'] as int,
          category.title,
        ));
      }
    }
  }
  expect(categoryCount, 44109);
  expect(candidateCount, 136);
  expect(po18Matches, 3);
  expect(exceptionsSeen, _ambiguousOrOrdinary);
  if (unexpected.isNotEmpty) {
    final first = unexpected.first;
    fail(
      'Unreviewed category: source ${first.$1}, record ${first.$2}, '
      'label ${first.$3}; total ${unexpected.length}.',
    );
  }
}

final class _NoNetwork implements HttpClient {
  _NoNetwork(this.record);
  final void Function() record;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) {
    record();
    throw StateError('Network is disabled for this offline audit');
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isSetter) return null;
    return super.noSuchMethod(invocation);
  }
}
