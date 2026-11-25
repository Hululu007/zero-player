import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/presentation/rich_reader_page.dart';
import 'package:zero_player/features/publications/application/publication_workflow.dart';
import 'package:zero_player/features/publications/data/publication_aozora_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_dushupai_catalogue.dart';
import 'package:zero_player/features/publications/domain/acquisition_task.dart';
import 'package:zero_player/features/publications/domain/publication.dart';
import 'package:zero_player/features/publications/presentation/publications_page.dart';

import '../test_support/local_book_fixtures.dart';
import '../test_support/publication_catalogue_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'aggregate search keeps its active requests when source settings change',
    (tester) => withPublicationCatalogue(
      (fixture) => _withApp(tester, (services) async {
        fixture.holdSearchAt = '/catalogue';
        final field = find.widgetWithText(TextField, '书名、作者或 ISBN');
        await _wait(tester, field);
        await tester.enterText(field, 'Reference');
        await _tap(tester, find.byTooltip('搜索图书'));
        await fixture.pending.future.timeout(const Duration(seconds: 10));

        final discovery = services.publications.discovery;
        await discovery.saveConfig(
          PublicationCatalogueFixture.configuration(
            '/additional',
          ).replaceFirst('"Catalogue"', '"Additional"'),
        );
        final extra = (await discovery.sources())
            .singleWhere((item) => item.source.endpoint.path == '/additional')
            .source;
        await discovery.setEnabled(extra, true);
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        fixture.release();
        await _wait(tester, find.text('Reference catalogue'));
        expect(
          fixture.requests.where(
            (uri) =>
                uri.path == '/catalogue' &&
                uri.queryParameters['page'] == '1' &&
                uri.queryParameters['q'] == 'Reference',
          ),
          hasLength(1),
        );
        expect(
          fixture.requests.where(
            (uri) =>
                uri.path == '/additional' &&
                uri.queryParameters['q'] == 'Reference',
          ),
          isEmpty,
        );

        await _tap(tester, find.byTooltip('图书操作'));
        await _tap(tester, find.text('管理渠道分组'));
        await _tap(tester, find.text('新建分组'));
        await tester.enterText(find.byType(TextField).last, '技术渠道');
        await _tap(tester, find.text('确定'));
        await tester.enterText(
          find.widgetWithText(TextField, '筛选渠道'),
          'Catalogue',
        );
        await _tap(tester, find.widgetWithText(CheckboxListTile, 'Catalogue'));
        await _tap(tester, find.widgetWithText(FilledButton, '保存'));
        await _tap(tester, find.widgetWithText(OutlinedButton, '全部渠道'));
        await _tap(tester, find.widgetWithText(ListTile, '技术渠道'));
        await _wait(tester, find.text('Reference catalogue'));
        expect(
          fixture.requests.where(
            (uri) =>
                uri.path == '/additional' &&
                uri.queryParameters['q'] == 'Reference',
          ),
          isEmpty,
        );
      }),
    ),
  );
  testWidgets(
    'channel search downloads a PDF, opens the reader and keeps shelf state',
    (tester) => withPublicationCatalogue(
      (_) => _withApp(tester, (services) => _verifyFlow(tester, services)),
      respond: _serve,
    ),
    skip: !Platform.isWindows,
  );
  testWidgets(
    'Kindle imports read offline and keep their original bytes',
    (tester) => withPublicationCatalogue(
      (_) => _withApp(
        tester,
        (_) => _verifyKindle(tester),
        prepare: _importKindleSamples,
      ),
      respond: _serve,
    ),
  );
  testWidgets(
    'Dushupai search exposes both published shares in the app',
    (tester) => withPublicationCatalogue(
      (fixture) => _withApp(tester, (_) async {
        await _selectChannel(tester, '读书派 · 公开书目');
        final field = find.widgetWithText(TextField, '书名、作者或 ISBN');
        await tester.enterText(field, '示例');
        await _tap(tester, find.byTooltip('搜索图书'));
        await _wait(tester, find.text('示例书'));
        expect(
          fixture.requests.any((uri) => uri.path.startsWith('/download-')),
          isFalse,
        );
        await _tap(tester, find.text('查看下载入口'));
        await _wait(tester, find.text('打开城通网盘'));
        await _wait(tester, find.text('打开迅雷网盘'));
        expect(
          fixture.requests.where(
            (uri) => uri.path == '/download-book-30981.html',
          ),
          hasLength(1),
        );
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        await tester.pumpAndSettle();
        expect(find.text('示例书'), findsOneWidget);
      }, builtin: dushupaiSource),
      host: dushupaiCatalogueEndpoint.host,
      respond: _serveDushupai,
    ),
  );
  testWidgets(
    'website task opens manual account fields and resumes the same download',
    (tester) => withPublicationCatalogue(
      (_) => _withApp(
        tester,
        (services) => _verifyWebsite(tester, services),
        prepare: _seedWebsiteTask,
        configuration: jsonEncode({
          'version': 2,
          'kind': 'jsonSearch',
          'name': 'Website fixture',
          'endpoint': 'https://catalogue.fixture.example/catalogue',
          'field': {'title': 'title', 'mobi': 'link'},
        }),
      ),
      respond: _serveWebsite,
    ),
  );
  testWidgets(
    'Panda directory opens a channel and searches by its title field',
    (tester) => withPublicationCatalogue(
      (_) => _withApp(tester, (_) async {
        await _tap(tester, find.text('熊猫书源'));
        final directorySearch = find.widgetWithText(TextField, '搜索站名或域名');
        await _wait(tester, directorySearch);
        await tester.enterText(directorySearch, 'aozora.gr.jp');
        await tester.pump();
        await _tap(tester, find.text('青空文库'));
        await _tap(tester, find.byType(DropdownButton<PublicationSearchField>));
        await _tap(tester, find.text('书名').hitTestable().last);
        final title = find.widgetWithText(TextField, '输入书名');
        await tester.enterText(title, '吾輩は猫である');
        await _tap(tester, find.byTooltip('搜索图书'));
        await _wait(tester, find.text('吾輩は猫である').first);
      }, builtin: aozoraPublicationSource),
      respond: _serve,
    ),
  );
}

Future<void> _seedWebsiteTask(AppServices services) async {
  final module = services.publications;
  final source = (await module.discovery.sources())
      .singleWhere((row) => row.source.configurable && row.enabled)
      .source;
  final book = PublicationEdition(
    id: publicationId('gated-website-fixture'),
    title: 'Reference gated',
    candidates: [
      AcquisitionCandidate(
        source: source.id,
        link: source.endpoint.resolve('/site-book.mobi'),
        format: PublicationFormat.mobi,
      ),
    ],
  );
  await module.store.addTask(
    book,
    book.candidates,
    preflightFailure: const PublicationFailure(PublicationProblem.guestLimit),
  );
}

Future<void> _verifyWebsite(WidgetTester tester, AppServices services) async {
  final module = services.publications;
  final original = (await module.store.tasks()).single;
  await _tap(tester, find.text('书源'));
  await _tap(tester, find.text('网站账号管理'));
  await _wait(tester, find.text('网站账号'));
  await _tap(tester, find.text('完成'));
  await _tap(tester, find.text('任务'));
  await _tap(tester, find.text('网站操作'));
  await _tap(tester, find.text('管理账号'));
  await _tap(tester, find.text('添加账号'));
  await tester.enterText(find.byType(TextField).last, '测试账号');
  await _tap(tester, find.text('确定'));
  await _wait(tester, find.text('测试账号'));
  await _tap(tester, find.text('完成'));
  await _tap(tester, find.text('临时会话'));
  await _tap(tester, find.text('测试账号').hitTestable().last);
  await _tap(tester, find.text('验证码登录'));
  await tester.enterText(find.widgetWithText(TextFormField, '登录账号'), 'reader');
  await tester.enterText(
    find.widgetWithText(TextFormField, '登录密码'),
    'fixture-password',
  );
  await tester.enterText(find.widgetWithText(TextFormField, '验证码'), '4826');
  await _tap(tester, find.text('提交到网站'));
  await _wait(tester, find.text('网站登录完成'));
  await _tap(tester, find.text('下载 MOBI'));
  await _wait(tester, find.text('Reference gated').hitTestable());
  final task = (await module.store.tasks()).single;
  expect(task.id, original.id);
  expect(
    const {
      AcquisitionState.downloaded,
      AcquisitionState.importing,
      AcquisitionState.complete,
    }.contains(task.state),
    isTrue,
  );
}

Future<void> _serveWebsite(HttpRequest request) async {
  final response = request.response;
  switch (request.uri.path) {
    case '/site-book.mobi':
      if (request.cookies.any((cookie) => cookie.name == 'test_website')) {
        final bytes = sampleKindle();
        response.headers.contentType = ContentType(
          'application',
          'x-mobipocket-ebook',
        );
        response.contentLength = bytes.length;
        response.add(bytes);
      } else {
        response.headers.contentType = ContentType.html;
        response.statusCode = HttpStatus.forbidden;
        response.write('''
          <h1>游客下载次数已达上限</h1>
          <form method="post" action="/site-login">
            <label for="u">登录账号</label><input id="u" name="username" required>
            <label for="p">登录密码</label><input id="p" name="password" type="password">
            <label for="c">验证码</label><input id="c" name="captcha">
            <button>验证码登录</button>
          </form>''');
      }
    case '/site-login':
      final body = await utf8.decoder.bind(request).join();
      final values = Uri.splitQueryString(body);
      if (request.method == 'POST' &&
          values['username'] == 'reader' &&
          values['password'] == 'fixture-password' &&
          values['captcha'] == '4826') {
        response.cookies.add(Cookie('test_website', 'accepted')..path = '/');
        response.statusCode = HttpStatus.seeOther;
        response.headers.set(HttpHeaders.locationHeader, '/site-ready');
      } else {
        response.statusCode = HttpStatus.unauthorized;
      }
    case '/site-ready':
      response.headers.contentType = ContentType.html;
      response.write('<h1>网站登录完成</h1>');
    default:
      return _serve(request);
  }
  await response.close();
}

Future<void> _importKindleSamples(AppServices services) async {
  final module = services.publications;
  final workspace = module.space.directory.parent;
  final mobi = sampleKindle();
  final sources = [
    ('example.mobi', mobi),
    ('same.azw', mobi),
    ('example.azw3', sampleKindle(kf8: true)),
  ];
  for (final (name, bytes) in sources) {
    final file = await File('${workspace.path}/$name').writeAsBytes(bytes);
    await module.workflow.importDocument(
      PublicationLocalDocument.external(file),
    );
  }
  final holdings = await module.library.holdings();
  expect(
    holdings.map((item) => item.format),
    unorderedEquals([PublicationFormat.mobi, PublicationFormat.azw3]),
  );
  for (final holding in holdings) {
    expect(
      await module.space
          .managedFile(holding.digest, holding.format)
          .readAsBytes(),
      holding.format == PublicationFormat.mobi ? mobi : sources.last.$2,
    );
  }
}

Future<void> _verifyKindle(WidgetTester tester) async {
  await _tap(tester, find.text('书库'));
  await _tap(tester, find.textContaining('MOBI ·'));
  await _wait(tester, find.byType(RichReaderPage));
  await _wait(tester, find.textContaining('电子书格式测试正文', findRichText: true));
  tester.state<NavigatorState>(find.byType(Navigator).first).pop();
  await tester.pumpAndSettle();
  await _tap(tester, find.textContaining('AZW3 ·'));
  await _wait(tester, find.byType(RichReaderPage));
  await _wait(tester, find.textContaining('电子书格式测试正文', findRichText: true));
  tester.state<NavigatorState>(find.byType(Navigator).first).pop();
  await tester.pumpAndSettle();
}

Future<void> _selectChannel(WidgetTester tester, String name) async {
  await _tap(tester, find.text('选择渠道'));
  await tester.enterText(find.widgetWithText(TextField, '搜索渠道、分组或域名'), name);
  await _tap(tester, find.widgetWithText(ListTile, name));
}

Future<void> _verifyFlow(WidgetTester tester, AppServices services) async {
  await _selectChannel(tester, 'Catalogue');
  final field = find.widgetWithText(TextField, '书名、作者或 ISBN');
  await tester.enterText(field, 'Reference');
  await _tap(tester, find.byTooltip('搜索图书'));
  await _tap(tester, find.text('下载 PDF'));
  await _tap(tester, find.text('查看任务'));
  await _tap(tester, find.text('打开图书'));
  await _wait(tester, find.byType(RichReaderPage));
  await _wait(tester, find.text('1 / 2'));
  await _tap(tester, find.byTooltip('下一页').last);
  await _wait(tester, find.text('2 / 2'));
  tester.state<NavigatorState>(find.byType(Navigator).first).pop();
  await tester.pumpAndSettle();

  await _tap(tester, find.text('书库'));
  await _tap(tester, find.text('管理分组'));
  await _tap(tester, find.text('新建分组'));
  await tester.enterText(find.byType(TextField).last, '技术');
  await _tap(tester, find.text('确定'));
  await _tap(tester, find.byTooltip('图书操作'));
  await _tap(tester, find.text('移动到分组'));
  await _tap(tester, find.text('技术'));
  await _tap(tester, find.byTooltip('图书操作'));
  await _tap(tester, find.text('标记已读完'));
  await _wait(tester, find.textContaining('已读完'));
  final holding = (await services.publications.library.holdings()).single;
  expect(
    holding.groupId,
    (await services.publications.collections.groups()).single.id,
  );
  expect(holding.finished, isTrue);
  expect(holding.lastRead, greaterThan(0));

  await _tap(tester, find.text('发现'));
  await _tap(tester, find.text('阅读 PDF'));
  await _wait(tester, find.byType(RichReaderPage));
  await _wait(tester, find.text('2 / 2'));
  expect(await services.publications.store.tasks(), hasLength(1));
  tester.state<NavigatorState>(find.byType(Navigator).first).pop();
  await tester.pumpAndSettle();

  await _tap(tester, find.text('加入书单'));
  await tester.enterText(find.byType(TextField).last, '技术书单');
  await _tap(tester, find.text('确定'));
  await _tap(tester, find.text('书库'));
  await _tap(tester, find.text('我的书单'));
  await _tap(tester, find.text('技术书单'));
  await _tap(tester, find.byTooltip('查找可下载版本'));
  await _wait(tester, find.text('阅读 PDF'));
}

Future<void> _withApp(
  WidgetTester tester,
  Future<void> Function(AppServices) check, {
  Future<void> Function(AppServices)? prepare,
  String? builtin,
  String? configuration,
}) async {
  final root = await Directory.systemTemp.createTemp('zero-discovery-');
  final services = AppServices.scoped(root, AppDatabase.memory());
  try {
    await services.supervision.load();
    await services.settings.load();
    final discovery = services.publications.discovery;
    await discovery.setEnabledBatch(
      (await discovery.sources())
          .where((row) => row.enabled)
          .map((row) => row.source),
      false,
    );
    if (builtin == null) {
      await discovery.saveConfig(
        configuration ??
            PublicationCatalogueFixture.configuration('/catalogue'),
      );
    }
    final source = (await discovery.sources())
        .singleWhere(
          (row) => builtin == null
              ? row.source.configurable
              : row.source.id == builtin,
        )
        .source;
    await discovery.setEnabled(source, true);
    await discovery.check(source);
    await prepare?.call(services);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PublicationsPage(
            module: services.publications,
            books: services.books,
            platform: services.platform,
          ),
        ),
      ),
    );
    await check(services);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await services.close();
    await root.delete(recursive: true);
  }
}

Future<void> _serveDushupai(HttpRequest request) async {
  final response = request.response;
  response.write(switch (request.uri.path) {
    '/book-content-30981.html' =>
      '<div class="post-download"><a href="/download-book-30981.html">下载</a></div>',
    '/download-book-30981.html' =>
      '''
      <div class="block-download">
        <div id="download_declaration"><h1><a href="/book-content-30981.html">示例书</a></h1></div>
        <div class="download_blcok"><div class="list">
          <div class="box"><div class="button">
            <a href="https://url89.ctfile.com/f/123-456-aabbcc?pwd=1234">下载</a>
          </div></div>
          <div class="box"><div class="button">
            <a href="https://pan.xunlei.com/s/sample?pwd=ab12">下载</a>
          </div></div>
        </div></div>
      </div>''',
    _ =>
      '''
      <ul class="portfolio-book"><li class="portfolio-item">
        <div class="portfolio-title"><a href="/book-content-30981.html">示例书</a></div>
      </li></ul>''',
  });
  await response.close();
}

Future<void> _serve(HttpRequest request) async {
  final response = request.response;
  if (request.uri.path == '/book.pdf') {
    final bytes = samplePdf();
    response.headers.contentType = ContentType('application', 'pdf');
    response.contentLength = bytes.length;
    response.add(bytes);
  } else {
    response.headers.contentType = ContentType.json;
    response.write(
      jsonEncode([
        if (request.uri.queryParameters['page'] == '1')
          {'title': 'Reference manual', 'link': '/book.pdf'},
      ]),
    );
  }
  await response.close();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.pump();
  await _wait(tester, finder.hitTestable());
  await tester.tap(finder.hitTestable());
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _wait(WidgetTester tester, Finder finder) async {
  final deadline = Stopwatch()..start();
  while (finder.evaluate().isEmpty &&
      deadline.elapsed < const Duration(seconds: 20)) {
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
  expect(finder, findsOneWidget);
}
