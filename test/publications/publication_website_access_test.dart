import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/publications/data/publication_kgbook_rows.dart';
import 'package:zero_player/features/publications/data/publication_website_markup.dart';
import 'package:zero_player/features/publications/data/publication_website_target.dart';
import 'package:zero_player/features/publications/domain/acquisition_task.dart';
import 'package:zero_player/features/publications/domain/publication.dart';

import '../../test_support/local_book_fixtures.dart';
import '../../test_support/publication_catalogue_fixture.dart';

final _origin = Uri.https('catalogue.fixture.example', '/');
const _form = '''
<h1>站点验证</h1>
<form method="post" action="/signin">
  <input type="hidden" name="nonce" value="fixture-state">
  <label for="user">站点账号</label><input id="user" name="username" required>
  <label for="pass">站点密码</label><input id="pass" name="password" type="password">
  <label for="code">验证码</label><input id="code" name="captcha">
  <img src="/captcha.png" alt="验证码">
  <button name="operation" value="login">登录验证</button>
</form>
<a href="/register">注册账号</a>
''';
const _entered = {
  'username': 'test-reader',
  'password': 'test-password',
  'captcha': '2468',
};
final _captcha = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aRu8AAAAASUVORK5CYII=',
);

final class _RealHttp extends HttpOverrides {}

Future<T> _withSite<T>(
  Future<T> Function(PublicationCatalogueFixture) run, {
  required String host,
  required Future<void> Function(HttpRequest) respond,
}) => HttpOverrides.runZoned(
  () => withPublicationCatalogue(run, host: host, respond: respond),
  createHttpClient: _RealHttp().createHttpClient,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'website parser exposes trusted native controls and scoped destinations',
    () {
      final page = parsePublicationWebsitePage(
        '''
      <base href="https://elsewhere.example/">
      <meta http-equiv="refresh" content="0;url=https://elsewhere.example/">
      <script>window.testOnly = true</script>
      <iframe src="https://elsewhere.example/frame"></iframe>
      <h1>游客下载已达上限</h1>
      <a href="/download/sample.pdf">PDF 下载</a>
      <a href="https://elsewhere.example/download">网站下载</a>
      <a href="file:///tmp/sample.pdf">本地下载</a>
      <a href="https://catalogue.fixture.example:444/download">其他端口</a>
      <a href="https://account@catalogue.fixture.example/download">账密网址</a>
      <form method="POST" action="//elsewhere.example/login">
        <input type="password" name="secret"><button>登录</button>
      </form>
      <form method="POST" action="/login">
        <input name="secret" type="password">
        <button formaction="https://elsewhere.example/login">登录</button>
      </form>
      <form method="POST" action="/register">
        <input type="file" name="upload"><button>注册</button>
      </form>
      $_form
    ''',
        _origin,
        (uri) => publicationSameWebsite(_origin, uri),
      );
      expect(page.guestLimited, isTrue);
      expect(page.links.map((link) => link.uri), [
        _origin.resolve('download/sample.pdf'),
        _origin.resolve('register'),
      ]);
      final form = page.forms.single;
      expect(form.label, '登录验证');
      expect(form.fields.map((field) => field.kind), [
        PublicationWebsiteFieldKind.text,
        PublicationWebsiteFieldKind.password,
        PublicationWebsiteFieldKind.code,
      ]);
      expect(
        form.encode({..._entered, 'nonce': 'ignored', 'other': 'ignored'}),
        {..._entered, 'nonce': 'fixture-state', 'operation': 'login'},
      );
    },
  );

  test(
    'optional login, authentication and ordinary rate limits do not offer site login',
    () async {
      final cases = [
        (
          HttpStatus.ok,
          'If the guest download quota is exceeded, sign in.',
          PublicationProblem.invalid,
        ),
        (HttpStatus.unauthorized, '请登录', PublicationProblem.login),
        (HttpStatus.forbidden, '请验证', PublicationProblem.challenge),
        (HttpStatus.tooManyRequests, '请稍后重试', PublicationProblem.rateLimit),
        (
          HttpStatus.tooManyRequests,
          'Guest download quota exceeded',
          PublicationProblem.guestLimit,
        ),
      ];
      await _withSite(
        (_) => _withServices((services) async {
          final module = services.publications;
          final source = (await module.discovery.sources())
              .singleWhere((row) => row.source.configurable)
              .source;
          for (final (index, scenario) in cases.indexed) {
            final book = PublicationEdition(
              id: publicationId('site-case-$index'),
              title: 'Reference $index',
              candidates: [
                AcquisitionCandidate(
                  source: source.id,
                  link: _origin.resolve('/case-$index.pdf'),
                  format: PublicationFormat.pdf,
                ),
              ],
            );
            final id = await module.workflow.add(book, PublicationFormat.pdf);
            final task = await _waitFailed(module.store.task, id);
            expect(task.problem, scenario.$3);
            expect(
              PublicationWebsiteTarget.forTask(source, task) != null,
              scenario.$3 == PublicationProblem.guestLimit,
            );
            if (scenario.$1 == HttpStatus.tooManyRequests) {
              expect(task.retryAt?.isAfter(DateTime.now()), isTrue);
            }
          }
        }),
        host: _origin.host,
        respond: (request) async {
          expect(request.method, 'GET');
          final index = int.parse(
            request.uri.path.split('-').last.split('.').first,
          );
          final (status, message, _) = cases[index];
          request.response.statusCode = status;
          if (status == HttpStatus.tooManyRequests) {
            request.response.headers.set('retry-after', '60');
          }
          _html(request.response, '<h1>$message</h1>$_form');
          await request.response.close();
        },
      );
    },
  );

  test(
    'explicit guest refusal enables login for the same task and isolates accounts',
    () async {
      final methods = <(String, String)>[];
      var submits = 0;
      var authorizedFiles = 0;
      await _withSite(
        (fixture) => _withServices((services) async {
          final module = services.publications;
          final book =
              (await module.discovery
                      .search(
                        'Reference',
                        CancellationToken(),
                        sourceId: (await module.discovery.sources())
                            .singleWhere((row) => row.source.configurable)
                            .source
                            .id,
                        maxPages: 1,
                      )
                      .last)
                  .editions
                  .single;
          final source = (await module.discovery.enabledSource(
            book.candidates.single.source,
          ))!;
          final taskId = await module.workflow.add(book, PublicationFormat.pdf);
          final task = await _waitFailed(module.store.task, taskId);
          expect(task.problem, PublicationProblem.guestLimit);
          final target = PublicationWebsiteTarget.forTask(source, task)!;
          expect(target.address.path, '/details');
          await module.websites.addAccount(target, '阅读账号');
          await module.websites.addAccount(target, '备用账号');
          final accounts = await module.websites.accounts(target);
          final reader = accounts.singleWhere((row) => row.name == '阅读账号');
          final alternate = accounts.singleWhere((row) => row.name == '备用账号');
          final account = await module.websites.open(
            target,
            account: reader.id,
          );
          final page = await account.open();
          expect(page.uri.path, '/book.pdf');
          expect(page.links.single.label, '注册账号');
          final registration = await account.follow(page.links.single);
          expect(registration.forms.single.label, '注册');
          final signin = await account.open();
          expect(await account.captcha(signin.forms.single), _captcha);
          expect(submits, 0);
          final ready = await account.submit(signin.forms.single, _entered);
          expect(ready.uri.path, '/book.pdf');
          expect(ready.file, PublicationFormat.pdf);
          expect(submits, 1);
          expect(module.websites.hasSession(reader.id), isTrue);
          expect(module.websites.hasSession(alternate.id), isFalse);
          final other = await module.websites.open(
            target,
            account: alternate.id,
          );
          expect((await other.open()).forms, hasLength(1));
          other.close();
          final guest = await module.websites.open(target);
          expect((await guest.open()).forms, hasLength(1));
          guest.close();

          expect(await module.workflow.downloadFromWebsite(account), taskId);
          expect(authorizedFiles, 1);
          final completed = (await module.store.task(taskId))!;
          expect(completed.state, AcquisitionState.downloaded);
          expect(PublicationWebsiteTarget.forTask(source, completed), isNull);
          expect(
            await module.workflow.transfer.part(taskId).readAsBytes(),
            samplePdf(),
          );
          expect((await module.store.tasks()).map((task) => task.id), [taskId]);

          module.websites.clearAccount(reader.id);
          expect(account.lifetime.isCancelled, isTrue);
          expect(module.websites.hasSession(reader.id), isFalse);
          await module.websites.renameAccount(reader, '常用账号');
          expect(
            (await module.websites.accounts(target)).map((item) => item.name),
            contains('常用账号'),
          );

          await module.discovery.setEnabled(source, false);
          await expectLater(
            module.websites.open(target, account: reader.id),
            throwsA(isA<PublicationFailure>()),
          );
          await module.websites.removeAccount(reader);
          final rows = await module.store.db.rows(
            'SELECT * FROM publication_website_accounts',
          );
          expect(
            rows.single.keys,
            unorderedEquals(['id', 'source', 'origin', 'name']),
          );
          expect(
            fixture.requests.every((uri) => uri.host == _origin.host),
            isTrue,
          );

          final cloud = await module.discovery.enabledSource(source.id);
          expect(cloud, isNull);
          final cloudTask = AcquisitionTask(
            id: taskId,
            edition: task.edition,
            candidates: [
              AcquisitionCandidate(
                source: source.id,
                link: Uri.https('pan.quark.cn', '/s/sample'),
                format: PublicationFormat.pdf,
              ),
            ],
            state: AcquisitionState.failed,
            problem: PublicationProblem.guestLimit,
          );
          expect(PublicationWebsiteTarget.forTask(source, cloudTask), isNull);
        }),
        host: _origin.host,
        respond: (request) async {
          methods.add((request.method, request.uri.path));
          switch (request.uri.path) {
            case '/catalogue':
              _catalogue(request.response);
            case '/book.pdf':
              if (request.cookies.any(
                (cookie) => cookie.name == 'local_session',
              )) {
                authorizedFiles++;
                final bytes = samplePdf();
                request.response.headers.contentType = ContentType(
                  'application',
                  'pdf',
                );
                request.response.contentLength = bytes.length;
                request.response.add(bytes);
              } else {
                request.response.statusCode = HttpStatus.forbidden;
                _html(request.response, '<p>游客下载次数已达上限</p>$_form');
              }
            case '/register':
              _html(request.response, '''
              <form method="post" action="/register">
                <input name="email" type="email">
                <input name="password" type="password">
                <button>注册</button>
              </form>''');
            case '/captcha.png':
              request.response.headers.contentType = ContentType(
                'image',
                'png',
              );
              request.response.add(_captcha);
            case '/signin':
              submits++;
              expect(request.method, 'POST');
              expect(request.headers.value('origin'), _origin.origin);
              expect(request.headers.value('x-requested-with'), isNull);
              final values = Uri.splitQueryString(
                await utf8.decoder.bind(request).join(),
              );
              expect(values, {
                ..._entered,
                'nonce': 'fixture-state',
                'operation': 'login',
              });
              request.response.cookies.add(
                Cookie('local_session', 'authorized')..path = '/',
              );
              request.response.statusCode = HttpStatus.seeOther;
              request.response.headers.set(
                HttpHeaders.locationHeader,
                '/book.pdf',
              );
            default:
              request.response.statusCode = HttpStatus.notFound;
          }
          await request.response.close();
        },
      );
      expect(methods.where((entry) => entry.$1 == 'POST'), [
        ('POST', '/signin'),
      ]);
    },
  );

  test(
    'Kgbook public file uses the anonymous task even with a login form on the detail page',
    () async {
      final filePath = '/d/file/201708/${Uri.encodeComponent('斯通纳.azw3')}';
      await _withSite(
        (fixture) => _withServices((services) async {
          final module = services.publications;
          final source = (await module.discovery.enabledSource(kgbookSource))!;
          final book = kgbookEdition(
            '/renwuchuanji/1298.html',
            '斯通纳',
            '',
            'azw3',
          )!;
          final formats = await module.workflow.loadCatalogueResources(
            book,
            book.resources.single,
            CancellationToken(),
          );
          expect(formats.map((item) => item.format), [
            PublicationFormat.azw3,
            PublicationFormat.mobi,
            PublicationFormat.epub,
          ]);
          final id = await module.workflow.add(book, PublicationFormat.azw3);
          final task = await _waitState(
            module.store.task,
            id,
            AcquisitionState.downloaded,
          );
          expect(task.state, AcquisitionState.downloaded);
          expect(task.candidate.link, book.page);
          expect(PublicationWebsiteTarget.forTask(source, task), isNull);
          expect(
            await module.workflow.transfer.part(id).readAsBytes(),
            sampleKindle(kf8: true),
          );
          expect(fixture.requests.map((uri) => uri.path), [
            '/renwuchuanji/1298.html',
            '/e/DownSys/GetDown',
            filePath,
          ]);
        }, configure: false),
        host: 'kgbook.com',
        respond: (request) async {
          switch (request.uri.path) {
            case '/renwuchuanji/1298.html':
              request.response.headers.set(
                'cache-control',
                'public, max-age=60',
              );
              _html(
                request.response,
                '$_form'
                '<a href="/e/DownSys/GetDown?classid=8&amp;id=1298&amp;pathid=0">azw3格式</a>'
                '<a href="/e/DownSys/GetDown?classid=8&amp;id=1298&amp;pathid=1">mobi格式</a>'
                '<a href="/e/DownSys/GetDown?classid=8&amp;id=1298&amp;pathid=2">epub格式</a>'
                '<a href="/e/DownSys/GetDown?classid=8&amp;id=1234&amp;pathid=0">PDF</a>'
                '<a href="https://example.com/d/file/book.pdf">PDF</a>',
              );
            case '/e/DownSys/GetDown':
              expect(request.method, 'GET');
              expect(request.cookies, isEmpty);
              expect(request.headers.value(HttpHeaders.rangeHeader), isNull);
              expect(request.uri.queryParameters['pathid'], '0');
              expect(
                request.headers.value(HttpHeaders.refererHeader),
                'https://kgbook.com/renwuchuanji/1298.html',
              );
              request.response.statusCode = HttpStatus.found;
              request.response.headers.set(
                HttpHeaders.locationHeader,
                '/d/file/201708/${Uri.encodeComponent(latin1.decode(utf8.encode('斯通纳.azw3')))}',
              );
            case final path when path == filePath:
              expect(request.headers.value(HttpHeaders.rangeHeader), isNull);
              request.response.headers.contentType = ContentType(
                'application',
                'octet-stream',
              );
              request.response.headers.set(
                'content-disposition',
                'attachment; filename=fixture.azw3',
              );
              request.response.add(sampleKindle(kf8: true));
            default:
              fail('Unexpected site request ${request.uri}');
          }
          await request.response.close();
        },
      );
    },
  );

  test(
    'website credentials stop at a cross-origin or form-replay redirect',
    () async {
      for (final status in [
        HttpStatus.seeOther,
        HttpStatus.temporaryRedirect,
      ]) {
        await _withSite(
          (fixture) => _withServices((services) async {
            final module = services.publications;
            final source = (await module.discovery.sources())
                .singleWhere((row) => row.source.configurable)
                .source;
            final book = PublicationEdition(
              id: publicationId('manual-website-fixture'),
              title: 'Reference PDF',
              candidates: [
                AcquisitionCandidate(
                  source: source.id,
                  link: _origin.resolve('book.pdf'),
                  format: PublicationFormat.pdf,
                ),
              ],
            );
            final id = await module.store.addTask(
              book,
              book.candidates,
              preflightFailure: const PublicationFailure(
                PublicationProblem.guestLimit,
              ),
            );
            final target = PublicationWebsiteTarget.forTask(
              source,
              (await module.store.task(id))!,
            )!;
            final session = await module.websites.open(target);
            final page = await session.open();
            await expectLater(
              session.submit(page.forms.single, _entered),
              throwsA(
                isA<PublicationFailure>().having(
                  (e) => e.problem,
                  'problem',
                  PublicationProblem.unsupported,
                ),
              ),
            );
            expect(fixture.requests.map((uri) => uri.path), [
              '/book.pdf',
              '/signin',
            ]);
          }),
          host: _origin.host,
          respond: (request) async {
            if (request.uri.path == '/book.pdf') {
              _html(request.response, _form);
            } else {
              await request.drain<void>();
              request.response.statusCode = status;
              request.response.headers.set(
                HttpHeaders.locationHeader,
                status == HttpStatus.seeOther
                    ? 'https://different.example/form'
                    : '/replay',
              );
            }
            await request.response.close();
          },
        );
      }
    },
  );
}

Future<AcquisitionTask> _waitFailed(
  Future<AcquisitionTask?> Function(String) read,
  String id,
) => _waitState(read, id, AcquisitionState.failed);

Future<AcquisitionTask> _waitState(
  Future<AcquisitionTask?> Function(String) read,
  String id,
  AcquisitionState state,
) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < const Duration(seconds: 12)) {
    final task = await read(id);
    if (task?.state == state) return task!;
    if (task?.state == AcquisitionState.failed) {
      fail('Unexpected failure ${task?.problem}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('Expected the direct attempt to finish as ${state.name}');
}

Future<void> _withServices(
  Future<void> Function(AppServices) run, {
  bool configure = true,
}) async {
  final root = await Directory.systemTemp.createTemp('zero-website-');
  final services = AppServices.scoped(root, AppDatabase.memory());
  try {
    await services.supervision.load();
    await services.settings.load();
    if (!configure) {
      await run(services);
      return;
    }
    final discovery = services.publications.discovery;
    await discovery.saveConfig(
      jsonEncode({
        'version': 1,
        'kind': 'jsonSearch',
        'name': 'Website fixture',
        'endpoint': _origin.resolve('catalogue').toString(),
        'field': {'title': 'title', 'page': 'page', 'pdf': 'file'},
      }),
    );
    final source = (await discovery.sources())
        .singleWhere((row) => row.source.configurable)
        .source;
    await discovery.setEnabled(source, true);
    await run(services);
  } finally {
    await services.close();
    await root.delete(recursive: true);
  }
}

void _catalogue(HttpResponse response) {
  response.headers.contentType = ContentType.json;
  response.write(
    jsonEncode([
      {'title': 'Reference PDF', 'page': '/details', 'file': '/book.pdf'},
    ]),
  );
}

void _html(HttpResponse response, String body) {
  response.headers.contentType = ContentType.html;
  response.write(body);
}
