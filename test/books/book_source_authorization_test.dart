import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/supervision/application/supervision_controller.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('queued source edits recheck a revoked channels grant', () async {
    final root = await Directory.systemTemp.createTemp('book-auth-race-');
    final services = AppServices.scoped(root, AppDatabase.memory());
    addTearDown(() async {
      await services.close();
      await root.delete(recursive: true);
    });
    await services.settings.load();
    await services.supervision.load();
    final books = services.books;
    final source = (await books.sources(
      BookKind.text,
      enabledOnly: true,
    )).firstWhere((entry) => entry.source.builtin).source;
    final guard = services.supervision;
    await guard.saveCredentials(
      await guard.prepareCredentials('fixture-password'),
    );

    Future<SensitiveSession> session() => guard.execute(
      SensitiveOperation.channels,
      () async => guard.createSession(SensitiveOperation.channels),
      password: 'fixture-password',
    );

    Future<void> rejectQueued(Future<void> Function() operation) async {
      final grant = await session();
      final entered = Completer<void>();
      final release = Completer<void>();
      final blocking = services.db.transaction(() async {
        await services.db.rows('SELECT 1');
        entered.complete();
        await release.future;
      });
      await entered.future;
      try {
        final attempted = grant.run(operation);
        final rejected = expectLater(attempted, throwsFormatException);
        await Future<void>.delayed(Duration.zero);
        guard.invalidatePermissions();
        release.complete();
        await blocking;
        await rejected;
      } finally {
        if (!release.isCompleted) release.complete();
        await blocking;
        grant.close();
      }
    }

    await rejectQueued(() => books.saveSource(source, {'enabled': false}));
    expect(
      (await books.sourceEntry(BookKind.text, source.id))!.enabled,
      isTrue,
    );

    final grant = await session();
    await grant.run(() => books.saveSource(source, {'enabled': false}));
    grant.close();
    expect(
      (await books.sourceEntry(BookKind.text, source.id))!.enabled,
      isFalse,
    );

    await rejectQueued(() => books.restoreDefaultSources(BookKind.text));
    expect(
      (await books.sourceEntry(BookKind.text, source.id))!.enabled,
      isFalse,
    );
  });
}
