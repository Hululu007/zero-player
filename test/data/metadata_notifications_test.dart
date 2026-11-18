import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/persistence/app_database.dart';

void main() {
  _preciseContracts();
  _transactionContracts();
}

late AppDatabase db;
late List<String> events;
final subscriptions = <StreamSubscription<void>>[];

void _fixture() {
  setUp(() async {
    db = AppDatabase.memory();
    await db.rows('SELECT 1');
    events = [];
    for (final entry in {
      'legacy': null,
      'live': {MetadataDomain.live},
      'history': {MetadataDomain.musicHistory},
      'mode': {MetadataDomain.musicMode},
      'empty': <MetadataDomain>{},
    }.entries) {
      subscriptions.add(
        db
            .changesFor({'app_meta'}, metadataDomains: entry.value)
            .listen((_) => events.add(entry.key)),
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
}

void _preciseContracts() {
  _fixture();
  test(
    'precise writes preserve legacy events and filter by explicit keys',
    () async {
      await db.setMetadata('music_mode', '"shuffle"', MetadataDomain.musicMode);
      await _flush();
      expect(events, ['legacy', 'mode']);
      await expectLater(
        db.setMetadata('live_state:x', '{}', MetadataDomain.musicMode),
        throwsArgumentError,
      );
      expect(
        await db.rows("SELECT * FROM app_meta WHERE key='live_state:x'"),
        isEmpty,
      );
    },
  );
  test('multiple precise domains merge once after nested commit', () async {
    await db.atomic(() async {
      await db.setMetadata('music_mode', '"shuffle"', MetadataDomain.musicMode);
      await db.atomic(
        () => db.setMetadata(
          'music_history:x',
          '{}',
          MetadataDomain.musicHistory,
        ),
        tables: {},
      );
      await _flush();
      expect(events, isEmpty);
    }, tables: {});
    await _flush();
    expect(events, ['legacy', 'history', 'mode']);
  });
  for (final writer in [
    'write',
    'raw',
    'batch',
    'nested',
    'transaction',
    'unknown',
  ]) {
    test('$writer cannot be masked by an outer precise declaration', () async {
      await db.atomic(
        () async {
          await db.setMetadata(
            'music_mode',
            '"shuffle"',
            MetadataDomain.musicMode,
          );
          const sql =
              "INSERT OR REPLACE INTO app_meta VALUES('live_state:x','{}')";
          switch (writer) {
            case 'write':
              await db.write(sql);
            case 'raw':
              await db.customStatement(sql);
            case 'batch':
              await db.batch((batch) => batch.customStatement(sql));
            case 'nested':
              await db.atomic(
                () => db.customStatement(sql),
                tables: {'app_meta'},
              );
            case 'transaction':
              await db.transaction(() => db.customStatement(sql));
            case 'unknown':
              db.changed(tables: {'app_meta'});
          }
        },
        tables: {'app_meta'},
        metadataDomains: {MetadataDomain.musicMode},
      );
      await _flush();
      expect(events, ['legacy', 'live', 'history', 'mode', 'empty']);
    });
  }
}

void _transactionContracts() {
  test(
    'trigger side effects invalidate every domain and other tables',
    () async {
      await db.customStatement(
        '''CREATE TRIGGER side_effect AFTER INSERT ON app_meta
      WHEN NEW.key='music_mode' BEGIN
      INSERT OR REPLACE INTO app_meta VALUES('live_state:x','{}'); END''',
      );
      await db.setMetadata('music_mode', '"shuffle"', MetadataDomain.musicMode);
      await _flush();
      expect(events, ['legacy', 'live', 'history', 'mode', 'empty']);
    },
  );
  test(
    'default null differs from explicit empty and ordinary transactions defer',
    () async {
      await db.atomic(() async {}, tables: {'app_meta'}, metadataDomains: {});
      await _flush();
      expect(events, ['legacy']);
      events.clear();
      await db.atomic(() async {}, tables: {'app_meta'});
      await _flush();
      expect(events, ['legacy', 'live', 'history', 'mode', 'empty']);
      events.clear();
      await db.transaction(() async {
        await db.setMetadata(
          'music_mode',
          '"shuffle"',
          MetadataDomain.musicMode,
        );
        await _flush();
        expect(events, isEmpty);
      });
      await _flush();
      expect(events, ['legacy', 'mode']);
    },
  );
  test(
    'rollback, read-only and silent raw transactions do not publish',
    () async {
      await expectLater(
        db.atomic(() async {
          await db.setMetadata(
            'music_mode',
            '"shuffle"',
            MetadataDomain.musicMode,
          );
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      await db.atomic(() => db.rows('SELECT 1'), tables: {});
      await db.transaction(
        () => db.customStatement("INSERT INTO app_meta VALUES('raw','1')"),
      );
      await _flush();
      expect(events, isEmpty);
      expect(
        await db.rows("SELECT * FROM app_meta WHERE key='music_mode'"),
        isEmpty,
      );
    },
  );
  test(
    'rolled-back savepoint does not contaminate successful precise writes',
    () async {
      await db.atomic(() async {
        await expectLater(
          db.atomic(() async {
            await db.write("INSERT INTO app_meta VALUES('live_state:x','{}')");
            throw StateError('inner rollback');
          }),
          throwsStateError,
        );
        await db.setMetadata(
          'music_mode',
          '"shuffle"',
          MetadataDomain.musicMode,
        );
      }, tables: {});
      await _flush();
      expect(events, ['legacy', 'mode']);
      expect(
        await db.rows("SELECT * FROM app_meta WHERE key='live_state:x'"),
        isEmpty,
      );
    },
  );
  test(
    'logical content records stay independent and full restore invalidates all',
    () async {
      var logical = 0;
      final sub = db.changesFor({'content_records'}).listen((_) => logical++);
      await db.atomic(
        () => db.customStatement(
          "INSERT INTO app_meta VALUES('content_label:x:y','{}')",
        ),
        tables: {'content_records'},
      );
      await _flush();
      expect(logical, 1);
      expect(events, isEmpty);
      await db.atomic(() => db.customStatement('DELETE FROM app_meta'));
      await _flush();
      expect(logical, 2);
      expect(events, ['legacy', 'live', 'history', 'mode', 'empty']);
      await sub.cancel();
    },
  );
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);
