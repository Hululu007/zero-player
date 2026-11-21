import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/features/publications/presentation/publications_page.dart';

import 'publication_catalogue_fixture.dart';

Future<void> verifyPublicationSourceMaintenance(
  WidgetTester tester,
  AppServices services,
  PublicationCatalogueFixture fixture,
) async {
  final discovery = services.publications.discovery;
  for (final item in (await discovery.sources()).where((e) => e.enabled)) {
    await discovery.setEnabled(item.source, false);
  }
  await discovery.saveConfig(
    PublicationCatalogueFixture.configuration('/health'),
  );
  final source = (await discovery.sources())
      .singleWhere((item) => item.source.configurable)
      .source;
  await discovery.setEnabled(source, true);
  await discovery.setFavorite(source, true);
  await discovery.check(source);

  final visible = ValueNotifier(true);
  try {
    await tester.pumpWidget(
      ValueListenableBuilder<bool>(
        valueListenable: visible,
        builder: (_, value, _) => MaterialApp(
          home: Scaffold(
            body: PublicationsPage(
              module: services.publications,
              books: services.books,
              platform: services.platform,
              visible: value,
            ),
          ),
        ),
      ),
    );
    final search = find.byTooltip('搜索图书');
    final book = find.text('Reference health');
    await _waitForControl(tester, search);
    await tester.tap(search);
    await _waitForControl(tester, book);

    visible.value = false;
    await tester.pumpAndSettle();
    final requests = fixture.requests.length;
    fixture.status = HttpStatus.gone;
    await services.db.write(
      'UPDATE publication_source_settings SET checked=0 WHERE id=?',
      [source.id],
    );
    await tester.pumpAndSettle();
    expect(fixture.requests, hasLength(requests));

    visible.value = true;
    final reason = find.text('Catalogue已暂停检索 · 书源入口已失效');
    await _waitForControl(tester, reason);
    expect(fixture.requests, hasLength(requests + 1));
    expect(book, findsNothing);

    await tester.tap(find.text('书源'));
    await tester.pumpAndSettle();
    final check = find.text('检查或更新');
    final status = find.text('已暂停检索 · 书源入口已失效');
    expect(status, findsOneWidget);
    fixture.status = HttpStatus.ok;
    await tester.ensureVisible(check);
    await tester.pumpAndSettle();
    await tester.tap(check.hitTestable());
    await tester.pumpAndSettle();
    expect(status, findsNothing);

    await tester.tap(find.text('发现'));
    await tester.pumpAndSettle();
    await tester.tap(search);
    await _waitForControl(tester, book);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    visible.dispose();
  }
}

Future<void> _waitForControl(WidgetTester tester, Finder control) async {
  final deadline = Stopwatch()..start();
  while (deadline.elapsed < const Duration(seconds: 7) &&
      control.evaluate().isEmpty) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(control, findsOneWidget);
}
