import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/header_policy.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/data/books_repository.dart';
import 'package:zero_player/features/books/data/legado/legado_discovery.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/legado_source.dart';
import 'package:zero_player/features/books/domain/legado_source_fingerprint.dart';

const _sourceId =
    '99dec828e154116574529a7c8013e0e1d08c12ccb01ffa57a1da3ee7aebb8654';
const _oldRulesDigest =
    '831e0cc10732d8493f297e45d6df8edf132f4b4eb4c14a03b2234de9e21d73f1';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map raw;
  setUpAll(() async {
    final bytes = await File(
      'assets/catalogs/books/legado/catalog.json.bz2',
    ).readAsBytes();
    final catalog =
        jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(bytes))) as Map;
    raw = (catalog['records'] as List)[168] as Map;
  });

  test('the exact imported and persisted old versions lose only check-in', () {
    final source = parseBookSourceRecord(raw);
    expect(source.id, _sourceId);
    final old = _oldVersion(source, raw);
    final previous = LegadoSource.fromJson(old['legado'] as Map);
    expect(legadoSourceFingerprint(previous), _oldRulesDigest);
    expect(previous.categories.single.title, '签到');
    expect(previous.categories.single.address, contains('"method":"POST"'));

    for (final fixed in [source, BookSource.fromJson(old)]) {
      expect(fixed.id, source.id);
      expect(fixed.hasSearch, isTrue);
      expect(fixed.hasDiscovery, isFalse);
      expect(fixed.legado!.categories, isEmpty);
      expect(fixed.legado!.search, previous.search);
      expect(fixed.legado!.rules, previous.rules);
      expect(fixed.legado!.headers, previous.headers);
      expect(fixed.legado!.comment, previous.comment);
      expect(
        () => fixed.resolve(fixed.endpoint, 'https://other.example/'),
        throwsFormatException,
      );
    }
  });

  test(
    'different identities, endpoints and user rule changes are untouched',
    () {
      final source = parseBookSourceRecord(raw);
      final old = _oldVersion(source, raw);
      final legacy = old['legado'] as Map;
      final categories = legacy['explore'] as List;
      final variants = <Map>[
        {...old, 'url': 'https://www.bbs.fanfanu.com/'},
        {...old, 'sourceKey': 'custom:forum'},
        {...old, 'discover': '/custom-discovery'},
        {
          ...old,
          'legado': {...legacy, 'search': '${legacy['search']}##custom'},
        },
        {
          ...old,
          'legado': {...legacy, 'library': 'custom'},
        },
        {
          ...old,
          'legado': {...legacy, 'comment': 'custom'},
        },
        {
          ...old,
          'legado': {
            ...legacy,
            'rules': {...legacy['rules'] as Map, 'content': 'custom'},
          },
        },
        {
          ...old,
          'legado': {
            ...legacy,
            'explore': [
              ...categories,
              {'title': '自定义', 'url': '/books'},
            ],
          },
        },
      ];
      for (final variant in variants) {
        final custom = BookSource.fromJson(variant);
        expect(custom.legado!.categories.first.title, '签到');
      }
      // Removing the leading www produces the same legacy ID; the exact
      // endpoint check must still protect the unrelated configuration.
      expect(BookSource.fromJson(variants.first).id, source.id);
    },
  );

  test(
    'single-source and aggregate discovery make no check-in request',
    () async {
      final requests = <(String, Uri)>[];
      await HttpOverrides.runZoned(() async {
        final root = await Directory.systemTemp.createTemp(
          'fanfanu-discovery-',
        );
        final services = AppServices.scoped(root, AppDatabase.memory());
        try {
          await services.settings.load();
          await services.supervision.load();
          final repo = services.books;
          for (final entry in await repo.sources(
            BookKind.text,
            enabledOnly: true,
          )) {
            await repo.saveSource(entry.source, {'enabled': false});
          }

          // This dummy request verifies the fixture sees network attempts while
          // its fake HttpClient cannot create a socket or contact any host.
          final dummy = Uri.parse('https://fixture.invalid/check');
          await expectLater(
            services.http.open(dummy, policy: HeaderPolicy({dummy: const {}})),
            throwsA(isA<SocketException>()),
          );
          expect(requests.single.$1, 'GET');
          requests.clear();

          final source = parseBookSourceRecord(raw);
          await repo.importSources([source]);
          await repo.saveSource(source, {'enabled': true});
          await _checkDiscovery(repo, source, requests);

          // Store the original data as an upgrade fixture; loading it must not
          // rewrite it, alter the user's state, or expose the old check-in.
          final saved = <String, Object?>{
            'source': _oldVersion(source, raw),
            'enabled': true,
            'favorite': true,
            'group': '我的收藏',
          };
          await repo.store.write('books_source:$_sourceId', saved);
          await repo.refreshSourceRisks();
          final entry = (await repo.sources(
            BookKind.text,
          )).singleWhere((entry) => entry.source.id == _sourceId);
          expect(entry.enabled, isTrue);
          expect(entry.favorite, isTrue);
          expect(entry.group, '我的收藏');
          expect(await repo.store.read('books_source:$_sourceId'), saved);
          await _checkDiscovery(repo, entry.source, requests);
        } finally {
          await services.close();
          await root.delete(recursive: true);
        }
      }, createHttpClient: (_) => _DenyHttpClient(requests));
    },
  );
}

Map<String, Object?> _oldVersion(BookSource source, Map raw) => {
  ...source.toJson(),
  'legado': {
    ...source.legado!.toJson(),
    'explore': legadoCategories(
      raw['exploreUrl'],
    ).map((category) => category.toJson()).toList(),
  },
};

Future<void> _checkDiscovery(
  BooksRepository repo,
  BookSource source,
  List<(String, Uri)> requests,
) async {
  final token = CancellationToken();
  expect(await repo.categories(BookKind.text, source.id, token), isEmpty);
  final single = await repo.discover(BookKind.text, source.id, token);
  expect(single.books, isEmpty);
  int? total;
  final aggregate = await repo.find(
    BookKind.text,
    '',
    token,
    sourceIds: {source.id},
    onProgress: (update) => total = update.total,
  );
  expect(total, 0);
  expect(aggregate.books, isEmpty);
  await repo.probe(source, '', token);
  expect(requests, isEmpty);
}

/// All attempted HTTP requests stop here; no DNS lookup or socket is opened.
final class _DenyHttpClient implements HttpClient {
  _DenyHttpClient(this.requests);
  final List<(String, Uri)> requests;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) {
    requests.add((method, uri));
    return Future.error(const SocketException('network disabled in fixture'));
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
