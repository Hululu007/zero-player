import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_builtin_domain_updates.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/data/book_source_risk_store.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/data/legado/legado_request.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_source_risk.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late BookStore store;
  late BookSourceRiskStore risks;
  late BookSource old;
  setUp(() async {
    db = AppDatabase.memory();
    store = BookStore(db);
    risks = BookSourceRiskStore(db);
    final raw =
        jsonDecode(
              utf8.decode(
                BZip2Decoder().decodeBytes(
                  await File(
                    'assets/catalogs/books/legado/catalog.json.bz2',
                  ).readAsBytes(),
                ),
              ),
            )
            as Map;
    old = parseBookSourceRecord(raw['records'][4176]);
  });
  tearDown(() => db.close());
  Future<List<BookSource>> load() =>
      loadReviewedBookDomains(store, risks, migratePreferences: true);
  Future<void> install({bool enabled = true, Map? source}) =>
      store.write('books_source:${old.id}', {
        'source': source ?? old.toJson(),
        'catalog': true,
        'enabled': enabled,
        'favorite': true,
        'group': '自定义分组',
      });
  _preferencesTests(() => store, () => old, install, load);
  _restrictionTests(() => store, () => old, () => risks, install, load);
  test(
    'damaged predecessor JSON cannot prevent built-ins from loading',
    () async {
      await install(source: {...old.toJson(), 'legado': 'invalid saved data'});
      final current = (await load()).last;
      expect(await store.read('books_source:${current.id}'), isNull);
      expect(await store.read('books_source:${old.id}'), isNotNull);
      await db.write('UPDATE app_meta SET value=? WHERE key=?', [
        '{broken JSON',
        'books_source:${old.id}',
      ]);
      expect(await load(), hasLength(2));
      expect(await store.read('books_source:${current.id}'), isNull);
    },
  );
  test(
    'new defaults are disabled and reviewed rules contain no remote eval',
    () async {
      final sources = await load();
      expect(sources, hasLength(2));
      for (final source in sources) {
        expect(source.defaultEnabled, isFalse);
        expect(source.builtin, isTrue);
        expect(knownUnsafeBookRule(source), isFalse);
        expect(quarantinedBookSource(source), isFalse);
        expect(source.legado!.rules['infoCategory'], isNotEmpty);
        expect(
          () => source.requestTarget(Uri.https('unreviewed.example', '/book')),
          throwsFormatException,
        );
      }
      final request = LegadoRequest.parse(
        sources.first,
        sources.first.endpoint,
        '/modules/article/ajax2.php,{"headers":{"X-Requested-With":"XMLHttpRequest","Cookie":"secret"}}',
      );
      expect(request.headers['X-Requested-With'], 'XMLHttpRequest');
      expect(request.headers.containsKey('Cookie'), isFalse);
      // Keep archive import normalization and historical rule fingerprints
      // stable; XHR is accepted only in explicit runtime request options.
      expect(
        legadoHeaders({
          'X-Requested-With': 'XMLHttpRequest',
        }, sources.first.endpoint),
        isEmpty,
      );
    },
  );
}

void _preferencesTests(
  BookStore Function() store,
  BookSource Function() old,
  Future<void> Function({bool enabled, Map? source}) install,
  Future<List<BookSource>> Function() load,
) {
  test(
    'unchanged catalog source transfers preferences once, without moving historical data',
    () async {
      await install(enabled: true);
      final before = await store().read('books_source:${old().id}');
      final sources = await load();
      final current = sources.last;
      final state = await store().read('books_source:${current.id}') as Map;
      expect(state['enabled'], isTrue);
      expect(state['favorite'], isTrue);
      expect(state['group'], '自定义分组');
      expect(current.id, isNot(old().id));
      expect(await store().read('books_source:${old().id}'), before);
      await store().write('books_source:${current.id}', {
        'enabled': false,
        'removed': true,
      });
      await load();
      expect(await store().read('books_source:${current.id}'), {
        'enabled': false,
        'removed': true,
      });
    },
  );
  test(
    'disabled preference is preserved and edited catalog rules are not migrated',
    () async {
      await install(enabled: false);
      final current = (await load()).last;
      expect(
        (await store().read('books_source:${current.id}') as Map)['enabled'],
        isFalse,
      );
      await store().write('books_source:${current.id}', null);
      final edited = old().toJson();
      edited['legado'] = {
        ...old().legado!.toJson(),
        'library': '// user custom code',
      };
      await install(enabled: true, source: edited);
      await load();
      expect(await store().read('books_source:${current.id}'), isNull);
    },
  );
}

void _restrictionTests(
  BookStore Function() store,
  BookSource Function() old,
  BookSourceRiskStore Function() risks,
  Future<void> Function({bool enabled, Map? source}) install,
  Future<List<BookSource>> Function() load,
) {
  test(
    'blacklisted predecessor cannot reappear under its new identity',
    () async {
      await install(enabled: true);
      await store().write('books_source_blacklist', {old().id: '用户删除'});
      final current = (await load()).last;
      expect(await store().read('books_source:${current.id}'), {
        'removed': true,
        'enabled': false,
      });
    },
  );
  test(
    'manual risk evidence is retained and prevents automatic enabling',
    () async {
      await install(enabled: true);
      final risk = BookSourceAssessment(
        sourceId: old().id,
        name: old().name,
        host: old().endpoint.host,
        adult: false,
        quarantined: true,
        adultHost: false,
        quarantinedHost: false,
        version: 1,
      );
      await risks().write(risk);
      final current = (await load()).last;
      expect(
        (await store().read('books_source:${current.id}') as Map)['enabled'],
        isFalse,
      );
      expect((await risks().all())[old().id]!.quarantined, isTrue);
    },
  );
  test(
    'supervised initialization does not migrate channel preferences',
    () async {
      await install(enabled: true);
      final sources = await loadReviewedBookDomains(
        store(),
        risks(),
        migratePreferences: false,
      );
      expect(await store().read('books_source:${sources.last.id}'), isNull);
    },
  );
}
