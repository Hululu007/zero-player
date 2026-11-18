import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/platform/platform_services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'lock freezes orientation and restores the latest preference on unlock',
    () async {
      final calls = <String>[];
      final platform = PlatformServices(
        applyFullscreen: (_, _) async {},
        applyPlayerOrientation: (mode) async => calls.add(mode),
      );
      await platform.setPlayerOrientation('auto');
      await platform.setPlayerOrientationLocked(true);
      await platform.setPlayerOrientation('landscape');
      await platform.setPlayerOrientationLocked(true);
      expect(calls, ['auto', 'locked']);
      await platform.setPlayerOrientationLocked(false);
      expect(calls.last, 'landscape');
      await platform.dispose();
      expect(calls.last, 'system');
    },
  );

  test(
    'pending direction changes and lock are ordered before exit restoration',
    () async {
      final started = Completer<void>(), release = Completer<void>();
      final calls = <String>[];
      final platform = PlatformServices(
        applyFullscreen: (_, _) async {},
        applyPlayerOrientation: (mode) async {
          calls.add(mode);
          if (mode == 'auto') {
            started.complete();
            await release.future;
          }
        },
      );
      final change = platform.setPlayerOrientation('auto');
      await started.future;
      final lock = platform.setPlayerOrientationLocked(true);
      final exit = platform.restorePlayerWindow();
      release.complete();
      await Future.wait([change, lock, exit]);
      expect(calls, ['auto', 'locked', 'system']);
      await platform.dispose();
      expect(calls, ['auto', 'locked', 'system']);
    },
  );

  test('failed lock or unlock leaves a retryable orientation state', () async {
    var fail = true;
    final calls = <String>[];
    final platform = PlatformServices(
      applyFullscreen: (_, _) async {},
      applyPlayerOrientation: (mode) async {
        calls.add(mode);
        if (fail) throw StateError('fixture orientation');
      },
    );
    await expectLater(
      platform.setPlayerOrientationLocked(true),
      throwsStateError,
    );
    fail = false;
    await platform.setPlayerOrientation('auto');
    await platform.setPlayerOrientationLocked(true);
    fail = true;
    await expectLater(
      platform.setPlayerOrientationLocked(false),
      throwsStateError,
    );
    fail = false;
    await platform.setPlayerOrientationLocked(false);
    expect(calls, ['locked', 'auto', 'locked', 'auto', 'auto']);
    await platform.dispose();
  });
}
