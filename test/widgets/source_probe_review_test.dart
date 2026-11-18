import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/sources/presentation/source_actions.dart';
import 'package:zero_player/features/sources/presentation/source_probe_dialog.dart';
import '../../test_support/http_test_server.dart';

void main() {
  testWidgets(
    'manual probe owns its progress while the shared monitor is busy',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('probe-review-'),
      ))!;
      final server = (await tester.runAsync(
        () => HttpTestServer.start((request) {
          request.response.write('{"list":[],"info":{"site_name":"Manual"}}');
        }),
      ))!;
      final services = (await tester.runAsync(
        () async => AppServices.scoped(
          root,
          AppDatabase.memory(),
          allowPrivateNetworks: true,
        ),
      ))!;
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await services.settings.load();
          await services.supervision.load();
          await services.sources.saveManual(
            'Manual',
            server.baseUri.resolve('api'),
          );
          services.sourceProbe.running = true;
          services.sourceProbe.total = 9;
          services.sourceProbe.statuses['background'] = 'Background progress';
        }, _RealHttpOverrides()),
      );
      final sources = (await tester.runAsync(services.sources.all))!;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => probeSources(context, services, sources),
                  child: const Text('Probe'),
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(() => tester.tap(find.text('Probe')));
        await tester.pump();
        final dialog = tester.widget<SourceProbeDialog>(
          find.byType(SourceProbeDialog),
        );
        expect(identical(dialog.probe, services.sourceProbe), isFalse);
        for (var i = 0; i < 100 && dialog.probe.running; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(dialog.probe.total, 1);
        expect(dialog.probe.results.keys, contains(sources.single.id));
        expect(
          server.calls.values.fold<int>(0, (a, b) => a + b),
          greaterThan(0),
          reason: dialog.probe.statuses.values.join(' | '),
        );
        expect(services.sourceProbe.total, 9);
        expect(services.sourceProbe.statuses, {
          'background': 'Background progress',
        });
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await services.close();
          await server.close();
          await root.delete(recursive: true);
        });
      }
    },
  );
}

class _RealHttpOverrides extends HttpOverrides {}
