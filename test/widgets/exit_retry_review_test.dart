import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zero_player/app/app_back_dispatcher.dart';
import 'package:zero_player/core/platform/platform_services.dart';

void main() {
  testWidgets('failed exit can be confirmed again', (tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('Home')),
        ),
      ],
    );
    var attempts = 0, exits = 0;
    final dispatcher = AppBackDispatcher(
      router: router,
      platform: PlatformServices(),
      closeDrawer: () => false,
      shutdown: () async {
        if (++attempts == 1) throw StateError('close failed');
      },
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.pop') exits++;
        return null;
      },
    );
    try {
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      for (var i = 0; i < 2; i++) {
        final exit = dispatcher.confirmExit();
        await tester.pumpAndSettle();
        expect(find.text('退出 Zero Player？'), findsOneWidget);
        await tester.tap(find.text('退出'));
        await tester.pumpAndSettle();
        await exit;
        if (i == 0) expect(tester.takeException(), isA<StateError>());
      }
      expect(attempts, 2);
      expect(exits, 1);
    } finally {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
    }
  });
}
