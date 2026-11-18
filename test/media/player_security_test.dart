import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/media/engine/player_security.dart';

void main() {
  test(
    'a transient native write failure retries every safety property',
    () async {
      final values = <String, String>{};
      final writes = <String>[];
      var fail = true;
      final security = PlayerSecurity(
        setProperty: (key, value) async {
          writes.add(key);
          if (key == 'config' && fail) throw StateError('native unavailable');
          values['options/$key'] = value;
        },
        getProperty: (key) async => values[key]!,
      );
      await expectLater(security.ensureReady(), throwsStateError);
      fail = false;
      await security.ensureReady();
      expect(writes.where((key) => key == 'load-scripts').length, 2);
      expect(values['options/access-references'], 'no');
      final count = writes.length;
      await security.ensureReady();
      expect(writes.length, count);
    },
  );
  test(
    'concurrent verification shares failure and retries readback mismatch',
    () async {
      final gate = Completer<void>();
      var writes = 0;
      var verified = false;
      final security = PlayerSecurity(
        setProperty: (_, _) async {
          writes++;
          await gate.future;
        },
        getProperty: (_) async => verified ? 'no' : 'yes',
      );
      final first = expectLater(security.ensureReady(), throwsStateError);
      final second = expectLater(security.ensureReady(), throwsStateError);
      expect(writes, 1);
      gate.complete();
      await Future.wait([first, second]);
      verified = true;
      await security.ensureReady();
      expect(writes, 8);
    },
  );
  test(
    'network timeout mismatch blocks readiness and can be retried',
    () async {
      final properties = <String, String>{};
      var mismatch = true;
      final security = PlayerSecurity(
        networkTimeout: const Duration(seconds: 90),
        setProperty: (key, value) async {
          properties['options/$key'] = value;
        },
        getProperty: (key) async => key == 'options/network-timeout' && mismatch
            ? '5'
            : properties[key]!,
      );
      await expectLater(security.ensureReady(), throwsStateError);
      mismatch = false;
      await security.ensureReady();
      expect(properties['options/network-timeout'], '60');
    },
  );
}
