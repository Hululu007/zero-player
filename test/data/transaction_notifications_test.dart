import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/persistence/app_database.dart';

void main() {
  late AppDatabase db;
  late List<String> events;
  final subscriptions = <StreamSubscription<void>>[];
  setUp(() async {
    db = AppDatabase.memory();
    await db.rows('SELECT 1');
    events = [];
    for (final table in ['settings', 'app_meta', 'downloads']) {
      subscriptions.add(
        db.changesFor({table}).listen((_) => events.add(table)),
      );
    }
  });
  tearDown(() async {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    subscriptions.clear();
    await db.close();
  });

  test('rollback emits no provisional changes', () async {
    await expectLater(
      db.atomic(() async {
        await db.write('INSERT INTO settings VALUES(?,?)', ['a', '1']);
        await Future<void>.delayed(Duration.zero);
        expect(events, isEmpty);
        throw StateError('rollback');
      }, tables: {'settings'}),
      throwsStateError,
    );
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
    expect(await db.rows("SELECT * FROM settings WHERE key='a'"), isEmpty);
  });

  test(
    'nested writes and explicit declarations emit one union after commit',
    () async {
      await db.atomic(() async {
        await db.write('INSERT INTO settings VALUES(?,?)', ['a', '1']);
        await db.atomic(() async {
          await db.write('INSERT INTO app_meta VALUES(?,?)', ['b', '2']);
        }, tables: {'app_meta'});
        await Future<void>.delayed(Duration.zero);
        expect(events, isEmpty);
      }, tables: {'settings'});
      await Future<void>.delayed(Duration.zero);
      expect(events, ['settings', 'app_meta']);
    },
  );

  test(
    'empty read transaction stays silent and unrelated writes still notify',
    () async {
      await db.atomic(() => db.rows('SELECT * FROM settings'), tables: {});
      await db.write('INSERT INTO app_meta VALUES(?,?)', ['c', '3']);
      await Future<void>.delayed(Duration.zero);
      expect(events, ['app_meta']);
    },
  );
}
