import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/persistence/installation_metadata.dart';
import 'package:zero_player/features/books/application/book_site_checks.dart';
import 'package:zero_player/features/books/data/aoaostar_book_catalog.dart';
import 'package:zero_player/features/books/data/book_site_inspection.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/book_sources_page.dart';

void main() {
  _quarantineReviewPageTests();
  _sourceListPolicyRaceTests();
  _ruleCluePageTests();
}

void _ruleCluePageTests() {
  testWidgets(
    'dynamic rule clues can be filtered without hiding other sources',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      late Directory root;
      late AppServices services;
      final ordinary = _source('普通规则源', 'ordinary.example');
      final historical = _source('历史规则源', 'm.nshkedu.com');
      final dynamicSource = BookSource.fromJson({
        ..._source('动态规则源', 'dynamic.example').toJson(),
        'legado': {
          'rules': {'content': '@js: eval(result)'},
        },
      });
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('book-rule-clue-ui-');
        services = AppServices.scoped(root, AppDatabase.memory());
        await services.supervision.load();
        await services.settings.load();
        await _skipCatalogSeed(services);
        await services.books.importSources([
          ordinary,
          dynamicSource,
          historical,
        ]);
      });
      addTearDown(() => _close(tester, services, root));
      await tester.pumpWidget(
        MaterialApp(
          home: BookSourcesPage(services: services, kind: BookKind.text),
        ),
      );
      await tester.enterText(find.byType(TextField).first, '规则源');
      await _waitFor(tester, () => find.text('动态规则源').evaluate().isNotEmpty);
      expect(find.textContaining('规则含动态求值，待复核'), findsOneWidget);
      expect(find.text('普通规则源'), findsOneWidget);
      await tester.tap(find.text('动态求值'));
      await tester.pump();
      expect(find.text('动态规则源'), findsOneWidget);
      expect(find.text('普通规则源'), findsNothing);
      await tester.tap(find.text('动态求值'));
      await tester.pump();
      expect(find.text('普通规则源'), findsOneWidget);
      expect(find.textContaining('2026-11-15 首页防护检出，待复核'), findsOneWidget);
      await tester.tap(find.text('历史检出'));
      await tester.pump();
      expect(find.text('历史规则源'), findsOneWidget);
      expect(find.text('普通规则源'), findsNothing);
      await tester.tap(find.text('历史检出'));
      await tester.pump();
      expect(find.text('普通规则源'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

void _quarantineReviewPageTests() {
  testWidgets(
    'small source page presents samples and allows reviewing quarantine',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      late Directory root;
      late AppServices services;
      final shown = _source('样本抽查', 'shown.example');
      final risk = _source('待复核源', 'risk.example');
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('book-site-ui-');
        services = AppServices.scoped(root, AppDatabase.memory());
        await services.supervision.load();
        await services.settings.load();
        await _skipCatalogSeed(services);
        await services.books.importSources([shown, risk]);
        await services.books.saveSource(shown, {'enabled': true});
        await services.books.markSourceRisk(risk, quarantine: true);
        final check = BookSiteCheck(
          const BookSiteInspection(BookSiteFinding.gamblingClue),
          DateTime(2026, 11, 15, 8, 30),
          bookSourceCheckFingerprint(shown),
        );
        await services.books.store.write(
          'books_site_check:${shown.id}',
          check.toJson(),
        );
        await services.books.sources(BookKind.text);
      });
      addTearDown(() => _close(tester, services, root));
      await tester.pumpWidget(
        MaterialApp(
          home: BookSourcesPage(services: services, kind: BookKind.text),
        ),
      );
      await tester.enterText(find.byType(TextField).first, '样本抽查');
      await _waitFor(
        tester,
        () => find.textContaining('网页：疑似博彩文字线索').evaluate().isNotEmpty,
      );
      expect(find.text('网页抽查'), findsOneWidget);
      expect(find.text('风险记录'), findsOneWidget);
      expect(find.textContaining('不验证解析、网页脚本、木马或安全性'), findsOneWidget);
      expect(find.textContaining('未确认结果的重试间隔从 30 分钟递增'), findsOneWidget);
      expect(find.textContaining('网页：疑似博彩文字线索'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('风险记录'));
      await _waitFor(tester, () => find.text('待复核源').evaluate().isNotEmpty);
      expect(find.text('待复核源'), findsOneWidget);
      expect(find.text('人工复核'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('人工复核'));
      await _waitFor(tester, () => find.text('确认解除').evaluate().isNotEmpty);
      expect(find.text('确认解除'), findsOneWidget);
      await tester.tap(find.text('确认解除'));
      await _waitFor(
        tester,
        () => find.textContaining('已解除该条风险记录').evaluate().isNotEmpty,
      );
      await _waitFor(
        tester,
        () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      await tester.enterText(find.byType(TextField).first, '待复核源');
      await _waitFor(
        tester,
        () => find.widgetWithText(ListTile, '待复核源').evaluate().isNotEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

void _sourceListPolicyRaceTests() {
  for (final changePolicy in [true, false]) {
    testWidgets(
      'source list rechecks ${changePolicy ? 'adult filtering' : 'the group'} between reads',
      (tester) async {
        tester.view.physicalSize = const Size(320, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        late Directory root;
        late AppServices services;
        final source = _source('受控分组样本', 'control.example');
        await tester.runAsync(() async {
          root = await Directory.systemTemp.createTemp(
            'book-source-policy-ui-',
          );
          services = AppServices.scoped(root, AppDatabase.memory());
          await services.db.write(
            'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
            [installationAccessKey, upgradedInstallationAccess],
          );
          await services.supervision.load();
          await services.settings.load();
          if (changePolicy) {
            await services.settings.update({'filterAdult': false});
          }
          await _skipCatalogSeed(services);
          await services.books.importSources([source]);
          if (changePolicy) {
            await services.books.saveSource(source, {'group': '肉文'});
          }
        });
        final readStarted = Completer<void>();
        final resume = Completer<void>();
        var held = false;
        addTearDown(() async {
          if (!resume.isCompleted) resume.complete();
          await _close(tester, services, root);
        });
        await tester.pumpWidget(
          MaterialApp(
            home: BookSourcesPage(
              services: services,
              kind: BookKind.text,
              afterSourceReadForTesting: () async {
                if (held) return;
                held = true;
                readStarted.complete();
                await resume.future;
              },
            ),
          ),
        );
        await tester.enterText(find.byType(TextField).first, '受控分组样本');
        await _waitFor(tester, () => readStarted.isCompleted);
        await tester.runAsync(() async {
          if (changePolicy) {
            await services.settings.update({'filterAdult': true});
          } else {
            await services.books.saveSource(source, {'group': '肉文'});
          }
        });
        resume.complete();
        for (var i = 0; i < 400; i++) {
          await tester.pump(const Duration(milliseconds: 10));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          expect(find.widgetWithText(ListTile, '受控分组样本'), findsNothing);
          if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
        }
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(find.text('没有符合条件的来源'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<void> _skipCatalogSeed(AppServices services) async {
  final revision = (await AoaoStarBookCatalog.load()).revision;
  final filter = services.contentPolicy.filterAdult ? 'filtered' : 'all';
  await services.books.store.write(
    'books_catalog_revision',
    '$revision:adult-$filter:2',
  );
}

Future<void> _waitFor(WidgetTester tester, bool Function() complete) async {
  for (var i = 0; i < 400 && !complete(); i++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(complete(), isTrue, reason: '页面应在完成本地异步操作后更新');
}

Future<void> _close(
  WidgetTester tester,
  AppServices services,
  Directory root,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  var closed = false;
  Object? failure;
  final closing = services.close().then(
    (_) => closed = true,
    onError: (Object error) {
      failure = error;
      closed = true;
      return true;
    },
  );
  for (var i = 0; i < 400 && !closed; i++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(closed, isTrue, reason: '应用资源应完成关闭');
  await closing;
  if (failure != null) throw failure!;
  await tester.runAsync(() => root.delete(recursive: true));
}

BookSource _source(String name, String host) => BookSource.fromJson({
  'name': name,
  'kind': 'text',
  'format': 'feed',
  'url': 'https://$host/feed',
});
