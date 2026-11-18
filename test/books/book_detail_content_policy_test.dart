// Real bundled source rules with synthetic details and synthetic offline text.
// The fake HttpClient never opens a socket or runs a source's script.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/persistence/installation_metadata.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/book_detail_page.dart';
import 'package:zero_player/features/books/presentation/book_reader_page.dart';
import 'package:zero_player/features/books/domain/book_download_plan.dart';

const expectedId =
    '741f7ba69997207a3fb04701e2f1cf1fe706520e7b80d8268058ecf1321b17f3';
const cachedBody = '这是用于离线回归的普通占位正文。';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('detail policy gates old offline books and rechecks on change', (
    tester,
  ) async {
    final (:services, :http, :blocked, :offline, :refresh) = await _prepare(
      tester,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: BookDetailPage(services: services, initial: blocked),
      ),
    );
    await waitFor(
      tester,
      () =>
          http.requests.any((u) => u.path == '/book/restricted') &&
          find.text('当前内容策略限制访问此作品').evaluate().isNotEmpty,
    );
    expect(find.text('第一章 测试'), findsNothing);
    expect(find.text('开始阅读'), findsNothing);
    expect(find.text('离线下载'), findsNothing);
    expect(find.text('导出离线章节'), findsNothing);
    expect(find.text('收藏'), findsNothing);
    expect(find.text('模拟作品'), findsNothing);
    expect(http.requests.every((u) => !u.path.startsWith('/chapter/')), isTrue);
    // A real policy change rechecks the same book; it does not erase the
    // evidence and silently fall back while the filter remains active.
    await io(tester, () => services.settings.update({'filterAdult': false}));
    await waitFor(tester, () => _canRead());
    expect(find.widgetWithText(FilledButton, '开始阅读'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '开始阅读'));
    await waitFor(
      tester,
      () => find.byType(BookReaderPage).evaluate().isNotEmpty,
    );
    expect(find.byType(BookReaderPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await io(tester, () => services.settings.update({'filterAdult': true}));
    await tester.pumpWidget(
      MaterialApp(
        home: BookDetailPage(services: services, initial: offline),
      ),
    );
    await waitFor(
      tester,
      () => http.requests.any((u) => u.path == '/book/offline') && _canRead(),
    );
    // An ordinary 500 retains the existing offline path.
    expect(find.widgetWithText(FilledButton, '开始阅读'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '开始阅读'));
    await waitFor(
      tester,
      () => find.byType(BookReaderPage).evaluate().isNotEmpty,
    );
    expect(find.byType(BookReaderPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());

    // A refresh must hide the old directory while its new details are pending;
    // policy invalidation cannot publish the delayed older result afterward.
    await tester.pumpWidget(
      MaterialApp(
        home: BookDetailPage(services: services, initial: refresh),
      ),
    );
    await waitFor(tester, _canRead);
    http.refreshRestricted = true;
    http.holdNextRefresh = true;
    await tester.tap(find.byTooltip('作品操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('刷新目录'));
    await waitFor(tester, () => http.refreshWaiting);
    expect(find.text('第一章 测试'), findsNothing);
    expect(find.text('开始阅读'), findsNothing);
    expect(find.text('刷新对照'), findsNothing);
    services.contentPolicy.refresh();
    http.releaseRefresh();
    await waitFor(
      tester,
      () => find.text('当前内容策略限制访问此作品').evaluate().isNotEmpty,
    );
    expect(find.text('第一章 测试'), findsNothing);
    expect(find.text('开始阅读'), findsNothing);
    expect(find.text('刷新对照'), findsNothing);
    expect(http.requests.every((u) => u.host == 'www.nidedizhi2.com'), isTrue);
  });
  testWidgets(
    'unrelated policy refresh on an open detail keeps its chapter download running',
    (tester) async {
      final f = await _prepare(tester);
      await _allowedDownloadRefresh(tester, f.services, f.refresh, f.http);
    },
  );
}

Future<void> _allowedDownloadRefresh(
  WidgetTester tester,
  AppServices services,
  Book book,
  FakeClient http,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    MaterialApp(
      home: BookDetailPage(services: services, initial: book),
    ),
  );
  await waitFor(tester, _canRead);
  final chapters = (await services.books.store.entry(book))!.chapters;
  final task = services.bookDownloads.start(
    book,
    chapters,
    const BookDownloadPlan(1, 1, false),
  );
  await waitFor(tester, () => http.chapterWaiting);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    MaterialApp(
      home: BookDetailPage(services: services, initial: book),
    ),
  );
  await waitFor(tester, _canRead);
  services.contentPolicy.refresh();
  await tester.pump();
  expect(task.token.isCancelled, isFalse);
  http.releaseChapter();
  await tester.runAsync(() => task.done);
}

Future<
  ({
    AppServices services,
    FakeClient http,
    Book blocked,
    Book offline,
    Book refresh,
  })
>
_prepare(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 1200);
  tester.view.devicePixelRatio = 1;
  AppServices? closeable;
  Directory? createdRoot;
  String? tempBase, initialRoot;
  late AppServices services;
  late Book blocked, offline, refresh;
  final http = FakeClient();
  addTearDown(() async {
    http.releaseRefresh();
    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await io(tester, () async {
      try {
        await closeable?.close();
      } finally {
        final root = createdRoot;
        if (root != null && tempBase != null && initialRoot != null) {
          final actual = await root.resolveSymbolicLinks();
          if (path.normalize(actual).toLowerCase() !=
                  path.normalize(initialRoot!).toLowerCase() ||
              path.normalize(path.dirname(actual)).toLowerCase() !=
                  path.normalize(tempBase!).toLowerCase() ||
              !path.basename(actual).startsWith('book-detail-policy-')) {
            throw StateError('Temporary fixture escaped its expected parent');
          }
          await root.delete(recursive: true);
        }
      }
    });
  });
  await io(tester, () async {
    tempBase = await Directory.systemTemp.resolveSymbolicLinks();
    final root = await Directory.systemTemp.createTemp('book-detail-policy-');
    createdRoot = root;
    initialRoot = await root.resolveSymbolicLinks();
    await HttpOverrides.runZoned(() async {
      services = AppServices.scoped(root, AppDatabase.memory());
      closeable = services;
      await services.db.write(
        'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
        [installationAccessKey, upgradedInstallationAccess],
      );
      await services.settings.load();
      await services.supervision.load();
      final archive = await File(
        'assets/catalogs/books/legado/catalog.json.bz2',
      ).readAsBytes();
      final catalog =
          jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive))) as Map;
      final source = parseBookSourceRecord((catalog['records'] as List)[4533]);
      expect(source.id, expectedId);
      expect(source.legado!.rules['searchCategory'], isNull);
      expect(
        source.legado!.rules['infoCategory'],
        '.infohead@.infotype@p.1@text##类型：',
      );
      await services.books.importSources([source]);
      await services.books.saveSource(source, {'enabled': true});
      expect(services.contentPolicy.filterAdult, isTrue);
      expect(services.books.sourceAllowed(source), isTrue);
      Book sample(String name, String endpoint) => Book(
        source.id,
        source.kind,
        name,
        '作者',
        source.endpoint.resolve('/book/$endpoint'),
      );
      blocked = sample('模拟作品', 'restricted');
      offline = sample('离线对照', 'offline');
      refresh = sample('刷新对照', 'refresh');
      expect(services.books.bookAllowed(blocked), isTrue);
      for (final (book, suffix) in [
        (blocked, 'restricted'),
        (offline, 'offline'),
        (refresh, 'refresh'),
      ]) {
        final chapter = BookChapter(
          '第一章 测试',
          source.endpoint.resolve('/chapter/$suffix/1'),
        );
        await services.books.store.saveBook(book, chapters: [chapter]);
        await services.books.store.saveText(book, chapter, cachedBody);
      }
    }, createHttpClient: (_) => http);
  });
  return (
    services: services,
    http: http,
    blocked: blocked,
    offline: offline,
    refresh: refresh,
  );
}

bool _canRead() => find
    .widgetWithText(FilledButton, '开始阅读')
    .evaluate()
    .any((element) => (element.widget as FilledButton).onPressed != null);

Future<void> io(WidgetTester tester, Future<void> Function() work) async {
  await tester.runAsync(() => work().timeout(const Duration(seconds: 15)));
}

Future<void> waitFor(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 400; i++) {
    await tester.pump(const Duration(milliseconds: 10));
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  fail('timed out waiting for offline fixture');
}

final class FakeClient implements HttpClient {
  final requests = <Uri>[];
  final _refreshGate = Completer<void>();
  final _chapterGate = Completer<void>();
  bool chapterWaiting = false;
  bool refreshRestricted = false;
  bool holdNextRefresh = false;
  bool refreshWaiting = false;

  void releaseRefresh() {
    if (!_refreshGate.isCompleted) _refreshGate.complete();
  }

  void releaseChapter() {
    if (!_chapterGate.isCompleted) _chapterGate.complete();
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) async {
    requests.add(uri);
    if (method != 'GET' ||
        uri.host != 'www.nidedizhi2.com' ||
        !{
          '/book/restricted',
          '/book/offline',
          '/book/refresh',
          '/chapter/refresh/1',
        }.contains(uri.path)) {
      throw const SocketException('All non-fixture network is disabled');
    }
    return FakeRequest(this, uri);
  }

  @override
  void close({bool force = false}) {
    releaseRefresh();
    releaseChapter();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class FakeRequest implements HttpClientRequest {
  FakeRequest(this.client, this.uri);
  final FakeClient client;
  @override
  final Uri uri;
  @override
  final HttpHeaders headers = FakeHeaders();
  @override
  Future<HttpClientResponse> close() async {
    if (uri.path == '/chapter/refresh/1') {
      client.chapterWaiting = true;
      await client._chapterGate.future;
      return FakeResponse('', 500);
    }
    if (uri.path == '/book/refresh' && client.holdNextRefresh) {
      client.holdNextRefresh = false;
      client.refreshWaiting = true;
      await client._refreshGate.future;
    }
    if (uri.path == '/book/offline') return FakeResponse('', 500);
    final restricted =
        uri.path == '/book/restricted' || client.refreshRestricted;
    final category = restricted ? '情欲小说' : '言情小说';
    return FakeResponse(
      '<div class="infohead"><h3>模拟作品</h3><div class="infotype"><p>作者</p><p>类型：$category</p></div></div>',
      200,
    );
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class FakeResponse extends Stream<List<int>>
    implements HttpClientResponse {
  FakeResponse(this.html, this.statusCode);
  final String html;
  @override
  final int statusCode;
  @override
  final HttpHeaders headers = FakeHeaders()
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

final class FakeHeaders implements HttpHeaders {
  final values = <String, List<String>>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = [value.toString()];
  @override
  String? value(String name) => values[name.toLowerCase()]?.firstOrNull;
  @override
  void forEach(void Function(String, List<String>) action) =>
      values.forEach(action);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
