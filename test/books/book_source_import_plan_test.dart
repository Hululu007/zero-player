import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/data/book_source_import_plan.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/domain/book.dart';

void main() {
  _ownershipTests();
  _identityTests();
  _batchTests();
}

void _ownershipTests() {
  test(
    'only an owning subscription may update an ordinary installed source',
    () {
      final old = _source();
      final revised = _source({'name': '修订书源'});
      for (final subscription in [null, 'other', 'owner']) {
        final plan = BookSourceImportPlan(
          [_entry(old, subscription: 'owner')],
          blockedIds: {},
          blockedAliases: {},
          subscriptionId: subscription,
        );
        expect(
          _decide(plan, revised),
          subscription == 'owner'
              ? BookSourceImportAction.update
              : BookSourceImportAction.duplicate,
        );
        expect(_decide(plan, revised), BookSourceImportAction.duplicate);
      }
    },
  );
  test(
    'catalog updates require catalog ownership and a strictly newer version',
    () {
      for (final catalog in [false, true]) {
        for (final version in [4, 5, 6]) {
          final plan = _plan([
            _entry(_source({'updatedAt': 5}), catalog: catalog),
          ], fromCatalog: true);
          expect(
            _decide(plan, _source({'updatedAt': version, 'name': '新目录名称'})),
            catalog && version > 5
                ? BookSourceImportAction.update
                : BookSourceImportAction.duplicate,
          );
        }
      }
    },
  );
  test('builtins and unchanged subscription records are never overwritten', () {
    for (final builtin in [false, true]) {
      final old = BookSource.fromJson(_source().toJson(), builtin: builtin);
      final plan = BookSourceImportPlan(
        [_entry(old, subscription: 'owner')],
        blockedIds: {},
        blockedAliases: {},
        subscriptionId: 'owner',
      );
      expect(_decide(plan, _source()), BookSourceImportAction.duplicate);
      if (builtin) {
        final other = BookSourceImportPlan(
          [_entry(old, subscription: 'owner')],
          blockedIds: {},
          blockedAliases: {},
          subscriptionId: 'owner',
        );
        expect(
          _decide(other, _source({'name': '修订'})),
          BookSourceImportAction.duplicate,
        );
      }
    }
  });
}

void _identityTests() {
  test(
    'legacy identity remains stable without merging distinct rule variants',
    () {
      final old = _legado();
      for (final key in ['https://books.example', 'variant#two', 'alias:two']) {
        final incoming = BookSource.fromJson({
          ...old.toJson(),
          'sourceKey': key,
        });
        final prepared = _plan([_entry(old)]).prepare(incoming);
        expect(
          prepared.source.id,
          key == 'https://books.example' ? old.id : incoming.id,
        );
        expect(prepared.previous != null, key == 'https://books.example');
      }
      final moved = BookSource.fromJson({
        ...old.toJson(),
        'sourceKey': 'https://books.example',
        'url': 'https://other.example/',
      });
      expect(_plan([_entry(old)]).prepare(moved).previous, isNull);
    },
  );
  test(
    'adult evidence survives updates even when only the old group labels it',
    () {
      for (final field in ['adultEvidence', 'name', 'group']) {
        final old = _source({
          if (field == 'adultEvidence') field: true,
          if (field == 'name') field: '成人小说',
        });
        final previous = _entry(old, group: field == 'group' ? '🔞' : '普通');
        final incoming = _source();
        final prepared = _plan([previous]).prepare(incoming);
        expect(prepared.source.adultEvidence, isTrue, reason: field);
        expect(incoming.adultEvidence, isFalse);
      }
    },
  );
  test(
    'blacklist aliases survive www changes but retain path and rule scope',
    () {
      final source = _source({'url': 'https://www.books.example/library?q=1'});
      final plan = BookSourceImportPlan(
        [],
        blockedIds: {},
        blockedAliases: {bookSourceBlacklistAlias(source)},
      );
      expect(
        _decide(plan, _source({'url': 'https://books.example/library?q=1'})),
        BookSourceImportAction.skip,
      );
      expect(
        _decide(plan, _source({'url': 'https://books.example/other?q=1'})),
        BookSourceImportAction.insert,
      );
      expect(
        _decide(plan, _source({'url': 'https://books.example/library?q=2'})),
        BookSourceImportAction.insert,
      );
    },
  );
}

void _batchTests() {
  test(
    'denied rows do not consume identities and remain skipped after a match',
    () {
      final plan = _plan([]);
      final source = _source();
      expect(
        _decide(plan, source, allowed: false),
        BookSourceImportAction.skip,
      );
      expect(_decide(plan, source), BookSourceImportAction.insert);
      expect(
        _decide(plan, source, allowed: false),
        BookSourceImportAction.skip,
      );
      expect(_decide(plan, source), BookSourceImportAction.duplicate);
      expect(plan.changes, (added: 1, updated: 0, duplicates: 1, skipped: 2));
    },
  );
  test(
    'custom capacity counts accepted additions, while catalog has its own budget',
    () {
      final current = List.generate(
        11999,
        (i) => _entry(_source({'url': 'https://site$i.example/'})),
      );
      for (final catalog in [false, true]) {
        final plan = _plan(current, fromCatalog: catalog);
        expect(_decide(plan, _source()), BookSourceImportAction.insert);
        expect(_decide(plan, _source()), BookSourceImportAction.duplicate);
        expect(
          _decide(plan, _source({'url': 'https://another.example/'})),
          catalog ? BookSourceImportAction.insert : BookSourceImportAction.skip,
        );
      }
      final catalogEntries = current
          .map((e) => _entry(e.source, catalog: true))
          .toList();
      expect(
        _decide(_plan(catalogEntries), _source()),
        BookSourceImportAction.insert,
      );
    },
  );
}

BookSource _source([Map<String, Object?> changes = const {}]) =>
    BookSource.fromJson({
      'name': '普通书源',
      'kind': 'text',
      'format': 'feed',
      'url': 'https://books.example/',
      ...changes,
    });

BookSource _legado() => parseBookSourceRecord({
  'bookSourceUrl': 'https://books.example/',
  'bookSourceName': '旧书源',
  'searchUrl': '/search?q={{key}}',
  'ruleContent': {'content': 'p@text'},
});

BookSourceEntry _entry(
  BookSource source, {
  String? subscription,
  bool catalog = false,
  String group = '普通',
}) => BookSourceEntry(
  source,
  true,
  true,
  group,
  '旧结果',
  1,
  subscriptionId: subscription,
  fromCatalog: catalog,
);

BookSourceImportPlan _plan(
  List<BookSourceEntry> current, {
  bool fromCatalog = false,
}) => BookSourceImportPlan(
  current,
  blockedIds: {},
  blockedAliases: {},
  fromCatalog: fromCatalog,
);

BookSourceImportAction _decide(
  BookSourceImportPlan plan,
  BookSource source, {
  bool allowed = true,
}) => plan.decide(
  plan.prepare(source),
  allowed: allowed,
  supervisionRestricted: false,
);
