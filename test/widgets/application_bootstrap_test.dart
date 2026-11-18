import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/app/application_bootstrap.dart';
import 'package:zero_player/app/startup_failure.dart';
import 'package:zero_player/core/persistence/app_database.dart';

void main() {
  _disposalTests();
  testWidgets('repeated taps and a retained old button start only one retry', (
    tester,
  ) async {
    var attempts = 0;
    final retry = Completer<AppServices>();
    await tester.pumpWidget(
      ApplicationBootstrap(
        createServices: () {
          attempts++;
          return attempts == 1
              ? Future.error(StateError('disk'))
              : retry.future;
        },
      ),
    );
    await tester.pumpAndSettle();
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    button.onPressed!();
    button.onPressed!();
    expect(attempts, 2);
    await tester.pump();
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    retry.completeError(StateError('still unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(attempts, 3);
  });
  testWidgets('unsafe startup cleanup asks for process restart without retry', (
    tester,
  ) async {
    var exits = 0;
    await tester.pumpWidget(
      ApplicationBootstrap(
        exitApplication: () async {
          exits++;
        },
        createServices: () async {
          throw const ApplicationRestartRequired();
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('完全退出'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expect(find.text('退出'), findsOneWidget);
    await tester.tap(find.text('退出'));
    expect(exits, 1);
  });
}

void _disposalTests() {
  testWidgets('late successful startup is closed after bootstrap disposal', (
    tester,
  ) async {
    final pending = Completer<AppServices>();
    late Directory root;
    late AppServices services;
    var closed = false;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('bootstrap-disposal-');
      services = AppServices.scoped(root, AppDatabase.memory());
      services.addCloseHook(() async {
        closed = true;
      });
    });
    await tester.pumpWidget(
      ApplicationBootstrap(createServices: () => pending.future),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(services);
    await tester.pump();
    for (var i = 0; i < 200 && !closed; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(closed, isTrue);
    var finished = false;
    unawaited(
      services.close().then((_) {
        finished = true;
      }),
    );
    for (var i = 0; i < 200 && !finished; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(finished, isTrue);
    await tester.runAsync(() => root.delete(recursive: true));
    await tester.pump();
    expect(closed, isTrue);
    expect(tester.takeException(), isNull);
  });
}
