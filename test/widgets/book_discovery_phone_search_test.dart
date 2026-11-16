import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/book_discovery_view.dart';

import '../../test_support/book_fixture_source.dart';
import '../../test_support/mobile_app_fixture.dart';

void main() {
  testWidgets('phone discovery folds its search box into a pill', (
    tester,
  ) async {
    final fixture = MobileAppFixture();
    await tester.runAsync(fixture.initialize);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 740);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final source = bookFixtureSource('fixture.test');
    await tester.runAsync(
      () => fixture.services.books.importSources([source]),
    );
    final entries = await tester.runAsync(
      () => fixture.services.books.sources(BookKind.text, enabledOnly: true),
    );
    final queries = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookDiscoveryView(
            repository: fixture.services.books,
            kind: BookKind.text,
            sources: entries,
            active: true,
            onOpen: (_, {bool direct = false}) {},
            onSearch: (query, _, _) => queries.add(query),
            onSourceFavorite: (_, _) {},
            onManage: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Phones show a tappable pill instead of an always-visible text field.
    expect(find.byType(TextField), findsNothing);
    expect(find.text('搜书名、作者或书籍链接'), findsOneWidget);

    await tester.tap(find.text('搜书名、作者或书籍链接'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byTooltip('收起搜索框'), findsOneWidget);
    expect(find.byTooltip('返回顶部'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('收起搜索框'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('搜书名、作者或书籍链接'), findsOneWidget);
    expect(queries, isEmpty);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('搜书名、作者或书籍链接'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '星海');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    expect(queries, ['星海']);
    // Submitting folds the box again so the results keep the screen space.
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);

    await fixture.finish(tester);
  });
}
