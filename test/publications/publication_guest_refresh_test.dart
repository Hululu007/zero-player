import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/publications/application/publication_acquisitions.dart';
import 'package:zero_player/features/publications/application/publication_discovery.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/data/publication_share.dart';
import 'package:zero_player/features/publications/data/publication_sources.dart';
import 'package:zero_player/features/publications/data/publication_space.dart';
import 'package:zero_player/features/publications/data/publication_store.dart';
import 'package:zero_player/features/publications/data/publication_transfer.dart';
import 'package:zero_player/features/publications/domain/acquisition_task.dart';
import 'package:zero_player/features/publications/domain/publication.dart';

import '../../test_support/local_book_fixtures.dart';

const _cdn = 'dl-guest-fixture.drive.quark.cn';
const _sliceBytes = PublicationTransfer.sliceBytes;
const _firstSlice = 'bytes=0-${_sliceBytes - 1}';
const _secondSlice = 'bytes=$_sliceBytes-${2 * _sliceBytes - 1}';
const _lastSlice = 'bytes=${2 * _sliceBytes}-${(9 << 20) - 1}';

void main() {
  test(
    'confirmed fallback uses its own published code rather than a supplied code for another link',
    _verifyCodeBoundary,
  );
  test(
    'Quark distinguishes incorrect or missing codes from expired shares',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final originalClient = HttpClient()..findProxy = (_) => 'DIRECT';
      final responses = [
        (41008, '需要提取码', PublicationProblem.shareCode),
        (41007, '提取码错误', PublicationProblem.shareCode),
        (41010, '分享已失效', PublicationProblem.missing),
      ];
      var call = 0;
      server.listen((request) async {
        await request.drain<void>();
        final (code, message, _) = responses[call++];
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'status': 404,
            'code': code,
            'message': message,
            'data': {'file_num': 1},
          }),
        );
        await request.response.close();
      });
      await HttpOverrides.runZoned(() async {
        final network = MediaHttpClient();
        addTearDown(network.close);
        final resolver = PublicationShareResolver(
          PublicationHttp(network, authorize: (_) {}),
        );
        for (final (index, (_, _, problem)) in responses.indexed) {
          await expectLater(
            resolver.inspect(
              Uri.https('pan.quark.cn', '/s/fixture-share'),
              index == 1 ? 'wrong' : null,
              CancellationToken(),
            ),
            throwsA(
              isA<PublicationFailure>().having(
                (error) => error.problem,
                'problem',
                problem,
              ),
            ),
          );
        }
      }, createHttpClient: (_) => _LocalClient(originalClient, server.port));
      expect(call, responses.length);
    },
  );

  test(
    'concurrent guest expiry refreshes once and replaces stale ranges',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final originalClient = HttpClient()..findProxy = (_) => 'DIRECT';
      final fixture = _GuestFixture();
      server.listen((request) => unawaited(fixture.serve(request)));

      await HttpOverrides.runZoned(
        () => _verifyRefresh(fixture),
        createHttpClient: (_) => _LocalClient(originalClient, server.port),
      );
    },
  );
}

Future<void> _verifyCodeBoundary() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  final originalClient = HttpClient()..findProxy = (_) => 'DIRECT';
  addTearDown(() => originalClient.close(force: true));
  final observed = <(String, String)>[];
  server.listen((request) async {
    final data = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
    observed.add((data['pwd_id'] as String, data['passcode'] as String));
    final response = request.response..headers.contentType = ContentType.json;
    response.write(jsonEncode({'status': 401, 'code': 31001}));
    await response.close();
  });
  await HttpOverrides.runZoned(() async {
    final root = await Directory.systemTemp.createTemp(
      'publication-code-scope-',
    );
    addTearDown(() => root.delete(recursive: true));
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final network = MediaHttpClient();
    addTearDown(network.close);
    final store = PublicationStore(db);
    final http = PublicationHttp(network, authorize: (_) {});
    final discovery = PublicationDiscovery(store, http, (_) => true);
    addTearDown(discovery.close);
    await discovery.saveConfig(
      jsonEncode({
        'version': 1,
        'kind': 'snapshot',
        'name': 'Fixture Catalogue',
        'endpoint': 'https://catalog.example/books',
        'hosts': ['pan.quark.cn'],
        'field': {'title': 'title', 'pdf': 'pdf'},
      }),
    );
    final source = (await discovery.sources())
        .singleWhere((item) => item.source.configurable)
        .source;
    await discovery.setEnabled(source, true);
    final books = configuredPublicationRows(
      source,
      jsonEncode([
        {'title': 'Sample', 'pdf': 'https://pan.quark.cn/s/first?pwd=AAAA'},
        {'title': 'Sample', 'pdf': 'https://pan.quark.cn/s/second?pwd=BBBB'},
      ]),
    );
    final candidates = [
      for (final (index, book) in books.indexed)
        book.candidates.single.withSharedFile((
          name: 'Sample.pdf',
          id: '0:document-$index',
          format: PublicationFormat.pdf,
          bytes: 300,
        )),
    ];
    final id = await store.addTask(books.first, candidates);
    final done = Completer<void>();
    late final PublicationAcquisitions runner;
    runner = PublicationAcquisitions(
      store,
      discovery,
      PublicationShareResolver(http),
      PublicationTransfer(http, PublicationSpace(store, root)),
      (_) {},
      activity: () {
        if (!runner.busy && !done.isCompleted) done.complete();
      },
    );
    addTearDown(runner.close);
    runner.start(id, code: 'manual', codeFor: candidates.first.id);
    await done.future.timeout(const Duration(seconds: 10));
    expect(observed, [('first', 'manual'), ('second', 'BBBB')]);
    final task = (await store.task(id))!;
    expect(task.failures.map((item) => item.problem), [
      PublicationProblem.login,
      PublicationProblem.login,
    ]);
    final saved = (await db.rows(
      'SELECT candidates FROM publication_tasks WHERE id=?',
      [id],
    )).single;
    expect(
      saved['candidates'],
      allOf(contains('AAAA'), contains('BBBB'), isNot(contains('manual'))),
    );
  }, createHttpClient: (_) => _LocalClient(originalClient, server.port));
}

Future<void> _verifyRefresh(_GuestFixture fixture) async {
  final root = await Directory.systemTemp.createTemp('publication-refresh-');
  addTearDown(() => root.delete(recursive: true));
  final db = AppDatabase.memory();
  addTearDown(db.close);
  final store = PublicationStore(db);
  final network = MediaHttpClient();
  addTearDown(network.close);
  final http = PublicationHttp(network, authorize: (_) {});
  final transfer = PublicationTransfer(
    http,
    PublicationSpace(store, root, freeBytes: (_) async => 4 << 30),
  );
  final digest = sha256.convert(fixture.current).toString();
  final id = await store.addTask(
    const PublicationEdition(
      id: 'guest-refresh-fixture',
      title: 'Field Manual',
    ),
    [
      AcquisitionCandidate(
        source: 'manual',
        link: Uri.https('pan.quark.cn', '/s/fixture'),
        fileId: '0:fixture-file',
        format: PublicationFormat.pdf,
        bytes: fixture.current.length,
        digest: digest,
      ),
    ],
  );
  final done = Completer<void>();
  late final PublicationAcquisitions runner;
  runner = PublicationAcquisitions(
    store,
    PublicationDiscovery(store, http, (_) => true),
    PublicationShareResolver(http),
    transfer,
    (_) {},
    activity: () {
      if (!runner.busy && !done.isCompleted) done.complete();
      if (!fixture.firstCheckpoint.isCompleted) {
        unawaited(
          store.task(id).then((task) {
            if (task?.received == _sliceBytes &&
                !fixture.firstCheckpoint.isCompleted) {
              fixture.firstCheckpoint.complete();
            }
          }),
        );
      }
    },
  );
  addTearDown(runner.close);
  runner.start(id);
  await done.future.timeout(const Duration(seconds: 15));

  final task = (await store.task(id))!;
  expect(task.state, AcquisitionState.downloaded, reason: '${task.problem}');
  expect(task.failures, isEmpty);
  expect(task.received, fixture.current.length);
  expect(fixture.issued, 2);
  expect(fixture.expiredSlices, unorderedEquals([_secondSlice, _lastSlice]));
  expect(fixture.servedSlices[1], [_firstSlice]);
  expect(
    fixture.servedSlices[2],
    unorderedEquals([_firstSlice, _secondSlice, _lastSlice]),
  );
  expect(
    await publicationFileDigest(transfer.part(id), CancellationToken()),
    digest,
  );
}

final class _GuestFixture {
  _GuestFixture() {
    final pdf = samplePdf();
    current.setRange(0, pdf.length, pdf);
    previous.setRange(0, pdf.length, pdf);
    previous[1 << 20] = 1;
  }

  final current = Uint8List(9 << 20);
  final previous = Uint8List(9 << 20);
  final firstCheckpoint = Completer<void>();
  final _oldSlicesArrived = Completer<void>();
  final expiredSlices = <String>[];
  final servedSlices = <int, List<String>>{};
  int issued = 0;

  Future<void> serve(HttpRequest request) async {
    final response = request.response;
    try {
      await request.drain<void>();
      if (request.uri.path == '/field-manual.pdf') {
        await _file(request);
      } else {
        _api(request);
      }
      await response.close();
    } on TimeoutException {
      response.statusCode = HttpStatus.gatewayTimeout;
      await response.close();
    } on IOException {
      // The range runner cancels any pending old-generation responses.
    }
  }

  void _api(HttpRequest request) {
    final response = request.response;
    if (request.headers.value(HttpHeaders.cookieHeader) != null) {
      response.statusCode = HttpStatus.forbidden;
      return;
    }
    final Object? data = switch (request.uri.path) {
      '/1/clouddrive/share/sharepage/token' => {'stoken': 'fixture-ticket'},
      '/1/clouddrive/share/sharepage/detail' => {
        'list': [
          {
            'fid': 'fixture-file',
            'file_name': 'Field Manual.pdf',
            'size': current.length,
            'share_fid_token': 'fixture-file-ticket',
          },
        ],
      },
      '/1/clouddrive/file/download' => _newDownload(response),
      _ => null,
    };
    if (data == null) {
      response.statusCode = HttpStatus.notFound;
      return;
    }
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode({'code': 0, 'status': 200, 'data': data}));
  }

  List<Map<String, String>> _newDownload(HttpResponse response) {
    issued++;
    response.cookies.add(
      Cookie('__pugs', 'fixture-$issued')
        ..domain = 'quark.cn'
        ..path = '/'
        ..secure = true,
    );
    return [
      {
        'fid': 'fixture-file',
        'download_url': 'https://$_cdn/field-manual.pdf?session=$issued',
      },
    ];
  }

  Future<void> _file(HttpRequest request) async {
    final response = request.response;
    final session = int.tryParse(request.uri.queryParameters['session'] ?? '');
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final etag = '"fixture-version-$session"';
    if (session == null ||
        request.headers.value(HttpHeaders.cookieHeader) !=
            '__pugs=fixture-$session' ||
        (range != 'bytes=0-0' &&
            request.headers.value(HttpHeaders.ifRangeHeader) != etag)) {
      response.statusCode = HttpStatus.forbidden;
      return;
    }
    final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range ?? '');
    if (match == null) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      return;
    }
    final start = int.parse(match[1]!);
    final end = int.parse(match[2]!);
    if (session == 1 && start > 0) {
      expiredSlices.add(range!);
      if (expiredSlices.length == 2) _oldSlicesArrived.complete();
      await _oldSlicesArrived.future.timeout(const Duration(seconds: 5));
      await firstCheckpoint.future.timeout(const Duration(seconds: 5));
      response.statusCode = HttpStatus.preconditionFailed;
      return;
    }

    if (range != 'bytes=0-0') {
      servedSlices.putIfAbsent(session, () => []).add(range!);
    }
    final bytes = session == 1 ? previous : current;
    response.statusCode = HttpStatus.partialContent;
    response.headers.contentType = ContentType('application', 'pdf');
    response.headers.set(HttpHeaders.etagHeader, etag);
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$end/${bytes.length}',
    );
    response.contentLength = end - start + 1;
    response.add(Uint8List.sublistView(bytes, start, end + 1));
  }
}

/// Test-only routing. The real share adapter still sees the HTTPS origins.
final class _LocalClient implements HttpClient {
  _LocalClient(this.client, this.port);

  final HttpClient client;
  final int port;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) {
    if (uri.scheme != 'https' ||
        uri.port != 443 ||
        !const {'drive-pc.quark.cn', _cdn}.contains(uri.host)) {
      throw const SocketException('Request outside the guest fixture');
    }
    return client.openUrl(
      method,
      uri.replace(scheme: 'http', host: '127.0.0.1', port: port),
    );
  }

  @override
  void close({bool force = false}) => client.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isSetter) return null;
    return super.noSuchMethod(invocation);
  }
}
