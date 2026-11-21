import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/publications/application/publication_discovery.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/data/publication_space.dart';
import 'package:zero_player/features/publications/data/publication_store.dart';
import 'package:zero_player/features/publications/data/publication_transfer.dart';
import 'package:zero_player/features/publications/data/publication_zip.dart';
import 'package:zero_player/features/publications/domain/acquisition_task.dart';
import 'package:zero_player/features/publications/domain/publication.dart';
import 'package:zero_player/features/publications/domain/share_text.dart';

import '../../test_support/local_book_fixtures.dart';
import '../../test_support/publication_range_fixture.dart';

void main() {
  late Directory root;
  late AppDatabase db;
  late PublicationSpace space;
  late MediaHttpClient kernel;
  late PublicationTransfer transfer;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('publication-test-');
    db = AppDatabase.memory();
    kernel = MediaHttpClient(allowPrivateNetworks: true);
    space = PublicationSpace(
      PublicationStore(db),
      root,
      freeBytes: (_) async => 4 << 30,
    );
    await space.store.initialize();
    transfer = PublicationTransfer(
      PublicationHttp(kernel, authorize: (_) {}, allowLoopback: true),
      space,
    );
  });

  tearDown(() async {
    kernel.close();
    await db.close();
    await root.delete(recursive: true);
  });

  test(
    'share extraction keeps independent codes and omits password parameters',
    _shareCodes,
  );

  test(
    'guest cookies have host, path, HTTPS and expiration boundaries',
    _guestBoundaries,
  );
  test(
    'source edits preserve enable and favorite preferences',
    () => _sourcePreferences(space, kernel),
  );
  test(
    'a failed refresh keeps the last accepted snapshot searchable',
    () => _retainedCatalog(space, kernel),
  );

  test(
    'two reservations cannot both obtain the last 512 MiB',
    () => _compete(space),
  );
  test(
    'restart counts actual partials and preserves live reservations',
    () => _reconcile(space),
  );
  test(
    'quota cannot evict copies with removed sources or leases',
    () => _eviction(space),
  );

  test(
    'reopening a task reuses intact ranges and replaces a damaged range',
    () => _resumeRanges(root, transfer.http),
  );

  test(
    'incorrect slice headers cause a fresh single-stream download',
    () => _fallback(transfer),
  );
  test(
    'a 416 probe reuses a complete checkpoint only after rechecking its bytes',
    () => _completeOnRangeRejection(transfer),
  );
  test(
    'a 416 slice reporting a different file length stops the transfer',
    () => _changedLengthOnRangeRejection(transfer),
  );
  test(
    'a changed validator stops full-stream fallback',
    () => _changedWhole(transfer),
  );
  test(
    'single stream retry skips the range probe',
    () => _singleRetry(transfer),
  );

  test(
    'ZIP uses a selected file and rejects traversal before extraction',
    () => _extractZip(root),
  );
  test(
    'EPUB identification requires a central directory',
    () => _validateEpub(root),
  );
}

void _shareCodes() {
  final inputs = publicationShareInputs(
    'https://a.example/share/one?pwd=ab12\n'
    'ZIP 密码: archive\nhttps://b.example/share/two 提取码: xy99',
  );
  expect(inputs.map((item) => item.code), ['ab12', 'xy99']);
  expect(inputs.any((item) => item.link.hasQuery), isFalse);
  final ambiguous = publicationShareInputs(
    'https://a.example/share/one?pwd=ab12 提取码: xy99',
  );
  expect(ambiguous.single.needsConfirmation, isTrue);
  expect(ambiguous.single.code, isNull);
}

Future<void> _validateEpub(Directory root) async {
  final mimeType = 'application/epub+zip'.codeUnits;
  final archive = Archive()
    ..addFile(ArchiveFile.noCompress('mimetype', mimeType.length, mimeType))
    ..addFile(ArchiveFile.string('META-INF/container.xml', '<container/>'));
  final bytes = ZipEncoder().encode(archive);
  final file = File('${root.path}/fixture.epub');
  await file.writeAsBytes(bytes);
  expect(await detectPublicationFormat(file), PublicationFormat.epub);
  await file.writeAsBytes(bytes.sublist(0, 58));
  expect(await detectPublicationFormat(file), isNull);
}

Future<void> _compete(PublicationSpace space) async {
  await space.reserve(
    publicationId('already used'),
    1536 << 20,
    used: 1536 << 20,
  );
  final settled = await Future.wait([
    for (var i = 0; i < 2; i++)
      () async {
        try {
          await space.reserve(publicationId('active $i'), 512 << 20);
          return true;
        } on PublicationFailure catch (error) {
          expect(error.problem, PublicationProblem.space);
          return false;
        }
      }(),
  ]);
  expect(settled.where((won) => won), hasLength(1));
  expect((await space.usage()).reserved, 512 << 20);
}

Future<void> _sourcePreferences(
  PublicationSpace space,
  MediaHttpClient kernel,
) async {
  final discovery = PublicationDiscovery(
    space.store,
    PublicationHttp(kernel, authorize: (_) {}),
    (_) => true,
  );
  String config(String name) => jsonEncode({
    'version': 1,
    'kind': 'snapshot',
    'name': name,
    'endpoint': 'https://test.example/catalog.json',
    'field': {'title': 'name'},
  });
  try {
    await discovery.saveConfig(config('First catalogue'));
    final initial = (await discovery.sources()).singleWhere(
      (row) => row.source.configurable,
    );
    expect(initial.enabled, isFalse);
    await discovery.setEnabled(initial.source, true);
    await discovery.setFavorite(initial.source, true);
    await space.store.db.write(
      "UPDATE publication_source_settings SET failure='invalid' WHERE id=?",
      [initial.source.id],
    );
    expect(await discovery.isEnabled(initial.source.id), isFalse);
    expect((await discovery.sources()).first.enabled, isTrue);
    await discovery.setEnabled(initial.source, false);
    await discovery.saveConfig(
      config('Edited catalogue'),
      id: initial.source.id,
    );
    final changed = (await discovery.sources()).first;
    expect(changed.source.name, 'Edited catalogue');
    expect(changed.favorite, isTrue);
    expect(changed.enabled, isFalse);
    expect(changed.problem, isNull);
    await discovery.remove(changed.source);
    await discovery.check(changed.source);
    expect(
      (await discovery.sources()).any((row) => row.source.configurable),
      isFalse,
    );
  } finally {
    discovery.close();
  }
}

Future<void> _retainedCatalog(
  PublicationSpace space,
  MediaHttpClient kernel,
) async {
  final discovery = PublicationDiscovery(
    space.store,
    PublicationHttp(kernel, authorize: (_) {}),
    (_) => true,
  );
  try {
    for (final entry in (await discovery.sources()).where((e) => e.enabled)) {
      await discovery.setEnabled(entry.source, false);
    }
    await discovery.saveConfig(
      jsonEncode({
        'version': 1,
        'kind': 'snapshot',
        'name': 'Reference catalogue',
        'endpoint': 'https://test.example/catalog.json',
        'field': {'title': 'name'},
      }),
    );
    final source = (await discovery.sources())
        .singleWhere((entry) => entry.source.configurable)
        .source;
    await discovery.setEnabled(source, true);
    final book = PublicationEdition(
      id: publicationId('snapshot-fixture'),
      title: 'Reference workbook',
    );
    await space.store.db.write(
      'INSERT INTO publication_catalog VALUES(?,?,?,?,?)',
      [
        source.id,
        book.id,
        book.searchable,
        book.isbn,
        jsonEncode(book.toJson()),
      ],
    );
    await space.store.db.write(
      "UPDATE publication_source_settings SET revision=?,failure='invalid' WHERE id=?",
      [publicationId('last valid snapshot'), source.id],
    );
    final updates = await discovery
        .search('workbook', CancellationToken())
        .toList();
    expect(updates.single.editions.single.id, book.id);
    await discovery.setEnabled(source, false);
    expect(
      await discovery.search('workbook', CancellationToken()).toList(),
      isEmpty,
    );
  } finally {
    discovery.close();
  }
}

Future<AcquisitionTask> _claimedTask(
  PublicationSpace space,
  String title, {
  String source = 'manual',
}) async {
  final edition = PublicationEdition(id: publicationId(title), title: title);
  final id = await space.store.addTask(edition, [
    AcquisitionCandidate(
      source: source,
      link: Uri.https('test.example', '/$title.pdf'),
      format: PublicationFormat.pdf,
    ),
  ]);
  return (await space.store.claim(id, 'test-owner'))!;
}

Future<void> _reconcile(PublicationSpace space) async {
  final interrupted = await _claimedTask(space, 'interrupted');
  final active = await _claimedTask(space, 'active');
  final partDirectory = await space
      .taskDirectory(interrupted.id)
      .create(recursive: true);
  final file = File('${partDirectory.path}/download.part');
  await file.writeAsString('verified partial');
  await space.reserve(interrupted.id, 512 << 20);
  await space.reserve(active.id, 128 << 20);
  await space.store.updateTask(interrupted, AcquisitionState.paused);
  await space.reconcile();
  final usage = await space.usage();
  expect(usage.used, await file.length());
  expect(usage.reserved, 128 << 20);
}

Future<void> _eviction(PublicationSpace space) async {
  const capacity = 64 << 20;
  await space.setLimit(capacity);
  final digest = publicationId('book');
  final file = space.managedFile(digest, PublicationFormat.pdf);
  await file.parent.create(recursive: true);
  final handle = await file.open(mode: FileMode.write);
  try {
    await handle.truncate(capacity);
  } finally {
    await handle.close();
  }
  final db = space.store.db;
  await db.write(
    "INSERT INTO publication_files(digest,format,bytes,placement,downloaded) VALUES(?,'pdf',?,'managed',1)",
    [digest, capacity],
  );
  final item = publicationId('holding');
  await db.write(
    'INSERT INTO publication_shelf(id,digest,added) VALUES(?,?,0)',
    [item, digest],
  );
  final removed = await _claimedTask(
    space,
    'discontinued',
    source: publicationId('removed source'),
  );
  await space.store.updateTask(
    removed,
    AcquisitionState.complete,
    result: digest,
  );
  final pending = publicationId('new book');
  final insufficient = isA<PublicationFailure>().having(
    (failure) => failure.problem,
    'problem',
    PublicationProblem.space,
  );
  await expectLater(space.reserve(pending, 1), throwsA(insufficient));
  expect(await file.exists(), isTrue);

  final manual = await _claimedTask(space, 'confirmed manual source');
  await space.store.updateTask(
    manual,
    AcquisitionState.complete,
    result: digest,
  );
  final lease = await space.lease(digest, file);
  await expectLater(space.reserve(pending, 1), throwsA(insufficient));
  await space.unlease(lease);
  await expectLater(
    space.reserve(
      pending,
      1,
      authorize: () {
        if (!file.existsSync()) {
          throw const PublicationFailure(PublicationProblem.blocked);
        }
      },
    ),
    throwsA(
      isA<PublicationFailure>().having(
        (failure) => failure.problem,
        'problem',
        PublicationProblem.blocked,
      ),
    ),
  );
  expect(await file.exists(), isTrue);
  expect(
    await db.rows('SELECT digest FROM publication_file_releases'),
    isEmpty,
  );
  await file.rename('${file.path}.releasing');
  await space.releases.restoreUncommitted(digest, file);
  expect(await file.exists(), isTrue);
  await space.reserve(pending, 1);
  expect(await file.exists(), isFalse);
  expect(
    (await db.rows(
      'SELECT placement FROM publication_files',
    )).single['placement'],
    isNull,
  );
  expect(
    (await db.rows('SELECT id FROM publication_shelf')).single['id'],
    item,
  );
}

void _guestBoundaries() {
  final jar = GuestShareSession((_) => true);
  final target = Uri.parse('https://site.example/share/list');
  jar.receive(target, [Cookie('guest', 'one')..secure = true]);
  expect(
    jar.forAddress(Uri.parse('https://site.example/share/range')),
    'guest=one',
  );
  for (final link in [
    'http://site.example/share/list',
    'https://cdn.site.example/share/list',
    'https://site.example/other',
  ]) {
    expect(jar.forAddress(Uri.parse(link)), isNull);
  }
  jar.receive(target, [Cookie('guest', 'none')..maxAge = 0]);
  expect(jar.forAddress(target), isNull);
}

Future<void> _resumeRanges(Directory root, PublicationHttp http) async {
  final fake = await PublicationRangeFixture.start();
  final database = File('${root.path}/restart.sqlite');
  try {
    final (id, verified) = await _writeRangesBeforeRestart(
      root,
      database,
      http,
      fake,
    );
    final db = AppDatabase(database);
    final space = PublicationSpace(
      PublicationStore(db),
      root,
      freeBytes: (_) async => 4 << 30,
    );
    try {
      await space.reconcile();
      final transfer = PublicationTransfer(http, space);
      final partial = transfer.part(id);
      final length = await partial.length();
      final damaged = verified.last;
      final file = await partial.open(mode: FileMode.append);
      try {
        await file.setPosition(damaged);
        await file.writeByte(fake.bytes[damaged] ^ 1);
        await file.flush();
      } finally {
        await file.close();
      }
      expect(await partial.length(), length);
      fake.requests.clear();
      final output = await transfer.download(
        id,
        fake.candidate,
        PublicationDownload(fake.uri),
        CancellationToken(),
        (_, _) async {},
        () {},
      );
      expect(await output.readAsBytes(), equals(fake.bytes));
      for (final start in verified) {
        expect(
          fake.requests.any(
            (range) =>
                range.startsWith('bytes=$start-') && range != 'bytes=0-0',
          ),
          start == damaged,
          reason: 'Range at $start has saved data from the first run',
        );
      }
    } finally {
      await db.close();
    }
  } finally {
    await fake.close();
  }
}

Future<(String, List<int>)> _writeRangesBeforeRestart(
  Directory root,
  File database,
  PublicationHttp http,
  PublicationRangeFixture fixture,
) async {
  final db = AppDatabase(database);
  try {
    final store = PublicationStore(db);
    final transfer = PublicationTransfer(
      http,
      PublicationSpace(store, root, freeBytes: (_) async => 4 << 30),
    );
    final candidate = fixture.candidate;
    final id = await store.addTask(
      const PublicationEdition(id: 'resumable', title: 'Range manual'),
      [candidate],
    );
    final token = CancellationToken();
    await expectLater(
      transfer.download(
        id,
        candidate,
        PublicationDownload(fixture.uri),
        token,
        (received, _) async {
          if (received >= 2 * PublicationTransfer.sliceBytes) token.cancel();
        },
        () {},
      ),
      throwsA(isA<RequestCancelled>()),
    );
    final rows = await db.rows(
      'SELECT start FROM publication_ranges WHERE task=? ORDER BY start',
      [id],
    );
    expect(rows.length, greaterThanOrEqualTo(2));
    return (id, [for (final row in rows) row['start'] as int]);
  } finally {
    await db.close();
  }
}

Future<void> _fallback(PublicationTransfer transfer) async {
  final fake = await PublicationRangeFixture.start(wrongRange: true);
  try {
    final output = await transfer.download(
      publicationId('fallback'),
      fake.candidate,
      PublicationDownload(fake.uri),
      CancellationToken(),
      (_, _) async {},
      () {},
    );
    expect(fake.requests, contains('all'));
    expect(await output.readAsBytes(), equals(fake.bytes));
  } finally {
    await fake.close();
  }
}

Future<void> _completeOnRangeRejection(PublicationTransfer transfer) async {
  final fixture = await PublicationRangeFixture.start();
  addTearDown(fixture.close);
  final id = publicationId('completed before reopening');
  Future<File> download() => transfer.download(
    id,
    fixture.candidate,
    PublicationDownload(fixture.uri),
    CancellationToken(),
    (_, _) async {},
    () {},
  );

  final part = await download();
  fixture.unsatisfiedRanges['bytes=0-0'] = fixture.bytes.length;
  fixture.requests.clear();
  expect(await (await download()).readAsBytes(), fixture.bytes);
  expect(fixture.requests, ['bytes=0-0']);

  final blocker = publicationId('space held by another task');
  await transfer.space.reserve(blocker, 56 << 20, used: 56 << 20);
  await transfer.space.setLimit(64 << 20);
  fixture.requests.clear();
  await expectLater(
    download(),
    throwsA(
      isA<PublicationFailure>().having(
        (failure) => failure.problem,
        'problem',
        PublicationProblem.space,
      ),
    ),
  );
  expect(fixture.requests, ['bytes=0-0']);
  expect(await part.readAsBytes(), fixture.bytes);
  await transfer.space.release(blocker);

  final handle = await part.open(mode: FileMode.append);
  try {
    final offset = PublicationTransfer.sliceBytes;
    await handle.setPosition(offset);
    await handle.writeByte(fixture.bytes[offset] ^ 1);
    await handle.flush();
  } finally {
    await handle.close();
  }
  fixture.requests.clear();
  expect(await (await download()).readAsBytes(), fixture.bytes);
  expect(fixture.requests, ['bytes=0-0', 'all']);
}

Future<void> _changedLengthOnRangeRejection(
  PublicationTransfer transfer,
) async {
  final fixture = await PublicationRangeFixture.start();
  addTearDown(fixture.close);
  fixture.unsatisfiedRanges['bytes=0-4194303'] = fixture.bytes.length + 1;
  await expectLater(
    transfer.download(
      publicationId('changed range total'),
      fixture.candidate,
      PublicationDownload(fixture.uri),
      CancellationToken(),
      (_, _) async {},
      () {},
    ),
    throwsA(
      isA<PublicationFailure>().having(
        (failure) => failure.problem,
        'problem',
        PublicationProblem.invalid,
      ),
    ),
  );
  expect(fixture.requests, isNot(contains('all')));
}

Future<void> _changedWhole(PublicationTransfer transfer) async {
  final fixture = await PublicationRangeFixture.start(
    wrongRange: true,
    changedWhole: true,
  );
  try {
    await expectLater(
      transfer.download(
        publicationId('different fallback'),
        fixture.candidate,
        PublicationDownload(fixture.uri),
        CancellationToken(),
        (_, _) async {},
        () {},
      ),
      throwsA(
        isA<PublicationFailure>().having(
          (failure) => failure.problem,
          'problem',
          PublicationProblem.invalid,
        ),
      ),
    );
    expect(fixture.requests, contains('all'));
  } finally {
    await fixture.close();
  }
}

Future<void> _singleRetry(PublicationTransfer transfer) async {
  final fixture = await PublicationRangeFixture.start();
  try {
    final file = await transfer.download(
      publicationId('single retry'),
      fixture.candidate,
      PublicationDownload(fixture.uri),
      CancellationToken(),
      (_, _) async {},
      () {},
      allowRanges: false,
    );
    expect(fixture.requests, ['all']);
    expect(await file.readAsBytes(), equals(fixture.bytes));
  } finally {
    await fixture.close();
  }
}

Future<void> _extractZip(Directory root) async {
  final pdf = samplePdf();
  final zip = File('${root.path}/fixture.zip');
  final archive = Archive()
    ..addFile(ArchiveFile.bytes('reading/Book.pdf', pdf));
  await zip.writeAsBytes(ZipEncoder().encode(archive));
  final entries = await PublicationZip.inspect(zip);
  expect(entries.single.path, 'reading/Book.pdf');
  final output = File('${root.path}/out.pdf');
  await PublicationZip.extract(
    zip,
    entries.single,
    output,
    CancellationToken(),
  );
  expect(await output.readAsBytes(), equals(pdf));
  await zip.writeAsBytes(
    ZipEncoder().encode(
      archive..addFile(ArchiveFile.bytes('../escape.pdf', pdf)),
    ),
  );
  await expectLater(
    PublicationZip.inspect(zip),
    throwsA(isA<PublicationFailure>()),
  );
}
