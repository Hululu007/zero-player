import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/features/publications/data/publication_transfer.dart';
import 'package:zero_player/features/publications/domain/acquisition_task.dart';
import 'package:zero_player/features/publications/domain/publication.dart';
import 'package:zero_player/features/publications/presentation/publication_management_view.dart';
import 'package:zero_player/features/publications/presentation/publications_page.dart';

import 'local_book_fixtures.dart';
import 'publication_range_fixture.dart';

Future<void> verifyPublicationCapacityFlow(
  WidgetTester tester,
  AppServices services,
) async {
  final source = await PublicationRangeFixture.start();
  final module = services.publications;
  final other = publicationId('active capacity reservation');
  try {
    await module.workflow.initialize();
    await module.space.setLimit(80 << 20);
    final book = await File(
      '${services.root.path}/Protected.pdf',
    ).writeAsBytes(samplePdf());
    await module.workflow.importLocal(book);
    await module.space.reserve(other, 66 << 20);
    await module.space.setLimit(64 << 20);
    final id = await module.workflow.add(
      PublicationEdition(
        id: publicationId('capacity-range-fixture'),
        title: 'Capacity range fixture',
        candidates: [source.candidate],
      ),
      PublicationFormat.pdf,
    );
    final waiting = await _taskWhen(
      services,
      id,
      (task) => task.problem != null,
    );
    expect(waiting.state, AcquisitionState.waiting);
    expect(waiting.problem, PublicationProblem.space);
    expect(waiting.failures, isEmpty);
    expect(source.requests, ['bytes=0-0']);
    expect(await module.workflow.transfer.part(id).exists(), isFalse);
    expect(waiting.spaceShortfall, (
      requiredBytes: source.bytes.length,
      availableBytes: 0,
      protectedBytes: await book.length(),
    ));
    await _showCapacity(tester, services, waiting);
    await module.space.release(other);
    source.requests.clear();
    await module.workflow.start(id);
    final result = await _taskWhen(
      services,
      id,
      (task) => task.state == AcquisitionState.downloaded,
    );
    expect(result.spaceShortfall, isNull);
    expect(
      source.requests,
      unorderedEquals([
        'bytes=0-0',
        'bytes=0-4194303',
        'bytes=4194304-8388607',
        'bytes=8388608-9437183',
      ]),
    );
    expect(
      await publicationFileDigest(
        module.workflow.transfer.part(id),
        CancellationToken(),
      ),
      sha256.convert(source.bytes).toString(),
    );
    expect((await module.library.holdings()).single.resident, isTrue);
    debugPrint(
      'Publication capacity waiting, overage, protected occupancy and complete range digest verified',
    );
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await source.close();
  }
}

Future<void> _showCapacity(
  WidgetTester tester,
  AppServices services,
  AcquisitionTask waiting,
) async {
  final usage = await services.publications.space.usage();
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
  await _visible(tester, find.text('任务'));
  await tester.tap(find.text('任务'));
  await _visible(tester, find.text('PDF · 等待存储空间'));
  expect(
    find.text(publicationSpaceDetails(waiting.spaceShortfall!)),
    findsOneWidget,
  );
  await tester.tap(find.text('书源'));
  await _visible(
    tester,
    find.textContaining(
      '超出托管上限 ${publicationSize(usage.used + usage.reserved - usage.limit)}',
    ),
  );
  await tester.pumpWidget(const SizedBox.shrink());
}

Future<void> _visible(WidgetTester tester, Finder finder) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(finder, findsOneWidget);
}

Future<AcquisitionTask> _taskWhen(
  AppServices services,
  String id,
  bool Function(AcquisitionTask) ready,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 38));
  AcquisitionTask? task;
  while (DateTime.now().isBefore(deadline)) {
    task = await services.publications.store.task(id);
    if (task != null && ready(task)) return task;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError(
    'Capacity fixture task stopped at ${task?.state} with ${task?.problem}',
  );
}
