import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:zero_player/core/platform/platform_services.dart';
import 'package:zero_player/features/catalog/domain/catalog_item.dart';
import 'package:zero_player/features/playback/application/playback_request.dart';
import 'package:zero_player/features/playback/presentation/playback_surface.dart';
import 'package:zero_player/features/playback/presentation/player_page.dart';
import '../test_support/native_mark_harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  testWidgets(
    'page lock waits for orientation, retries failure and restores on back',
    (tester) async {
      final calls = <String>[];
      final release = Completer<void>();
      var fail = true;
      final platform = PlatformServices(
        applyFullscreen: (_, _) async {},
        applyPlayerOrientation: (mode) async {
          calls.add(mode);
          if (mode == 'locked') {
            if (fail) throw StateError('controlled orientation failure');
            await release.future;
          }
        },
      );
      final harness = await NativeMarkHarness.create(platform: platform);
      await harness.services.settings.update({'playerOrientation': 'auto'});
      final router = _router(harness);
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await nativeWidgetUntil(tester, () => calls.contains('auto'));
        await tester.tap(find.byTooltip('锁定防误触'));
        await nativeWidgetUntil(tester, () => calls.contains('locked'));
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byTooltip('锁定防误触'), findsOneWidget);
        expect(find.text('controlled orientation failure'), findsOneWidget);
        fail = false;
        await tester.tap(find.byTooltip('锁定防误触'));
        await nativeWidgetUntil(
          tester,
          () => calls.where((m) => m == 'locked').length == 2,
        );
        final surface = tester.widget<PlaybackSurface>(
          find.byType(PlaybackSurface),
        );
        surface.onBack();
        await tester.pump(const Duration(milliseconds: 100));
        expect(surface.locked, isFalse);
        release.complete();
        await nativeWidgetUntil(tester, () => calls.last == 'auto');
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byType(PlayerPage), findsOneWidget);
        expect(find.byTooltip('锁定防误触'), findsOneWidget);
        await tester.tap(find.byTooltip('返回'));
        await nativeWidgetUntil(
          tester,
          () => find.text('已返回').evaluate().isNotEmpty,
        );
        expect(calls, ['auto', 'locked', 'locked', 'auto', 'system']);
        expect(tester.takeException(), isNull);
      } finally {
        if (!release.isCompleted) release.complete();
        debugDefaultTargetPlatformOverride = null;
        await harness.close(tester);
        router.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

GoRouter _router(NativeMarkHarness harness) => GoRouter(
  initialLocation: '/player',
  routes: [
    GoRoute(
      path: '/',
      builder: (_, _) => const Scaffold(body: Text('已返回')),
    ),
    GoRoute(
      path: '/player',
      builder: (_, _) => PlayerPage(
        services: harness.services,
        request: PlaybackRequest(
          CatalogItem(
            sourceId: 'test-source',
            id: 'long.mp4',
            title: '锁定方向回归',
            lines: [
              PlayLine('main', [
                Episode(
                  '1',
                  Uri.parse('http://127.0.0.1:${harness.server.port}/long.mp4'),
                ),
              ]),
            ],
          ),
        ),
      ),
    ),
  ],
);
