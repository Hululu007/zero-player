import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zero_player/app/shell.dart';
import 'package:zero_player/core/diagnostics/performance_counters.dart';
import 'package:zero_player/features/catalog/domain/catalog_item.dart';
import 'package:zero_player/features/discovery/presentation/discovery_page.dart';
import 'package:zero_player/features/supervision/data/content_records.dart';
import '../../test_support/mobile_app_fixture.dart';

late MobileAppFixture fixture;

void main() {
  setUp(() async {
    fixture = MobileAppFixture();
    await fixture.initialize(mode: 'television');
    await _save(0);
  });
  tearDown(() {
    PerformanceCounters.enabled = false;
    PerformanceCounters.reset();
  });
  _visibilityContracts();
  _raceContracts();
  _failureAndLabelContracts();
  _pendingReadContract();
}

void _pendingReadContract() {
  testWidgets('settled return keeps visible history during ordinary refresh', (
    tester,
  ) async {
    await fixture.pump(tester);
    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    router.go('/settings');
    await fixture.settle(tester);
    router.go('/');
    await fixture.settle(tester);
    final entered = Completer<void>();
    final release = Completer<void>();
    late Future<void> held;
    await tester.runAsync(() async {
      held = fixture.services.db.transaction(() async {
        entered.complete();
        await release.future;
      });
    });
    try {
      await fixture.waitFor(tester, () => entered.isCompleted);
      fixture.services.db.changed(tables: {'watch_history'});
      await tester.pump();
      await tester.pump();
      expect(find.text('续播').hitTestable(), findsOneWidget);
    } finally {
      await tester.runAsync(() async {
        release.complete();
      });
      var done = false;
      held.whenComplete(() => done = true);
      await fixture.waitFor(tester, () => done);
    }
    await fixture.settle(tester);
    await fixture.finish(tester);
  });
}

void _failureAndLabelContracts() {
  testWidgets('return read failure hides old history and refresh retries', (
    tester,
  ) async {
    await fixture.pump(tester, size: const Size(1280, 720));
    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    router.go('/settings');
    await fixture.settle(tester);
    await tester.runAsync(
      () => fixture.services.db.customStatement(
        'ALTER TABLE watch_history RENAME TO unavailable_history',
      ),
    );
    router.go('/');
    await fixture.settle(tester);
    expect(find.text('续播').hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.runAsync(
      () => fixture.services.db.customStatement(
        'ALTER TABLE unavailable_history RENAME TO watch_history',
      ),
    );
    await tester.runAsync(
      () => fixture.services.db.customStatement(
        'UPDATE watch_history SET position_ms=27000',
      ),
    );
    await tester.tap(find.byTooltip('刷新推荐'));
    await fixture.settle(tester);
    expect(find.textContaining('00:27'), findsOneWidget);
    expect(find.text('续播').hitTestable(), findsOneWidget);
    await fixture.finish(tester);
  });

  testWidgets('hidden label change is rechecked before history is shown', (
    tester,
  ) async {
    await fixture.pump(tester);
    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    expect(find.text('续播'), findsOneWidget);
    router.go('/settings');
    await fixture.settle(tester);
    PerformanceCounters.enabled = true;
    PerformanceCounters.reset();
    await tester.runAsync(
      () => rememberContent(
        fixture.services.db,
        const CatalogItem(
          sourceId: 'local',
          id: 'test',
          title: '续播',
          tags: '色情',
        ),
      ),
    );
    await fixture.settle(tester);
    expect(
      PerformanceCounters.snapshot()['history.recent_works.calls'] ?? 0,
      0,
    );
    router.go('/');
    await fixture.settle(tester);
    expect(PerformanceCounters.snapshot()['history.recent_works.calls'], 1);
    expect(find.text('续播'), findsNothing);
    expect(tester.takeException(), isNull);
    await fixture.finish(tester);
  });
}

void _visibilityContracts() {
  for (final standalone in [false, true]) {
    testWidgets('hidden discovery coalesces history, standalone=$standalone', (
      tester,
    ) async {
      await fixture.pump(tester, size: const Size(1280, 720));
      final router = GoRouter.of(tester.element(find.byType(AppShell)));
      final scroll = tester
          .widget<CustomScrollView>(
            find.byKey(const ValueKey('discovery-scroll')),
          )
          .controller!;
      final state = tester.state(find.byType(DiscoveryPage));
      final before = scroll.offset;
      if (standalone) {
        router.push('/sources');
      } else {
        router.go('/settings');
      }
      await fixture.settle(tester);
      expect(
        tester
            .widget<DiscoveryPage>(
              find.byType(DiscoveryPage, skipOffstage: false),
            )
            .visible,
        false,
      );
      PerformanceCounters.enabled = true;
      PerformanceCounters.reset();
      for (var i = 1; i <= 20; i++) {
        await tester.runAsync(() => _save(i));
      }
      await fixture.settle(tester);
      expect(
        PerformanceCounters.snapshot()['history.recent_works.calls'] ?? 0,
        0,
      );
      if (standalone) {
        router.pop();
      } else {
        router.go('/');
      }
      await fixture.settle(tester);
      expect(PerformanceCounters.snapshot()['history.recent_works.calls'], 1);
      expect(tester.state(find.byType(DiscoveryPage)), same(state));
      expect(scroll.offset, before);
      expect(find.textContaining('00:20'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focus = FocusManager.instance.primaryFocus;
      await tester.runAsync(() => _save(21));
      await fixture.settle(tester);
      expect(FocusManager.instance.primaryFocus, same(focus));
      expect(scroll.offset, before);
      await fixture.finish(tester);
    });
  }
}

void _raceContracts() {
  testWidgets(
    'rapid leave/return and a hidden policy change show latest data only',
    (tester) async {
      await fixture.pump(tester);
      final router = GoRouter.of(tester.element(find.byType(AppShell)));
      router.go('/settings');
      await fixture.settle(tester);
      await tester.runAsync(() => _save(9));
      router.go('/');
      await tester.pump();
      router.go('/settings');
      await tester.pump();
      await tester.runAsync(() => _save(32));
      fixture.services.contentPolicy.refresh();
      await fixture.settle(tester);
      router.go('/');
      await fixture.settle(tester);
      expect(find.textContaining('00:32'), findsOneWidget);
      expect(find.textContaining('00:09'), findsNothing);
      expect(tester.takeException(), isNull);
      await fixture.finish(tester);
    },
  );
}

Future<void> _save(int second) {
  final episode = Episode('第1集', Uri.parse('https://media.test/a.mp4'));
  final line = PlayLine('线路', [episode]);
  return fixture.services.history.save(
    const CatalogItem(sourceId: 'local', id: 'test', title: '续播'),
    line,
    episode,
    Duration(seconds: second),
    const Duration(minutes: 2),
  );
}
