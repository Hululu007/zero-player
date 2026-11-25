import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/publications/application/cloud_resource_download.dart';
import 'package:zero_player/features/publications/application/publication_acquisitions.dart';
import 'package:zero_player/features/publications/application/publication_discovery.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/data/publication_lunarora_catalogue.dart';
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
    'resource save checks capacity before guest download and preserves existing files',
    _verifyCloudDownload,
  );
  test(
    'folder batch uses one directory and retains files saved before a conflict',
    _verifyCloudBatch,
  );
  test('a Lanzou share can save a bounded response with no size', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final directory = await Directory.systemTemp.createTemp('cloud-no-size-');
    addTearDown(() => directory.delete(recursive: true));
    final original = HttpClient()..findProxy = (_) => 'DIRECT';
    addTearDown(() => original.close(force: true));
    final previous = FileSelectorPlatform.instance;
    FileSelectorPlatform.instance = _CloudPicker(directory.path);
    addTearDown(() => FileSelectorPlatform.instance = previous);
    final contents = utf8.encode('fixture without length');
    server.listen((request) async {
      await request.drain<void>();
      final response = request.response;
      switch (request.uri.path) {
        case '/iSample':
          response.headers.contentType = ContentType.html;
          response.write(
            '<title>sample.txt</title><script>var sign="sample"; '
            'var websignkey="fixture"; var api="/ajaxm.php"; downprocess();</script>',
          );
        case '/ajaxm.php':
          response.headers.contentType = ContentType.json;
          response.write(
            jsonEncode({
              'zt': 1,
              'dom': 'https://www.lanzou.com',
              'url': 'fixture',
            }),
          );
        case '/file/fixture':
          response.headers.contentType = ContentType.text;
          response.headers.chunkedTransferEncoding = true;
          response.add(contents);
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
    await HttpOverrides.runZoned(
      () async {
        final network = MediaHttpClient();
        addTearDown(network.close);
        final tool = CloudResourceDownload(
          PublicationShareResolver(PublicationHttp(network, authorize: (_) {})),
          (_) {},
        );
        final share = Uri.https('www.lanzou.com', '/iSample');
        final file = (await tool.inspect(share, null)).single;
        expect(file.bytes, isNull);
        final sizes = <int>[];
        final saved = await tool.save(
          share,
          null,
          file,
          (_, total) => sizes.add(total),
        );
        expect(await File(saved!).readAsBytes(), contents);
        expect(sizes.first, -1);
        expect(sizes.last, contents.length);
      },
      createHttpClient: (_) =>
          _LocalClient(original, server.port, hosts: const {'www.lanzou.com'}),
    );
  });
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

Future<void> _verifyCloudDownload() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  final originalClient = HttpClient()..findProxy = (_) => 'DIRECT';
  addTearDown(() => originalClient.close(force: true));
  final directory = await Directory.systemTemp.createTemp(
    'cloud-resource-test-',
  );
  addTearDown(() => directory.delete(recursive: true));
  final picker = FileSelectorPlatform.instance;
  final fixturePicker = _CloudPicker(directory.path);
  FileSelectorPlatform.instance = fixturePicker;
  addTearDown(() => FileSelectorPlatform.instance = picker);
  final contents = utf8.encode('fixture audio');
  const filename = 'sample.mp3';
  const oversized = 'oversized.mp4';
  var downloads = 0;
  server.listen((request) async {
    await request.drain<void>();
    final response = request.response;
    final Object? data = switch (request.uri.path) {
      '/1/clouddrive/share/sharepage/token' => {'stoken': 'fixture-ticket'},
      '/1/clouddrive/share/sharepage/detail' => {
        'list': [
          {
            'fid': 'sample',
            'file_name': filename,
            'size': contents.length,
            'share_fid_token': 'file-ticket',
          },
          {
            'fid': 'large',
            'file_name': oversized,
            'size': 1 << 60,
            'share_fid_token': 'other-ticket',
          },
        ],
      },
      '/1/clouddrive/file/download' => [
        {'fid': 'sample', 'download_url': 'https://$_cdn/sample.mp3'},
      ],
      _ => null,
    };
    if (data != null) {
      if (request.uri.path.endsWith('/file/download')) {
        downloads++;
        response.cookies.add(
          Cookie('__pugs', 'cloud-test')
            ..domain = 'quark.cn'
            ..path = '/'
            ..secure = true,
        );
      }
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'code': 0, 'status': 200, 'data': data}));
    } else if (request.uri.path == '/sample.mp3') {
      response.headers.contentType = ContentType('audio', 'mpeg');
      response.contentLength = contents.length;
      response.add(contents);
    } else {
      response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  });
  await HttpOverrides.runZoned(() async {
    final network = MediaHttpClient();
    addTearDown(network.close);
    final resolver = PublicationShareResolver(
      PublicationHttp(network, authorize: (_) {}),
    );
    var metered = true;
    final tool = CloudResourceDownload(
      resolver,
      (_) {},
      checkDownload: () async {
        if (metered) throw const PublicationFailure(PublicationProblem.metered);
      },
    );
    final share = Uri.https('pan.quark.cn', '/s/fixture');
    final files = await tool.inspect(share, 'ABCD');
    expect(files.map((file) => file.name), [filename, oversized]);
    await expectLater(
      tool.save(share, 'ABCD', files.first, (_, _) {}),
      throwsA(
        isA<PublicationFailure>().having(
          (error) => error.problem,
          'problem',
          PublicationProblem.metered,
        ),
      ),
    );
    expect(fixturePicker.uses, 0);
    metered = false;
    expect(await resolver.inspect(share, null, CancellationToken()), isEmpty);
    await expectLater(
      tool.save(share, 'ABCD', files.last, (_, _) {}),
      throwsA(
        isA<PublicationFailure>().having(
          (error) => error.problem,
          'problem',
          PublicationProblem.diskFull,
        ),
      ),
    );
    expect(downloads, 0);
    expect(await directory.list().toList(), isEmpty);
    final path = await tool.save(share, 'ABCD', files.first, (_, _) {});
    expect(await File(path!).readAsBytes(), contents);
    await expectLater(
      tool.save(share, 'ABCD', files.first, (_, _) {}),
      throwsA(
        isA<PublicationFailure>().having(
          (error) => error.problem,
          'problem',
          PublicationProblem.destinationConflict,
        ),
      ),
    );
    expect(downloads, 1);
    expect((await directory.list().toList()).single.path, path);
  }, createHttpClient: (_) => _LocalClient(originalClient, server.port));
}

Future<void> _verifyCloudBatch() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final original = HttpClient()..findProxy = (_) => 'DIRECT';
  addTearDown(() => server.close(force: true));
  addTearDown(() => original.close(force: true));
  final target = await Directory.systemTemp.createTemp('cloud-batch-test-');
  addTearDown(() => target.delete(recursive: true));
  final previous = FileSelectorPlatform.instance;
  final picker = _CloudPicker(target.path);
  FileSelectorPlatform.instance = picker;
  addTearDown(() => FileSelectorPlatform.instance = previous);

  final nested = await Directory(
    '${target.path}/Resources/Nested',
  ).create(recursive: true);
  final existing = await File(
    '${nested.path}/notes.txt',
  ).writeAsString('existing');
  final contents = utf8.encode('fixture audio');
  final file = {
    'fid': 'sample',
    'file_name': 'sample.mp3',
    'size': contents.length,
    'share_fid_token': 'file-ticket',
  };
  Map<String, Object> folder(String id, String name) => {
    'fid': id,
    'file_name': name,
    'dir': true,
  };
  server.listen((request) async {
    final body = await utf8.decoder.bind(request).join();
    final fid = request.uri.path.endsWith('/file/download')
        ? ((jsonDecode(body) as Map)['fids'] as List).single
        : null;
    final response = request.response;
    final Object? data = switch (request.uri.path) {
      '/1/clouddrive/share/sharepage/token' => {'stoken': 'fixture-ticket'},
      '/1/clouddrive/share/sharepage/detail' => {
        'list': switch (request.uri.queryParameters['pdir_fid']) {
          '0' => [folder('resources', 'Resources')],
          'resources' => [file, folder('nested', 'Nested')],
          'nested' => [
            {...file, 'fid': 'notes', 'file_name': 'notes.txt'},
          ],
          _ => const [],
        },
      },
      '/1/clouddrive/file/download' => [
        {'fid': fid, 'download_url': 'https://$_cdn/sample.mp3'},
      ],
      _ => null,
    };
    if (data != null) {
      if (request.uri.path.endsWith('/file/download')) {
        response.cookies.add(
          Cookie('__pugs', 'cloud-test')
            ..domain = 'quark.cn'
            ..path = '/'
            ..secure = true,
        );
      }
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'code': 0, 'status': 200, 'data': data}));
    } else if (request.uri.path == '/sample.mp3') {
      response.headers.contentType = ContentType('audio', 'mpeg');
      response.contentLength = contents.length;
      response.add(contents);
    } else {
      response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  });

  await HttpOverrides.runZoned(() async {
    final network = MediaHttpClient();
    addTearDown(network.close);
    final service = CloudResourceDownload(
      PublicationShareResolver(PublicationHttp(network, authorize: (_) {})),
      (_) {},
    );
    final share = Uri.https('pan.quark.cn', '/s/fixture');
    final tree = await service.inspectTree(share, null);
    expect(tree.truncated, isFalse);
    expect(tree.files.map((item) => item.folders), [
      ['Resources'],
      ['Resources', 'Nested'],
    ]);
    final result = (await service.saveBatch(share, null, tree.files, (_) {}))!;
    expect(picker.uses, 1);
    expect(result.saved, [tree.files.first]);
    expect(
      (result.failure as PublicationFailure).problem,
      PublicationProblem.destinationConflict,
    );
    expect(await existing.readAsString(), 'existing');
    expect(
      await File('${target.path}/Resources/sample.mp3').readAsBytes(),
      contents,
    );
    await existing.delete();
    final remaining = tree.files
        .where((item) => !result.saved.contains(item))
        .toList();
    final retried = (await service.saveBatch(share, null, remaining, (_) {}))!;
    expect(retried.failure, isNull);
    expect(await existing.readAsBytes(), contents);
  }, createHttpClient: (_) => _LocalClient(original, server.port));
}

final class _CloudPicker extends FileSelectorPlatform {
  _CloudPicker(this.path);
  final String path;
  int uses = 0;

  @override
  Future<String?> getDirectoryPath({
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    uses++;
    return path;
  }
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
  final resolver = PublicationShareResolver(http);
  final discovery = PublicationDiscovery(store, http, (_) => true);
  addTearDown(discovery.close);
  final edition = parseLunaroraSearch({
    'apiVersion': '2',
    'contentLanguage': 'zh-CN',
    'count': 1,
    'results': [
      {
        'type': 'Book',
        'catalogId': '9787020161171',
        'bookUrl': 'https://lunarora.com/book/9787020161171',
        'title': 'Field Manual',
        'authorsText': '',
        'hasDownloadLinks': true,
        'downloadLinks': [
          {'provider': 'quark', 'url': 'https://pan.quark.cn/s/fixture'},
        ],
      },
    ],
  }).single;
  final resource = edition.resources.single;
  final file = (await resolver.inspect(
    resource.link,
    resource.code,
    CancellationToken(),
  )).single;
  final id = await store.addTask(edition, [
    AcquisitionCandidate(
      source: resource.source,
      page: edition.page,
      link: resource.link,
      fileId: file.id,
      sharedFileName: file.name,
      format: file.format,
      bytes: file.bytes,
      digest: digest,
    ),
  ]);
  final done = Completer<void>();
  late final PublicationAcquisitions runner;
  runner = PublicationAcquisitions(
    store,
    discovery,
    resolver,
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
  _LocalClient(
    this.client,
    this.port, {
    this.hosts = const {'drive-pc.quark.cn', _cdn},
  });

  final HttpClient client;
  final int port;
  final Set<String> hosts;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) {
    if (uri.scheme != 'https' || uri.port != 443 || !hosts.contains(uri.host)) {
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
