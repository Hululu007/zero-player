import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/media/cache/segment_index.dart';
import 'package:zero_player/media/cache/segment_store.dart';

void main() {
  for (final persistent in [false, true]) {
    test(
      'batch pins preserve owners, empty sets and recovery: persistent=$persistent',
      () async {
        final root = await Directory.systemTemp.createTemp('batch-pins-');
        final db = AppDatabase.memory();
        final metadata = persistent ? SegmentIndex(db) : null;
        final store = SegmentStore(root, metadata: metadata);
        addTearDown(() async {
          await db.close();
          await root.delete(recursive: true);
        });
        final a = 'a' * 64, b = 'b' * 64;
        for (final key in [a, b]) {
          await store.write(
            key,
            Stream.value([1, 2, 3]),
            statusCode: 200,
            headers: {},
          );
        }
        await store.pin('one', a);
        await store.pin('one', b);
        await store.pin('two', a);
        expect(await store.pinnedResourcesFor({}), isEmpty);
        final pins = await store.pinnedResourcesFor({'one', 'two', 'absent'});
        expect(pins, {
          'one': {a: 3, b: 3},
          'two': {a: 3},
          'absent': <String, int>{},
        });
        await Future.wait([
          store.retainPins('one', {b}),
          store.unpin('two'),
        ]);
        expect(await store.pinnedResourcesFor({'one', 'two'}), {
          'one': {b: 3},
          'two': <String, int>{},
        });
        if (persistent) {
          await store.find(b)!.file.delete();
          final recovered = SegmentStore(root, metadata: metadata);
          await recovered.initialize();
          expect(await recovered.pinnedResourcesFor({'one', 'two'}), {
            'one': <String, int>{},
            'two': <String, int>{},
          });
          expect(await metadata!.ownedKeys('one'), isEmpty);
        }
      },
    );
  }
}
