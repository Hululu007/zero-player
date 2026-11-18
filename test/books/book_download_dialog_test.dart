import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/books/presentation/book_download_dialog.dart';

void main() {
  testWidgets('latest aggregation belongs to full-book text downloads', (
    tester,
  ) async {
    BookDownloadPlan? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              chosen = await showBookDownloadDialog(context, 30);
            },
            child: const Text('下载'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();
    expect(find.text('全本'), findsOneWidget);
    await tester.tap(find.text('聚合最新'));
    await tester.tap(find.text('指定区间'));
    await tester.pumpAndSettle();
    expect(find.text('聚合最新'), findsNothing);
    await tester.tap(find.text('全本'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始下载'));
    await tester.pumpAndSettle();
    expect(chosen!.fullBook, isTrue);
    expect(chosen!.aggregateLatest, isTrue);
    expect(chosen!.last, 30);
  });

  testWidgets('non-text downloads do not expose latest aggregation', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showBookDownloadDialog(
              context,
              10,
              allowAggregateLatest: false,
            ),
            child: const Text('下载'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();
    expect(find.text('聚合最新'), findsNothing);
    expect(find.text('全本'), findsOneWidget);
  });
}
