import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/books/data/book_shelf_lists.dart';
import 'package:zero_player/features/books/presentation/book_download_dialog.dart';

void main() {
  _privateListLoadingTest();
  testWidgets('latest aggregation belongs to full-book text downloads', (
    tester,
  ) async {
    BookDownloadSelection? chosen;
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
    expect(chosen!.plan.fullBook, isTrue);
    expect(chosen!.plan.aggregateLatest, isTrue);
    expect(chosen!.plan.last, 30);
    expect(chosen!.target.space, BookShelfSpace.public);
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

  testWidgets('download can target a private shelf list', (tester) async {
    BookDownloadSelection? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              chosen = await showBookDownloadDialog(
                context,
                8,
                publicLists: const [
                  ShelfList('1', '在追', ShelfListKind.group, {}),
                ],
                privateLists: const [
                  ShelfList('2', '夜深', ShelfListKind.list, {}),
                ],
              );
            },
            child: const Text('下载'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('私密书架'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<String?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('书单 · 夜深').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始下载'));
    await tester.pumpAndSettle();
    expect(chosen!.target.isPrivate, isTrue);
    expect(chosen!.target.listName, '夜深');
  });
}

void _privateListLoadingTest() {
  testWidgets('switching private space loads lists after authentication', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showBookDownloadDialog(
              context,
              8,
              loadPrivateLists: () async {
                calls++;
                return const [
                  ShelfList('private-list', '解锁后书单', ShelfListKind.list, {}),
                ];
              },
            ),
            child: const Text('下载'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('私密书架'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    await tester.tap(find.byType(DropdownButton<String?>));
    await tester.pumpAndSettle();
    expect(find.text('书单 · 解锁后书单'), findsOneWidget);
  });
}
