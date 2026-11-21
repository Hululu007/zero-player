import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/publications/domain/acquisition_task.dart';
import 'package:zero_player/features/publications/domain/publication.dart';
import 'package:zero_player/features/publications/presentation/publication_management_view.dart';

void main() {
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
