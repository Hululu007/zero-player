import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:zero_player/core/diagnostics/performance_counters.dart';
import 'package:zero_player/features/catalog/domain/catalog_item.dart';
import 'package:zero_player/features/playback/application/playback_controller.dart';
import 'package:zero_player/features/playback/domain/player_engine.dart';
import 'package:zero_player/features/playback/presentation/playback_surface.dart';
import 'package:zero_player/features/playback/presentation/player_page.dart';
import '../test_support/native_mark_harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  testWidgets(
    'player page preserves native video through position updates',
    (tester) async {
      final harness = await NativeMarkHarness.create();
      await harness.services.platform.initialize();
      final router = _router(harness);
      final previous = PerformanceCounters.enabled;
      try {
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await nativeWidgetUntil(
          tester,
          () => find.byType(PlaybackSurface).evaluate().isNotEmpty,
        );
        final controller = tester
            .widget<PlaybackSurface>(find.byType(PlaybackSurface))
            .controller;
        await nativeWidgetUntil(
          tester,
          () => controller.state.duration > Duration.zero,
        );
        await controller.engine.pause();
        await nativeWidgetUntil(tester, () => !controller.state.playing);
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(Video), findsOneWidget);
        final element = tester.element(find.byType(Video));
        final video = tester.widget<Video>(find.byType(Video));
        final counts = await _measurePositions(tester, controller);
        expect(identical(element, tester.element(find.byType(Video))), isTrue);
        expect(
          identical(video, tester.widget<Video>(find.byType(Video))),
          isTrue,
        );
        expect(counts['player.video.build'] ?? 0, 0);
        expect(counts['player.video.node'] ?? 0, 0);
        expect(counts['player.page.build'] ?? 0, 0);
        expect(counts['player.surface.build'], greaterThanOrEqualTo(30));
        expect(counts['player.transport.build'], greaterThanOrEqualTo(30));
        final evidence = {
          'scenario': 'native-player-page-30ticks',
          'mode': kProfileMode ? 'profile' : (kReleaseMode ? 'release' : 'debug'),
          'counts': counts,
        };
        stdout.writeln(jsonEncode(evidence));
        await File(
          '$fixtureProject/build/performance-implementation-20261118/player-page-workload.json',
        ).writeAsString(jsonEncode(evidence));
        await _checkBlocking(tester, controller);
        await _checkError(tester, controller);
        await _checkOptions(tester);
        await tester.tap(find.byTooltip('返回'));
        await nativeWidgetUntil(
          tester,
          () => find.text('已返回').evaluate().isNotEmpty,
        );
        expect(tester.takeException(), isNull);
      } finally {
        PerformanceCounters.enabled = previous;
        PerformanceCounters.reset();
        await harness.services.close();
        await harness.close(tester);
        router.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

GoRouter _router(NativeMarkHarness harness) {
  final request = PlaybackRequest(
    CatalogItem(
      sourceId: 'test-source',
      id: 'long.mp4',
      title: '性能受控夹具',
      lines: [
        PlayLine('main', [
          Episode(
            '1',
            Uri.parse('http://127.0.0.1:${harness.server.port}/long.mp4'),
          ),
        ]),
      ],
    ),
  );
  return GoRouter(
    initialLocation: '/player',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: Text('已返回')),
      ),
      GoRoute(
        path: '/player',
        builder: (_, _) =>
            PlayerPage(services: harness.services, request: request),
      ),
    ],
  );
}

Future<Map<String, int>> _measurePositions(
  WidgetTester tester,
  PlaybackController controller,
) async {
  final duration = controller.state.duration;
  PerformanceCounters.enabled = true;
  PerformanceCounters.reset();
  for (var i = 0; i < 30; i++) {
    controller.state = PlaybackSnapshot(
      position: Duration(seconds: i),
      duration: duration,
    );
    // Deliver the existing business notification without timing native events.
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    controller.notifyListeners();
    await tester.pump();
  }
  return PerformanceCounters.snapshot();
}

Future<void> _checkBlocking(
  WidgetTester tester,
  PlaybackController controller,
) async {
  controller.blocked = true;
  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  controller.notifyListeners();
  await tester.pump();
  expect(find.byType(Video), findsNothing);
  expect(find.text('内容已屏蔽'), findsOneWidget);
  controller.blocked = false;
  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  controller.notifyListeners();
  await tester.pump();
  expect(find.byType(Video), findsOneWidget);
}

Future<void> _checkOptions(WidgetTester tester) async {
  await tester.ensureVisible(find.byTooltip('画面比例'));
  await tester.tap(find.byTooltip('画面比例'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('填充 · 裁切边缘'));
  await tester.pumpAndSettle();
  expect(tester.widget<Video>(find.byType(Video)).fit, BoxFit.cover);
  await tester.ensureVisible(find.byTooltip('全屏 (F)'));
  await tester.tap(find.byTooltip('全屏 (F)'));
  await tester.pumpAndSettle();
  expect(find.byTooltip('退出全屏 (F)'), findsOneWidget);
  await tester.tap(find.byTooltip('退出全屏 (F)'));
  await tester.pumpAndSettle();
  expect(find.byTooltip('全屏 (F)'), findsOneWidget);
}

Future<void> _checkError(
  WidgetTester tester,
  PlaybackController controller,
) async {
  controller.error = '受控失败回归';
  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  controller.notifyListeners();
  await tester.pump();
  expect(find.text('受控失败回归'), findsOneWidget);
  expect(find.text('重试'), findsOneWidget);
  controller.error = null;
  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  controller.notifyListeners();
  await tester.pump();
  expect(find.text('受控失败回归'), findsNothing);
}
