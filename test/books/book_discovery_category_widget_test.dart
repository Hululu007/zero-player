import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/persistence/installation_metadata.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/book_discovery_view.dart';

void main() {
  _duplicatePageTest();
  testWidgets(
    'tightened filter removes an open adult category and stale result',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1200);
      tester.view.devicePixelRatio = 1;
      final fakeHttp = _FakeHttpClient();
      late Directory root;
      late AppServices services;
      late BookSource source;
      await _io(tester, 'prepare mixed source', () async {
        root = await Directory.systemTemp.createTemp('category-widget-');
        await HttpOverrides.runZoned(() async {
          final db = AppDatabase.memory();
          services = AppServices.scoped(root, db);
          await db.write(
            'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
            [installationAccessKey, upgradedInstallationAccess],
          );
          await services.settings.load();
          await services.supervision.load();
          await services.settings.update({'filterAdult': false});
          final repo = services.books;
          for (final entry in await repo.sources(
            BookKind.text,
            enabledOnly: true,
          )) {
            await repo.saveSource(entry.source, {'enabled': false});
          }
          source = _mixedSource();
          await repo.importSources([source]);
          await repo.saveSource(source, {'enabled': true});
          await repo.store.write('books_discovery_aggregate:text', true);
        }, createHttpClient: (_) => fakeHttp);
      });
      addTearDown(() async {
        fakeHttp.release();
        await tester.pumpWidget(const SizedBox.shrink());
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await _io(tester, 'close mixed source', () async {
          await services.close();
          await root.delete(recursive: true);
        });
      });
      final entries = await tester.runAsync(
        () => services.books.sources(BookKind.text, enabledOnly: true),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BookDiscoveryView(
              repository: services.books,
              kind: BookKind.text,
              sources: entries,
              active: true,
              onOpen: (_, {bool direct = false}) {},
              onSearch: (_, _, _) {},
              onSourceFavorite: (_, _) {},
              onManage: () {},
            ),
          ),
        ),
      );
      await _waitFor(
        tester,
        'aggregate source picker',
        () => find.text('聚合渠道').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('聚合渠道'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('混合测试源'),
        ),
      );
      await _waitFor(
        tester,
        'both categories and first listing',
        () =>
            find.text('肉文').evaluate().isNotEmpty &&
            find.text('玄幻分类').evaluate().isNotEmpty &&
            find.text('旧分类作品').evaluate().isNotEmpty,
      );
      expect(find.widgetWithText(ChoiceChip, '肉文'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '玄幻分类'), findsOneWidget);

      final normalBook = Book(
        source.id,
        BookKind.text,
        '普通分类作品',
        '',
        source.endpoint.resolve('/book/1'),
      );
      final normalCard = find.byKey(ValueKey(normalBook.id));
      final normalTitle = find.descendant(
        of: normalCard,
        matching: find.text('普通分类作品'),
      );

      fakeHttp.holdAdult = true;
      await tester.tap(find.byTooltip('刷新当前页面'));
      await _waitFor(tester, 'pending old category', () => fakeHttp.waiting);
      await _io(
        tester,
        'enable adult filter',
        () => services.settings.update({'filterAdult': true}),
      );
      await tester.pump();
      expect(find.text('肉文'), findsNothing);
      expect(find.text('旧分类作品'), findsNothing);
      await _waitFor(
        tester,
        'ordinary category after policy change',
        () =>
            find.widgetWithText(ChoiceChip, '玄幻分类').evaluate().isNotEmpty &&
            normalTitle.evaluate().isNotEmpty,
      );

      // Let an uncooperative old request return after cancellation. It must not
      // repopulate the page once the category has become restricted.
      fakeHttp.release();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
      }
      expect(find.text('肉文'), findsNothing);
      expect(find.text('旧分类作品'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, '玄幻分类'), findsOneWidget);
      expect(normalCard, findsOneWidget);
      expect(normalTitle, findsWidgets);
      expect(
        fakeHttp.requests.map((uri) => uri.path),
        containsAll(['/adult', '/normal']),
      );
      expect(
        fakeHttp.requests.every((uri) => uri.host == 'mixed.example'),
        isTrue,
      );
    },
  );
}

void _duplicatePageTest() {
  testWidgets(
    'duplicate pages pause automatic loading and keep the next cursor',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fakeHttp = _FakeHttpClient()..paginate = true;
      late Directory root;
      late AppServices services;
      late List<BookSourceEntry> entries;
      await _io(tester, 'prepare duplicate discovery pages', () async {
        root = await Directory.systemTemp.createTemp('duplicate-book-pages-');
        await HttpOverrides.runZoned(() async {
          final db = AppDatabase.memory();
          services = AppServices.scoped(root, db);
          await db.write(
            'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
            [installationAccessKey, upgradedInstallationAccess],
          );
          await services.settings.load();
          await services.supervision.load();
          final repo = services.books;
          final template = _mixedSource().toJson();
          template['legado'] = {
            'explore': [
              {'title': '玄幻分类', 'url': '/normal?page={{page}}'},
            ],
            'rules': {
              ..._mixedSource().legado!.rules,
              'nextExplore': 'a.next@href',
            },
          };
          final source = BookSource.fromJson(template);
          await repo.importSources([source]);
          await repo.saveSource(source, {'enabled': true});
          entries = (await repo.sources(
            BookKind.text,
            enabledOnly: true,
          )).where((entry) => entry.source.id == source.id).toList();
        }, createHttpClient: (_) => fakeHttp);
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await _io(tester, 'close duplicate discovery pages', () async {
          await services.close();
          await root.delete(recursive: true);
        });
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BookDiscoveryView(
              repository: services.books,
              kind: BookKind.text,
              sources: entries,
              initialSourceId: entries.single.source.id,
              active: true,
              onOpen: (_, {bool direct = false}) {},
              onSearch: (_, _, _) {},
              onSourceFavorite: (_, _) {},
              onManage: () {},
            ),
          ),
        ),
      );
      await _waitFor(
        tester,
        'manual continuation',
        () => find.text('继续加载下一页').evaluate().isNotEmpty,
      );
      expect(
        fakeHttp.requests
            .where((uri) => uri.path == '/normal')
            .map((uri) => uri.queryParameters['page']),
        ['1', '2', '3'],
      );
      await tester.tap(find.text('继续加载下一页'));
      await _waitFor(
        tester,
        'new book on fourth page',
        () => find.text('第四页新书').evaluate().isNotEmpty,
      );
    },
  );
}

BookSource _mixedSource() => BookSource.fromJson({
  'name': '混合测试源',
  'url': 'https://mixed.example/',
  'kind': 'text',
  'format': 'html',
  'legado': {
    'explore': [
      {'title': '肉文', 'url': '/adult'},
      {'title': '玄幻分类', 'url': '/normal'},
    ],
    'rules': {
      'exploreList': '.bookbox',
      'exploreTitle': '.bookname a@text',
      'exploreLink': '.bookname a@href',
      'exploreCategory': '.kind@text',
      'content': '#content@text',
    },
  },
});

Future<void> _io(
  WidgetTester tester,
  String stage,
  Future<void> Function() work,
) async {
  await tester.runAsync(
    () => work().timeout(
      const Duration(seconds: 12),
      onTimeout: () => throw StateError('Timed out: $stage'),
    ),
  );
}

Future<void> _waitFor(
  WidgetTester tester,
  String stage,
  bool Function() complete,
) async {
  for (var i = 0; i < 400; i++) {
    await tester.pump(const Duration(milliseconds: 10));
    if (complete()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(complete(), isTrue, reason: 'Timed out waiting for $stage');
}

/// This fixture fabricates all responses in memory and cannot open a socket.
final class _FakeHttpClient implements HttpClient {
  final requests = <Uri>[];
  bool holdAdult = false, waiting = false, paginate = false;
  final _release = Completer<void>();

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) async {
    requests.add(uri);
    if (uri.host != 'mixed.example' || method != 'GET') {
      throw const SocketException('unexpected fixture request');
    }
    return _FakeRequest(this, uri);
  }

  @override
  void close({bool force = false}) => release();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.client, this.uri);
  final _FakeHttpClient client;
  @override
  final Uri uri;
  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  Future<HttpClientResponse> close() async {
    if (uri.path == '/adult' && client.holdAdult) {
      client.waiting = true;
      await client._release.future;
    }
    final page = int.tryParse(uri.queryParameters['page'] ?? '') ?? 1;
    final isNew = client.paginate && page == 4;
    final title = isNew
        ? '第四页新书'
        : uri.path == '/adult'
        ? '旧分类作品'
        : '普通分类作品';
    return _FakeResponse('''
      <div class="bookbox"><div class="bookname">
        <a href="/book/${isNew ? 2 : 1}">$title</a></div><span class="kind">玄幻</span></div>
      ${client.paginate && page < 4 ? '<a class="next" href="/normal?page=${page + 1}">下一页</a>' : ''}
    ''');
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class _FakeResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeResponse(this.html);
  final String html;
  @override
  int get statusCode => 200;
  @override
  final HttpHeaders headers = _FakeHeaders()
    ..set('content-type', 'text/html; charset=utf-8');

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(utf8.encode(html)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class _FakeHeaders implements HttpHeaders {
  final _values = <String, List<String>>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = [value.toString()];
  }

  @override
  String? value(String name) => _values[name.toLowerCase()]?.firstOrNull;

  @override
  void forEach(void Function(String name, List<String> values) action) =>
      _values.forEach(action);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
