import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/request_trace.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/publications/data/publication_transfer.dart';
import 'package:zero_player/features/publications/domain/acquisition_task.dart';
import 'package:zero_player/features/publications/presentation/publications_page.dart';

const _profile = String.fromEnvironment('PUBLICATION_AUTHOR_RESUME_HOME');
const _title = 'Making Games with Python & Pygame';
const _digest =
    'da538577ef5be12f10fdaf4e2cc8f6fed1eb2826ff8181a8d094911fc9d9ef18';
const _tail = 368980;
const _length = 4563284;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'a paused publisher transfer resumes from its verified tail',
    _resume,
    skip: !Platform.isWindows || _profile.isEmpty,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Future<void> _resume(WidgetTester tester) async {
  final root = Directory(_profile);
  final dbFile = File('${root.path}/zero-player.sqlite');
  expect(
    root.uri.pathSegments.where(
      (part) => part.startsWith('author-resume-profile-'),
    ),
    hasLength(1),
  );
  expect(await dbFile.exists(), isTrue);
  final services = AppServices.scoped(root, AppDatabase(dbFile));
  try {
    await services.supervision.load();
    await services.settings.load();
    final module = services.publications;
    await module.workflow.initialize();
    final task = (await module.store.tasks()).single;
    expect(task.edition.title, _title);
    expect(task.state, anyOf(AcquisitionState.paused, AcquisitionState.failed));
    expect(task.received, _tail);
    expect(task.total, _length);
    for (final item in await module.discovery.sources()) {
      if (item.enabled && item.source.id != task.candidate.source) {
        await module.discovery.setEnabled(item.source, false);
      }
    }

    final requests = <Map<String, Object?>>[];
    final transferTime = Stopwatch()..start();
    final downloaded =
        await traceRequests(requests, () async {
          await module.workflow.start(task.id);
          return _awaitDownload(services, task);
        }).whenComplete(() async {
          await File(
            '${root.path}/transfer-trace.json',
          ).writeAsString(jsonEncode(requests));
        });
    final elapsedMs = transferTime.elapsedMilliseconds;
    final ranges = [
      for (final item in requests)
        if ((item['url'] as String).startsWith('https://inventwithpython.com/'))
          ((item['requestHeaders'] as Map)['range'], item['status']),
    ];
    debugPrint('Author transfer requests $ranges');
    expect(ranges, contains(('bytes=0-4194303', 206)));
    expect(
      ranges.every(
        (item) => const {'bytes=0-0', 'bytes=0-4194303'}.contains(item.$1),
      ),
      isTrue,
    );
    expect(downloaded.received, _length);
    final part = module.workflow.transfer.part(task.id);
    final digest = await publicationFileDigest(part, CancellationToken());
    expect(digest, _digest);
    await module.workflow.finish(downloaded);
    expect(
      (await module.store.task(task.id))?.state,
      AcquisitionState.complete,
    );
    await _openFromShelf(tester, services);

    final proof = {
      'bytes': downloaded.received,
      'sha256': digest,
      'retainedTailBytes': _tail,
      'elapsedMs': elapsedMs,
      'reopenedPage': '1 / 365',
      'requests': requests,
    };
    await File(
      '${root.path}/resume-proof.json',
    ).writeAsString(jsonEncode(proof));
    debugPrint(
      'Author PDF resumed $_length bytes $digest elapsedMs=$elapsedMs',
    );
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await services.close();
  }
}

Future<AcquisitionTask> _awaitDownload(
  AppServices services,
  AcquisitionTask before,
) async {
  final watch = Stopwatch()..start();
  var lastReport = -15;
  while (watch.elapsed < const Duration(minutes: 8)) {
    final task = (await services.publications.store.task(before.id))!;
    final seconds = watch.elapsed.inSeconds;
    if (seconds >= lastReport + 15) {
      debugPrint(
        'Author transfer ${task.state.name} ${task.received}/${task.total}',
      );
      lastReport = seconds;
    }
    if (task.state == AcquisitionState.downloaded) return task;
    if (task.generation > before.generation &&
        (task.state == AcquisitionState.failed ||
            task.state == AcquisitionState.paused)) {
      throw StateError(
        'Author transfer ${task.state.name}: ${task.problem?.name}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw StateError('Author transfer exceeded the acceptance window');
}

Future<void> _openFromShelf(WidgetTester tester, AppServices services) async {
  final discovery = services.publications.discovery;
  final source = await discovery.enabledSource('open-textbooks');
  if (source != null) await discovery.check(source);
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
  final shelf = find.text('书库');
  await _visible(tester, shelf);
  await tester.tap(shelf);
  final book = find.text(_title);
  await _visible(tester, book);
  await tester.tap(book);
  await _visible(tester, find.text('1 / 365'));
}

Future<void> _visible(WidgetTester tester, Finder item) async {
  final watch = Stopwatch()..start();
  while (item.evaluate().isEmpty && watch.elapsed.inSeconds < 25) {
    await tester.pump(const Duration(milliseconds: 80));
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  expect(item, findsOneWidget);
}
