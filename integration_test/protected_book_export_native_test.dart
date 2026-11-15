import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/platform/protected_book_export.dart';

const _runSave = bool.fromEnvironment('RUN_ANDROID_SAF_SAVE_TEST');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android system picker closes on cancellation and can reopen',
    (tester) async {
      await tester.pumpWidget(const SizedBox());
      final cache = await getTemporaryDirectory();
      Set<String> ownedStaging() => cache
          .listSync()
          .whereType<Directory>()
          .map((entry) => entry.path)
          .where(
            (path) => path
                .split(Platform.pathSeparator)
                .last
                .startsWith('zero-book-export-'),
          )
          .toSet();
      final before = ownedStaging();
      for (var attempt = 0; attempt < 2; attempt++) {
        final token = CancellationToken();
        final pending = ProtectedBookExport().saveText(
          'ZeroPlayer-SAF-cancel-$attempt.txt',
          'Synthetic test content',
          cancellation: token,
          validate: () {},
        );
        debugPrint('SAF_CANCEL_PICKER_WAITING $attempt');
        await Future<void>.delayed(const Duration(seconds: 6));
        token.cancel();
        await expectLater(
          pending.timeout(const Duration(seconds: 20)),
          throwsA(isA<RequestCancelled>()),
        );
        expect(ownedStaging().difference(before), isEmpty);
      }
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'Android system picker writes a synthetic document',
    (tester) async {
      await tester.pumpWidget(const SizedBox());
      final pending = ProtectedBookExport().saveText(
        'ZeroPlayer-SAF-Audit.txt',
        'Zero Player synthetic SAF export.\n',
        cancellation: CancellationToken(),
        validate: () {},
      );
      debugPrint('SAF_SAVE_PICKER_WAITING');
      await pending.timeout(const Duration(minutes: 2));
      debugPrint('SAF_SAVE_COMPLETED');
    },
    skip: !Platform.isAndroid || !_runSave,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
