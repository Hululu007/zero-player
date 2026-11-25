import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/publications/domain/acquisition_task.dart';
import 'package:zero_player/features/publications/domain/publication.dart';
import 'package:zero_player/features/publications/presentation/publication_management_view.dart';

void main() {
  testWidgets('policy-hidden entries have their own empty state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PublicationShelfView(
            entries: const [],
            hiddenCount: 5,
            open: (_) {},
            action: (_, _) {},
            onLocal: () {},
            onLegacy: () {},
            onUnlisted: () {},
            exportBackup: () {},
            restoreBackup: () {},
            groups: const [],
            onGroups: () {},
            onLists: () {},
          ),
        ),
      ),
    );
    expect(find.text('当前内容策略隐藏了 5 本图书'), findsOneWidget);
    expect(find.text('书库还没有图书'), findsNothing);
  });

  testWidgets(
    'guest-limited downloads expose the browser action in the task row',
    (tester) async {
      final task = AcquisitionTask(
        id: 'visitor-limit',
        edition: const PublicationEdition(
          id: 'guide',
          title: 'Reference Guide',
        ),
        candidates: [
          AcquisitionCandidate(
            source: 'manual',
            link: Uri.https('pan.quark.cn', '/s/testbook'),
            format: PublicationFormat.zip,
            fileId: '0:testfile',
          ),
        ],
        state: AcquisitionState.failed,
        problem: PublicationProblem.guestLimit,
      );
      final actions = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PublicationTasksView(
              tasks: [task],
              action: (_, action) => actions.add(action),
            ),
          ),
        ),
      );
      expect(
        find.textContaining(PublicationProblem.guestLimit.label),
        findsOneWidget,
      );
      expect(find.text('重试'), findsOneWidget);
      await tester.tap(find.text('打开网盘'));
      expect(actions, ['browser']);
    },
  );

  testWidgets('task details show the retry date for a failed candidate', (
    tester,
  ) async {
    final task = AcquisitionTask(
      id: 'retry-fixture',
      edition: const PublicationEdition(id: 'guide', title: 'Reference Guide'),
      candidates: [
        AcquisitionCandidate(
          source: 'manual',
          link: Uri.https('catalog.example', '/guide.pdf'),
          format: PublicationFormat.pdf,
        ),
      ],
      state: AcquisitionState.downloaded,
      failures: [
        (
          candidate: 0,
          problem: PublicationProblem.rateLimit,
          at: DateTime(2026, 11, 21, 12),
          retryAt: DateTime(2026, 11, 21, 12, 2),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PublicationTasksView(tasks: [task], action: (_, _) {}),
        ),
      ),
    );
    await tester.tap(find.text(task.edition.title));
    await tester.pumpAndSettle();
    expect(
      find.text('2026-11-21 12:00:00\n可重试时间 2026-11-21 12:02:00'),
      findsOneWidget,
    );
  });
}
