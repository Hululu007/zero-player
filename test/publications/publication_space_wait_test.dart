import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
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

import '../../test_support/publication_range_fixture.dart';
import '../../test_support/local_book_fixtures.dart';

const _occupied = 60 << 20;
final _blocker = publicationId('other storage');

void main() {
  test(
    'quota denial parks a new download without writing a part',
    () => _withTransfer(_verifyWaiting),
  );
  test(
    'denied resume keeps its verified range for the next attempt',
    () => _withTransfer(_verifyRangeRetry),
  );
  test(
    'denial before a single-stream restart keeps the old verified range',
    () => _withTransfer(_verifySingleRetry),
  );
  test(
    'unknown length waits for a new reservation before writing the next window',
    () => _withTransfer(_verifyWindow, unknownLength: true),
  );
  test(
    'device headroom can be tighter than the remaining quota',
    () => _withTransfer(
      _verifyDisk,
      freeBytes: PublicationSpace.minFree + (3 << 20),
    ),
  );
}

Future<void> _withTransfer(
  Future<void> Function(_Running, PublicationRangeFixture) verify, {
  bool unknownLength = false,
  int freeBytes = 4 << 30,
}) async {
  final source = await PublicationRangeFixture.start(
    unknownLength: unknownLength,
  );
  addTearDown(source.close);
  final fixture = await _Running.start(source, freeBytes);
  addTearDown(fixture.close);
  await verify(fixture, source);
}

Future<void> _verifyWaiting(
  _Running fixture,
  PublicationRangeFixture source,
) async {
  final bytes = samplePdf();
  final digest = sha256.convert(bytes).toString();
  final file = fixture.space.managedFile(digest, PublicationFormat.pdf);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes);
  await fixture.store.db.write(
    'INSERT INTO publication_files(digest,format,bytes,placement) VALUES(?,?,?,?)',
    [digest, 'pdf', bytes.length, 'managed'],
  );
  final held = _occupied - bytes.length;
  await fixture.space.reserve(_blocker, held, used: held);

  final task = await fixture.run();

  expect(task.state, AcquisitionState.waiting);
  expect(task.problem, PublicationProblem.space);
  expect(task.spaceShortfall, (
    requiredBytes: source.bytes.length,
    availableBytes: 4 << 20,
    protectedBytes: bytes.length,
  ));
  expect(task.received, 0);
  expect(task.failures, isEmpty);
  expect(source.requests, ['bytes=0-0']);
  expect(await fixture.part.exists(), isFalse);
  expect(await file.readAsBytes(), bytes);
  expect((await fixture.space.usage()).reserved, 0);

  final reopened = PublicationStore(
    AppDatabase(File('${fixture.root.path}/waiting.sqlite')),
  );
  addTearDown(reopened.db.close);
  expect(
    (await reopened.task(fixture.id))!.spaceShortfall,
    task.spaceShortfall,
  );
}

Future<void> _verifyRangeRetry(
  _Running fixture,
  PublicationRangeFixture source,
) async {
  await fixture.writeCheckpoint(source);
  await fixture.space.reserve(_blocker, _occupied, used: _occupied);
  final paused = await fixture.run();

  expect(paused.state, AcquisitionState.paused);
  expect(paused.problem, PublicationProblem.space);
  expect(paused.received, PublicationTransfer.sliceBytes);
  expect(paused.failures, isEmpty);
  expect(source.requests, ['bytes=0-0']);
  expect(await fixture.part.length(), PublicationTransfer.sliceBytes);
  expect((await fixture.space.usage()).reserved, 0);

  await fixture.space.release(_blocker);
  source.requests.clear();
  final downloaded = await fixture.run();
  expect(downloaded.state, AcquisitionState.downloaded);
  expect(downloaded.spaceShortfall, isNull);
  expect(
    source.requests,
    unorderedEquals([
      'bytes=0-0',
      'bytes=4194304-8388607',
      'bytes=8388608-9437183',
    ]),
  );
  expect(
    await publicationFileDigest(fixture.part, CancellationToken()),
    sha256.convert(source.bytes).toString(),
  );
}

Future<void> _verifySingleRetry(
  _Running fixture,
  PublicationRangeFixture source,
) async {
  await fixture.writeCheckpoint(source);
  final task = (await fixture.store.task(fixture.id))!;
  await fixture.store.updateTask(
    task,
    AcquisitionState.paused,
    failures: [
      (
        candidate: 0,
        problem: PublicationProblem.rateLimit,
        at: DateTime.now(),
        retryAt: null,
      ),
    ],
  );
  await fixture.space.reserve(_blocker, _occupied, used: _occupied);
  final paused = await fixture.run();
  expect(paused.state, AcquisitionState.paused);
  expect(paused.received, PublicationTransfer.sliceBytes);
  expect(paused.failures.single.problem, PublicationProblem.rateLimit);
  expect(source.requests, ['all']);
  expect(
    await fixture.part.readAsBytes(),
    source.bytes.sublist(0, PublicationTransfer.sliceBytes),
  );
  expect(
    await fixture.store.db.rows(
      'SELECT start FROM publication_ranges WHERE task=?',
      [fixture.id],
    ),
    [
      {'start': 0},
    ],
  );
}

Future<void> _verifyWindow(_Running fixture, PublicationRangeFixture _) async {
  const occupied = 56 << 20;
  await fixture.space.reserve(_blocker, occupied, used: occupied);
  final task = await fixture.run();
  expect(task.state, AcquisitionState.paused);
  expect(task.problem, PublicationProblem.space);
  expect(task.spaceShortfall, (
    requiredBytes: 16 << 20,
    availableBytes: 8 << 20,
    protectedBytes: 0,
  ));
  expect(task.received, greaterThan(0));
  expect(task.received, lessThanOrEqualTo(8 << 20));
  expect(task.received, await fixture.part.length());
  expect((await fixture.space.usage()).used, occupied + task.received);
  expect((await fixture.space.usage()).reserved, 0);
}

Future<void> _verifyDisk(
  _Running fixture,
  PublicationRangeFixture source,
) async {
  final task = await fixture.run();
  expect(task.state, AcquisitionState.waiting);
  expect(task.spaceShortfall, (
    requiredBytes: source.bytes.length,
    availableBytes: 3 << 20,
    protectedBytes: 0,
  ));
  expect(await fixture.part.exists(), isFalse);
}

final class _Running {
  _Running(
    this.id,
    this.root,
    this.network,
    this.discovery,
    this.transfer,
    this.runner,
  );

  final String id;
  final Directory root;
  final MediaHttpClient network;
  final PublicationDiscovery discovery;
  final PublicationTransfer transfer;
  final PublicationAcquisitions runner;

  PublicationSpace get space => transfer.space;
  PublicationStore get store => space.store;
  File get part => transfer.part(id);

  static Future<_Running> start(
    PublicationRangeFixture source,
    int freeBytes,
  ) async {
    final root = await Directory.systemTemp.createTemp(
      'publication-space-wait-',
    );
    final store = PublicationStore(
      AppDatabase(File('${root.path}/waiting.sqlite')),
    );
    final network = MediaHttpClient(allowPrivateNetworks: true);
    final http = PublicationHttp(
      network,
      authorize: (_) {},
      allowLoopback: true,
    );
    final space = PublicationSpace(
      store,
      Directory('${root.path}/publications'),
      freeBytes: (_) async => freeBytes,
    );
    await space.setLimit(64 << 20);
    final transfer = PublicationTransfer(http, space);
    final discovery = PublicationDiscovery(store, http, (_) => true);
    final runner = PublicationAcquisitions(
      store,
      discovery,
      PublicationShareResolver(http),
      transfer,
      (_) {},
    );
    final id = await store.addTask(
      const PublicationEdition(
        id: 'space-wait-fixture',
        title: 'Local reference',
      ),
      [source.candidate],
    );
    return _Running(id, root, network, discovery, transfer, runner);
  }

  Future<AcquisitionTask> run() async {
    runner.start(id);
    final watch = Stopwatch()..start();
    while (runner.busy && watch.elapsed < const Duration(seconds: 15)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(runner.busy, isFalse);
    return (await store.task(id))!;
  }

  Future<void> writeCheckpoint(PublicationRangeFixture source) async {
    const count = PublicationTransfer.sliceBytes;
    final saved = source.bytes.sublist(0, count);
    final uri = source.uri;
    final identity = publicationId(
      '${source.candidate.id}\n${uri.origin}${uri.path}\n"release-v1"\n${source.bytes.length}',
    );
    await part.parent.create(recursive: true);
    await part.writeAsBytes(saved, flush: true);
    await store.db.write('INSERT INTO publication_transfer VALUES(?,?)', [
      id,
      identity,
    ]);
    await store.db.write('INSERT INTO publication_ranges VALUES(?,?,?)', [
      id,
      0,
      sha256.convert(saved).toString(),
    ]);
    await space.release(id, used: count);
    await store.updateTask(
      (await store.task(id))!,
      AcquisitionState.paused,
      received: count,
      total: source.bytes.length,
    );
  }

  Future<void> close() async {
    await runner.close();
    discovery.close();
    network.close();
    await store.db.close();
    await root.delete(recursive: true);
  }
}
