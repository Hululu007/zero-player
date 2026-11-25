import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zero_player/app/shell.dart';
import 'package:zero_player/features/books/presentation/books_page.dart';
import 'package:zero_player/features/books/presentation/book_detail_page.dart';
import 'package:zero_player/features/books/presentation/book_page_route.dart';
import 'package:zero_player/features/books/presentation/book_reader_page.dart';
import 'package:zero_player/features/books/presentation/reader_pagination.dart';
import 'package:zero_player/features/books/presentation/reader_style.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/publications/presentation/publications_page.dart';
import '../../test_support/mobile_app_fixture.dart';

late MobileAppFixture fixture;
final platformCalls = <MethodCall>[];

void main() {
  setUp(() async {
    platformCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          platformCalls.add(call);
          return null;
        });
    fixture = MobileAppFixture();
    await fixture.initialize();
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  _basicNavigationTests();
  _readingNavigationTests();
  _stackTests();
  _viewportAndExitTests();
  _immersiveRouteTest();
  _discoveryStateTest();
}

void _publicationNavigationTest() {
  testWidgets('desktop Escape returns from cloud resources', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await fixture.pump(tester, size: const Size(1100, 820));
    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    router.go('/downloads');
    await fixture.settle(tester);
    await tester.tap(find.text('网盘资源下载').hitTestable().last);
    await fixture.settle(tester);
    expect(router.state.uri.path, '/cloud-resources');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await fixture.settle(tester);
    expect(router.state.uri.path, '/downloads');
    await fixture.finish(tester);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Baidu share handoff leads back to the book library', (
    tester,
  ) async {
    await fixture.pump(tester);
    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    router.go('/cloud-resources');
    await fixture.settle(tester);
    final link = find.widgetWithText(TextField, '网盘分享链接');
    await tester.enterText(link, 'pan.baidu.com/s/fixture?pwd=ab12');
    await tester.tap(find.text('解析分享'));
    await fixture.settle(tester);
    expect(find.text('打开分享页'), findsOneWidget);

    final library = find.text('前往书库导入已下载的图书');
    await tester.ensureVisible(library);
    await tester.tap(library);
    await _waitForPublicationTabs(tester);
    await fixture.settle(tester);
    expect(router.state.uri.queryParameters['tab'], 'library');
    expect(find.text('管理分组').hitTestable(), findsOneWidget);

    router.go('/cloud-resources');
    await fixture.settle(tester);
    router.go('/publications?tab=tasks');
    await _waitForPublicationTabs(tester);
    await fixture.settle(tester);
    final tabs = tester.widget<TabBar>(find.byType(TabBar).first);
    expect(tabs.controller?.index, 2);
    await fixture.finish(tester);
  });

  testWidgets('publications swipes and system back follow the page hierarchy', (
    tester,
  ) async {
    await fixture.pump(tester);
    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    router.go('/calendar');
    await fixture.settle(tester);
    await tester.tap(find.widgetWithText(NavigationDestination, '阅读'));
    await fixture.settle(tester);
    await tester.tap(find.widgetWithText(ListTile, '出版图书'));
    await _waitForPublicationTabs(tester);

    await tester.fling(find.byType(TabBarView), const Offset(-310, 0), 800);
    await fixture.settle(tester);
    expect(find.text('管理分组').hitTestable(), findsOneWidget);
    await tester.binding.handlePopRoute();
    await fixture.settle(tester);
    expect(router.state.uri.path, '/publications');
    expect(find.byTooltip('搜索图书').hitTestable(), findsOneWidget);

    expect(find.text('渠道聚合'), findsNothing);
    await tester.tap(find.text('选择渠道'));
    await fixture.settle(tester);
    expect(find.byTooltip('定位到当前'), findsOneWidget);
    await tester.tap(find.text('收藏渠道'));
    await fixture.settle(tester);
    await tester.binding.handlePopRoute();
    await fixture.settle(tester);
    expect(router.state.uri.path, '/publications');
    expect(find.text('豆瓣读书 · Top 250').hitTestable(), findsOneWidget);

    final position = tester.getTopRight(find.byType(TabBarView));
    await tester.flingFrom(
      position + const Offset(-8, 150),
      const Offset(-130, 0),
      750,
    );
    await fixture.settle(tester);
    expect(router.state.uri.path, '/calendar');
    expect(find.text('退出 Zero Player？'), findsNothing);
    await fixture.finish(tester);
  });
}

void _readingNavigationTests() {
  _publicationNavigationTest();

  testWidgets('desktop reading expands without changing the current route', (
    tester,
  ) async {
    await fixture.pump(tester, size: const Size(1100, 820));
    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    await tester.tap(find.byTooltip('展开导航 (Ctrl+M)'));
    await fixture.settle(tester);
    final books = find.widgetWithText(ListTile, '出版图书');
    final novels = find.widgetWithText(ListTile, '网络小说');
    expect(books, findsNothing);
    expect(find.widgetWithText(ListTile, '网络漫画'), findsNothing);
    await tester.tap(find.text('阅读'));
    await fixture.settle(tester);
    expect(books, findsOneWidget);
    expect(tester.getTopLeft(books).dy, lessThan(tester.getTopLeft(novels).dy));
    expect(router.state.uri.path, '/');
    await tester.tap(books);
    await _waitForPublicationTabs(tester);
    expect(router.state.uri.path, '/publications');
    expect(find.byType(PublicationsPage), findsOneWidget);
    await tester.tap(find.byTooltip('展开导航 (Ctrl+M)'));
    await fixture.settle(tester);
    expect(find.widgetWithText(ListTile, '网络听书'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, '网络漫画'));
    await fixture.settle(tester);
    expect(router.state.uri.path, '/comics');
    await fixture.finish(tester);
  });

  testWidgets('phone reading opens the submenu before changing route', (
    tester,
  ) async {
    await fixture.pump(tester);
    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    final reading = find.widgetWithText(NavigationDestination, '阅读');
    await tester.tap(reading);
    await fixture.settle(tester);
    expect(router.state.uri.path, '/');
    final tiles = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(ListTile),
    );
    expect(
      tester
          .widgetList<ListTile>(tiles)
          .map((tile) => (tile.title! as Text).data),
      ['出版图书', '网络小说', '网络漫画', '网络听书'],
    );
    expect(tester.widgetList<ListTile>(tiles).first.selected, isFalse);
    await tester.tap(find.widgetWithText(ListTile, '出版图书'));
    await _waitForPublicationTabs(tester);
    expect(router.state.uri.path, '/publications');
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      3,
    );
    await tester.tap(reading);
    await fixture.settle(tester);
    expect(tester.widgetList<ListTile>(tiles).first.selected, isTrue);
    await tester.tap(find.widgetWithText(ListTile, '网络小说'));
    await fixture.waitFor(
      tester,
      () => find.text('书架').hitTestable().evaluate().isNotEmpty,
    );
    expect(router.state.uri.path, '/reading');
    await fixture.finish(tester);
  });

  testWidgets('TV reading keeps the novel, comic and audiobook entries', (
    tester,
  ) async {
    fixture.services.platform.television = true;
    await fixture.pump(tester, size: const Size(1100, 820));
    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    await tester.tap(find.byTooltip('展开导航 (Ctrl+M)'));
    await fixture.settle(tester);
    await tester.tap(find.text('阅读'));
    await fixture.settle(tester);
    expect(find.widgetWithText(ListTile, '出版图书'), findsNothing);
    expect(find.widgetWithText(ListTile, '网络小说'), findsOneWidget);
    expect(find.widgetWithText(ListTile, '网络漫画'), findsOneWidget);
    expect(find.widgetWithText(ListTile, '网络听书'), findsOneWidget);
    await tester.tap(find.byTooltip('收起导航'));
    await fixture.settle(tester);
    router.go('/publications');
    await fixture.waitFor(
      tester,
      () => find.textContaining('电视端暂不提供出版图书').evaluate().isNotEmpty,
    );
    expect(router.state.uri.path, '/publications');
    router.go('/cloud-resources');
    await fixture.settle(tester);
    await tester.enterText(
      find.widgetWithText(TextField, '网盘分享链接'),
      'pan.baidu.com/s/fixture',
    );
    await tester.tap(find.text('解析分享'));
    await fixture.settle(tester);
    expect(find.text('打开分享页'), findsOneWidget);
    expect(find.text('前往书库导入已下载的图书'), findsNothing);
    await fixture.finish(tester);
  });
}

Future<void> _waitForPublicationTabs(WidgetTester tester) => fixture.waitFor(
  tester,
  () => find
      .descendant(
        of: find.byType(PublicationsPage),
        matching: find.byType(TabBar),
      )
      .hitTestable()
      .evaluate()
      .isNotEmpty,
);

Future<void> _checkReadingLinks(WidgetTester tester, GoRouter router) async {
  expect(find.byTooltip('导入 EPUB / PDF / TXT').hitTestable(), findsOneWidget);
  final reading = find.widgetWithText(NavigationDestination, '阅读');
  await tester.tap(reading);
  await fixture.settle(tester);
  expect(find.widgetWithText(ListTile, '网络小说').hitTestable(), findsOneWidget);
  await tester.tap(find.widgetWithText(ListTile, '网络漫画').hitTestable());
  await fixture.settle(tester);
  expect(router.state.uri.path, '/comics');
  await tester.tap(reading);
  await fixture.settle(tester);
  await tester.tap(find.widgetWithText(ListTile, '网络听书').hitTestable());
  await fixture.settle(tester);
  expect(router.state.uri.path, '/audiobooks');
  await tester.tap(reading);
  await fixture.settle(tester);
  await tester.tap(find.widgetWithText(ListTile, '网络小说').hitTestable());
  await fixture.settle(tester);
  expect(router.state.uri.path, '/reading');
}

void _discoveryStateTest() {
  testWidgets('custom book discovery keeps scroll when switching modules', (
    tester,
  ) async {
    await tester.runAsync(() async {
      rootBundle.evict('assets/catalogs/books/verified.json');
      await rootBundle.loadString('assets/catalogs/books/verified.json');
      rootBundle.evict('assets/catalogs/books/website-sources.json');
      await rootBundle.loadString('assets/catalogs/books/website-sources.json');
      rootBundle.evict('assets/catalogs/books/reviewed-domain-updates.json');
      await rootBundle.loadString(
        'assets/catalogs/books/reviewed-domain-updates.json',
      );
    });
    var prepared = false;
    late BookSource source;
    final preparation = () async {
      for (final entry in await fixture.services.books.sources(BookKind.text)) {
        await fixture.services.books.saveSource(entry.source, {
          'enabled': false,
        });
      }
      source = BookSource.fromJson({
        'name': '本机测试书目',
        'url': 'https://reading-state.test/',
        'kind': 'text',
        'format': 'featured',
        'featured': [
          for (var i = 0; i < 40; i++)
            {'title': '星际航行$i', 'author': '作者', 'url': '/book/$i'},
        ],
        'rules': {
          'chapters': 'main a',
          'chapterTitle': 'text',
          'chapterUrl': 'href',
          'content': 'article@text',
        },
      });
      await fixture.services.books.importSources([source]);
      await fixture.services.books.saveSource(source, {'enabled': true});
      prepared = true;
    }();
    await fixture.waitFor(tester, () => prepared);
    await preparation;
    await fixture.pump(tester);
    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    router.go('/reading');
    await fixture.waitFor(
      tester,
      () => find.text('按渠道聚合').evaluate().isNotEmpty,
    );
    await _checkReadingLinks(tester, router);
    await fixture.waitFor(
      tester,
      () => find.text('按渠道聚合').hitTestable().evaluate().isNotEmpty,
    );
    await tester.tap(find.text('按渠道聚合'));
    await fixture.waitFor(
      tester,
      () => find.widgetWithText(OutlinedButton, '聚合渠道').evaluate().isNotEmpty,
    );
    await tester.tap(find.widgetWithText(OutlinedButton, '聚合渠道'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '本机测试书目'));
    await tester.pumpAndSettle();
    await fixture.waitFor(
      tester,
      () => find.text('星际航行0').evaluate().isNotEmpty,
    );
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -550));
    await tester.pumpAndSettle();
    final offset = scroll.offset;
    expect(offset, greaterThan(100));
    fixture.services.contentPolicy.refresh();
    await fixture.settle(tester);
    expect(scroll.offset, closeTo(offset, 1));
    await fixture.services.books.store.saveSource(source, {
      'health': 'ok',
      'checkedAt': 7,
    });
    router.go('/settings');
    await fixture.settle(tester);
    router.go('/reading');
    await fixture.settle(tester);
    expect(scroll.offset, closeTo(offset, 1));
    await _discoveryControls(tester, scroll);
    await fixture.finish(tester);
  });
}

Future<void> _discoveryControls(
  WidgetTester tester,
  ScrollController scroll,
) async {
  await tester.tap(find.byTooltip('返回顶部'));
  await tester.pumpAndSettle();
  expect(scroll.offset, 0);
  expect(find.byTooltip('渠道操作'), findsOneWidget);
  await tester.tap(find.byTooltip('渠道操作'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('复制渠道链接'));
  await tester.pumpAndSettle();
  expect(
    platformCalls.any(
      (call) =>
          call.method == 'Clipboard.setData' &&
          (call.arguments as Map)['text'] == 'https://reading-state.test/',
    ),
    isTrue,
  );
}

void _immersiveRouteTest() {
  testWidgets('reader covers the shell and returns to its book details', (
    tester,
  ) async {
    final book = Book(
      'local',
      BookKind.text,
      '沉浸阅读',
      '作者',
      Uri.parse('book:reader-route-fixture'),
    );
    final chapter = BookChapter('第一章 开始', book.uri.replace(fragment: '0'));
    await fixture.services.books.store.saveTexts(book, {
      chapter: '本地阅读内容。' * 500,
    });
    await fixture.services.books.store.saveBook(book, chapters: [chapter]);
    await fixture.services.books.store.write(
      'books_reader_preferences',
      const ReaderPreferences(mode: ReaderTurnMode.curl).toJson(),
    );
    await fixture.pump(tester, size: const Size(1024, 760));
    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    router.go('/reading');
    await fixture.waitFor(
      tester,
      () => find.byType(BooksPage).evaluate().isNotEmpty,
    );
    Navigator.of(tester.element(find.byType(BooksPage))).push(
      BookPageRoute<void>(
        builder: (_) =>
            BookDetailPage(services: fixture.services, initial: book),
      ),
    );
    await fixture.waitFor(
      tester,
      () => find.text('开始阅读').evaluate().isNotEmpty,
    );
    await tester.ensureVisible(find.text('开始阅读'));
    await tester.tap(find.text('开始阅读'));
    await fixture.waitFor(
      tester,
      () => find.byType(BookReaderPage).evaluate().isNotEmpty,
    );
    await fixture.settle(tester);
    expect(find.byType(BookReaderPage), findsOneWidget);
    expect(find.byType(NavigationBar).hitTestable(), findsNothing);
    expect(find.byTooltip('渠道管理').hitTestable(), findsNothing);
    final viewport = tester.getRect(find.byType(ReaderViewport));
    expect(viewport, const Rect.fromLTWH(0, 0, 1024, 760));
    await tester.dragFrom(viewport.center, const Offset(-380, 0));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 /'), findsOneWidget);
    await tester.dragFrom(viewport.center, const Offset(380, 0));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 /'), findsOneWidget);
    await tester.dragFrom(const Offset(8, 360), const Offset(240, 0));
    await fixture.settle(tester);
    expect(find.byType(BookDetailPage), findsOneWidget);
    expect(router.state.uri.path, '/reading');
    await _tabletBackOrder(tester);
    await fixture.finish(tester);
  });
}

Future<void> _tabletBackOrder(WidgetTester tester) async {
  await tester.tap(find.text('菜单'));
  await tester.pumpAndSettle();
  expect(find.byType(Drawer).hitTestable(), findsOneWidget);
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
  expect(find.byType(Drawer).hitTestable(), findsNothing);
  expect(find.byType(BookDetailPage), findsOneWidget);
  await tester.dragFrom(const Offset(8, 360), const Offset(240, 0));
  await fixture.waitFor(
    tester,
    () => find.byType(BookDetailPage).evaluate().isEmpty,
  );
  expect(find.byType(BooksPage), findsOneWidget);
  expect(find.byType(Drawer).hitTestable(), findsNothing);
}

void _basicNavigationTests() {
  testWidgets('actual router root back confirms instead of exiting Android', (
    tester,
  ) async {
    await fixture.pump(tester);
    await tester.binding.handlePopRoute();
    await fixture.settle(tester);
    expect(find.text('退出 Zero Player？'), findsOneWidget);
    expect(
      platformCalls.where((call) => call.method == 'SystemNavigator.pop'),
      isEmpty,
    );
    await tester.binding.handlePopRoute();
    await fixture.settle(tester);
    expect(find.text('退出 Zero Player？'), findsNothing);
    expect(
      platformCalls
          .where(
            (call) => call.method == 'SystemNavigator.setFrameworkHandlesBack',
          )
          .last
          .arguments,
      isTrue,
    );
    await fixture.finish(tester);
  });

  testWidgets('phone scroll hides the top bar and keeps bottom navigation', (
    tester,
  ) async {
    await fixture.pump(tester);
    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    router.go('/settings');
    await fixture.settle(tester);
    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.drag(find.byType(ListView).first, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar).hitTestable(), findsOneWidget);
    expect(find.byTooltip('展开导航 (Ctrl+M)').hitTestable(), findsNothing);
    await tester.drag(find.byType(ListView).first, const Offset(0, 140));
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开导航 (Ctrl+M)').hitTestable(), findsOneWidget);
    await fixture.finish(tester);
  });

  testWidgets('phone startup never requests immersive app fullscreen', (
    tester,
  ) async {
    await fixture.pump(tester);
    expect(fixture.fullscreenCalls.where((call) => call.$1), isEmpty);
    expect(find.byType(NavigationBar), findsOneWidget);
    await fixture.finish(tester);
  });
}

Future<void> _settleRoute(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void _stackTests() {
  testWidgets('reading keeps its branch state and both return paths', (
    tester,
  ) async {
    await fixture.pump(tester, size: const Size(320, 740));
    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    router.go('/reading');
    await fixture.waitFor(
      tester,
      () => find.text('书架').hitTestable().evaluate().isNotEmpty,
    );
    await tester.tap(find.text('书架'));
    await _settleRoute(tester);
    final branch = tester.element(find.byType(BooksPage));
    Navigator.of(branch).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('模块详情')),
          body: const Text('阅读详情'),
        ),
      ),
    );
    await _settleRoute(tester);
    await tester.binding.handlePopRoute();
    await _settleRoute(tester);
    expect(router.state.uri.path, '/reading');
    expect(
      tester
          .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
          .selected,
      {1},
    );
    router.go('/settings');
    await _settleRoute(tester);
    router.go('/reading');
    await _settleRoute(tester);
    expect(
      tester
          .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
          .selected,
      {1},
    );
    Navigator.of(tester.element(find.byType(BooksPage))).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(appBar: AppBar(title: const Text('模块详情'))),
      ),
    );
    await _settleRoute(tester);
    await tester.tap(find.byType(BackButton));
    await _settleRoute(tester);
    expect(router.state.uri.path, '/reading');
    expect(tester.takeException(), isNull);
    await fixture.finish(tester);
  });

  testWidgets(
    'system back dismisses dialogs, drawer, pushed pages before root exit',
    (tester) async {
      await fixture.pump(tester);
      final context = tester.element(find.byType(AppShell));
      final router = GoRouter.of(context);
      router.push('/calendar');
      await fixture.settle(tester);
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(title: Text('测试弹窗')),
      );
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await fixture.settle(tester);
      expect(find.text('测试弹窗'), findsNothing);
      expect(router.state.uri.path, '/calendar');
      await tester.binding.handlePopRoute();
      await fixture.settle(tester);
      expect(router.state.uri.path, '/');
      await tester.tap(find.text('更多'));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer).hitTestable(), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(Drawer).hitTestable(), findsNothing);
      expect(find.text('退出 Zero Player？'), findsNothing);
      router.go('/settings');
      await fixture.settle(tester);
      await tester.binding.handlePopRoute();
      await fixture.settle(tester);
      expect(router.state.uri.path, '/settings');
      expect(find.text('退出 Zero Player？'), findsOneWidget);
      await tester.tap(find.text('继续使用'));
      await fixture.settle(tester);
      expect(
        platformCalls.where((call) => call.method == 'SystemNavigator.pop'),
        isEmpty,
      );
      await fixture.finish(tester);
    },
  );
}

void _viewportAndExitTests() {
  testWidgets('phone landscape and stored TV mode keep bottom navigation', (
    tester,
  ) async {
    await tester.runAsync(
      () => fixture.services.settings.update({'mode': 'television'}),
    );
    await fixture.pump(tester, size: const Size(844, 390));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(fixture.fullscreenCalls.where((call) => call.$1), isEmpty);
    await fixture.services.platform.fullscreen(true);
    expect(fixture.fullscreenCalls.last, (false, true));
    await fixture.services.platform.fullscreen(false);
    expect(fixture.fullscreenCalls.last, (false, false));
    expect(find.byType(NavigationBar), findsOneWidget);
    await fixture.finish(tester);
  });

  testWidgets('exit is dispatched only after explicit confirmation', (
    tester,
  ) async {
    await fixture.pump(tester);
    await tester.binding.handlePopRoute();
    await fixture.settle(tester);
    await tester.tap(find.text('继续使用'));
    await tester.pumpAndSettle();
    expect(
      platformCalls.where((call) => call.method == 'SystemNavigator.pop'),
      isEmpty,
    );
    await tester.binding.handlePopRoute();
    await fixture.settle(tester);
    await tester.tap(find.text('退出'));
    await fixture.waitFor(
      tester,
      () => platformCalls.any((call) => call.method == 'SystemNavigator.pop'),
    );
    expect(
      platformCalls.where((call) => call.method == 'SystemNavigator.pop'),
      hasLength(1),
    );
    await fixture.finish(tester);
  });
}
