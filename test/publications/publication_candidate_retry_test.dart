import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/publications/application/publication_acquisitions.dart';
import 'package:zero_player/features/publications/application/publication_discovery.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/data/publication_share.dart';
import 'package:zero_player/features/publications/data/publication_space.dart';
import 'package:zero_player/features/publications/data/publication_store.dart';
import 'package:zero_player/features/publications/data/publication_transfer.dart';
import 'package:zero_player/features/publications/domain/acquisition_task.dart';
import 'package:zero_player/features/publications/domain/publication.dart';

import '../../test_support/local_book_fixtures.dart';

void main() {
  test(
    'fallback retains the retry date from an actual 429 response',
    () => _verifyCooldown(preflight: false),
  );
  test(
    'an earlier 429 still delays same-origin candidates after a restart',
    () => _verifyCooldown(preflight: true),
  );
  test('legacy candidate history has no recorded retry date', () async {
    final store = PublicationStore(AppDatabase.memory());
    addTearDown(store.db.close);
    final id = await store.addTask(_manual, [_published]);
    final checked = DateTime(2026, 11, 21, 12);
    await store.db.write('UPDATE publication_tasks SET failures=? WHERE id=?', [
      jsonEncode([
        [0, 'rateLimit', checked.millisecondsSinceEpoch],
      ]),
      id,
    ]);
    final saved = (await store.task(id))!.failures.single;
    expect(saved.at, checked);
    expect(saved.retryAt, isNull);
  });
}

final _manual = PublicationEdition(
  id: publicationId('publication retry fixture'),
  title: 'Reference Manual',
);
final _published = AcquisitionCandidate(
  source: 'manual',
  link: Uri.https('catalog.example', '/manual.pdf'),
  format: PublicationFormat.pdf,
);

Future<void> _verifyCooldown({required bool preflight}) async {
  final root = await Directory.systemTemp.createTemp('publication-cooldown-');
  addTearDown(() => root.delete(recursive: true));
  final header = HttpDate.format(
    DateTime.now().add(const Duration(minutes: 2)),
  );
  final retryAt = HttpDate.parse(header);
  final limitedRequests = <String>[];
  final limited = await _listen((request) async {
    limitedRequests.add(request.uri.path);
    request.response
      ..statusCode = 429
      ..headers.set('retry-after', header);
    await request.response.close();
  });
  final original = samplePdf();
  final available = await _listen((request) async {
    request.response
      ..headers.contentType = ContentType('application', 'pdf')
      ..contentLength = original.length
      ..add(original);
    await request.response.close();
  });
  final candidates = [
    _candidate(limited, 'limited.pdf'),
    _candidate(limited, 'another.pdf'),
    _candidate(available, 'original.pdf'),
  ];
  final database = File('${root.path}/tasks.sqlite');
  final initial = PublicationStore(AppDatabase(database));
  final id = await initial.addTask(
    _manual,
    candidates,
    preflightFailure: preflight
        ? PublicationFailure(PublicationProblem.rateLimit, retryAt: retryAt)
        : null,
  );
  await initial.db.close();

  final store = PublicationStore(AppDatabase(database));
  final transfer = await _download(store, root, id);
  expect(limitedRequests, preflight ? isEmpty : ['/limited.pdf']);
  expect(await transfer.part(id).readAsBytes(), original);

  final reopened = PublicationStore(AppDatabase(database));
  addTearDown(reopened.db.close);
  final saved = (await reopened.task(id))!;
  expect(saved.state, AcquisitionState.downloaded);
  expect(saved.selected, 2);
  expect(saved.retryAt, isNull);
  expect(saved.failures.map((failure) => failure.candidate), [0, 1]);
  expect(
    saved.failures.map((failure) => failure.retryAt?.millisecondsSinceEpoch),
    [retryAt.millisecondsSinceEpoch, retryAt.millisecondsSinceEpoch],
  );
}

Future<PublicationTransfer> _download(
  PublicationStore store,
  Directory root,
  String id,
) async {
  final network = MediaHttpClient(allowPrivateNetworks: true);
  final http = PublicationHttp(network, authorize: (_) {}, allowLoopback: true);
  final discovery = PublicationDiscovery(store, http, (_) => true);
  final transfer = PublicationTransfer(http, PublicationSpace(store, root));
  final completed = Completer<void>();
  late final PublicationAcquisitions runner;
  runner = PublicationAcquisitions(
    store,
    discovery,
    PublicationShareResolver(http),
    transfer,
    (_) {},
    activity: () {
      if (!runner.busy && !completed.isCompleted) completed.complete();
    },
  );
  try {
    runner.start(id);
    await completed.future.timeout(const Duration(seconds: 10));
    return transfer;
  } finally {
    await runner.close();
    discovery.close();
    network.close();
    await store.db.close();
  }
}

Future<HttpServer> _listen(Future<void> Function(HttpRequest) serve) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) => unawaited(serve(request)));
  return server;
}

AcquisitionCandidate _candidate(HttpServer server, String name) =>
    AcquisitionCandidate(
      source: 'manual',
      link: Uri.parse('http://127.0.0.1:${server.port}/$name'),
      format: PublicationFormat.pdf,
    );
