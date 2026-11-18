import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/media/cache/segment_index.dart';
import 'package:zero_player/media/cache/segment_metadata.dart';
import 'package:zero_player/media/cache/segment_store.dart';

void main() {
  _accountingContracts();
  _failureContracts();
  _damagedIndexRecovery();
  test(
    'startup removes orphan binaries and reconciles missing indexed files',
    () async {
      final root = await Directory.systemTemp.createTemp('cache-reconcile-');
      final db = AppDatabase.memory();
      final store = SegmentStore(root, metadata: SegmentIndex(db));
      addTearDown(() async {
        await db.close();
        await root.delete(recursive: true);
      });
      final key = 'a' * 64;
      await store.write(
        key,
        Stream.value([1, 2]),
        statusCode: 200,
        headers: {},
      );
      await store.find(key)!.file.delete();
      await File('${root.path}/${'b' * 64}.bin').writeAsBytes([3]);
      await store.initialize();
      expect(store.find(key), isNull);
      expect(store.sizeBytes, 0);
      expect(store.cacheBytes, 0);
      expect(await root.list().toList(), isEmpty);
    },
  );
  for (final range in [false, true]) {
    test(
      'empty or range-truncated body is never committed: range=$range',
      () async {
        final root = await Directory.systemTemp.createTemp('cache-body-');
        addTearDown(() => root.delete(recursive: true));
        final store = SegmentStore(root);
        await expectLater(
          store.write(
            'a' * 64,
            Stream.value(range ? [1] : <int>[]),
            statusCode: range ? 206 : 200,
            headers: {if (range) 'content-range': 'bytes 2-3/4'},
          ),
          throwsA(isA<HttpException>()),
        );
        expect(store.sizeBytes, 0);
        expect(await root.list().toList(), isEmpty);
      },
    );
  }
}

void _damagedIndexRecovery() {
  test(
    'startup retains damaged indexed files and their offline references',
    () async {
      final root = await Directory.systemTemp.createTemp('cache-damaged-');
      final db = AppDatabase.memory();
      final store = SegmentStore(root, metadata: SegmentIndex(db));
      addTearDown(() async {
        await db.close();
        await root.delete(recursive: true);
      });
      final key = 'c' * 64;
      await store.write(
        key,
        Stream.value([1, 2]),
        statusCode: 200,
        headers: {},
      );
      await store.pin('offline', key);
      await db.customStatement(
        'UPDATE segment_index SET headers=? WHERE cache_key=?',
        ['broken', key],
      );
      final recovered = SegmentStore(root, metadata: SegmentIndex(db));
      await recovered.initialize();
      expect(recovered.find(key), isNull);
      expect(await File('${root.path}/$key.bin').readAsBytes(), [1, 2]);
      expect(await SegmentIndex(db).ownedKeys('offline'), {key});
    },
  );
}

void _accountingContracts() {
  for (final persistent in [false, true]) {
    test(
      'capacity follows replacements, reloads and shared pins: $persistent',
      () async {
        final root = await Directory.systemTemp.createTemp('capacity-');
        final db = AppDatabase.memory();
        final metadata = persistent ? SegmentIndex(db) : null;
        final store = SegmentStore(root, maxBytes: 100, metadata: metadata);
        addTearDown(() async {
          await db.close();
          await root.delete(recursive: true);
        });
        final a = 'a' * 64, b = 'b' * 64, c = 'c' * 64;
        final known = {a, b, c};
        Future<void> check(Set<String> pinned) async {
          final entries = {
            for (final key in known)
              if (store.find(key) != null) key: store.find(key)!,
          };
          expect(
            store.sizeBytes,
            entries.values.fold<int>(0, (n, v) => n + v.length),
          );
          expect(
            store.cacheBytes,
            entries.entries
                .where((e) => !pinned.contains(e.key))
                .fold<int>(0, (n, e) => n + e.value.length),
          );
        }

        Future<StoredResource> write(String key, int size) => store.write(
          key,
          Stream.value(List.filled(size, 1)),
          statusCode: 200,
          headers: {},
        );
        await store.initialize();
        await write(a, 3);
        // _commit installs the entry and _load receives the same result again.
        (await store.acquire(b, () => write(b, 5))).release();
        await check({});
        await store.pin('one', a);
        await store.pin('two', a);
        await store.pin('one', b);
        await check({a, b});
        await write(a, 7);
        await check({a, b});
        await store.initialize();
        await store.initialize();
        await check({a, b});
        await store.retainPins('one', {b});
        await check({a, b});
        await store.unpin('two');
        await check({b});
        await write(c, 11);
        final lease = await store.acquire(c, () => throw StateError('missing'));
        await store.clearUnused();
        await check({b});
        expect(store.find(a), isNull);
        expect(store.find(c), isNotNull);
        lease.release();
        await store.evictUnused([c], 1);
        await check({b});
        await store.unpin('one');
        await store.clearUnused();
        await check({});
        expect(store.sizeBytes, 0);
      },
    );
  }
}

void _failureContracts() {
  test(
    'metadata failures retain conservative accounting until successful retry',
    () async {
      final root = await Directory.systemTemp.createTemp('capacity-fault-');
      final db = AppDatabase.memory();
      final metadata = _FaultMetadata(SegmentIndex(db));
      final store = SegmentStore(root, metadata: metadata);
      addTearDown(() async {
        await db.close();
        await root.delete(recursive: true);
      });
      final key = 'a' * 64;
      Future<StoredResource> write() => store.write(
        key,
        Stream.value([1, 2, 3]),
        statusCode: 200,
        headers: {},
      );
      metadata.failPut = true;
      await expectLater(write(), throwsStateError);
      expect(store.sizeBytes, 0);
      expect(store.cacheBytes, 0);
      expect(await root.list().toList(), isEmpty);
      metadata.failPut = false;
      await write();
      metadata.failRemove = true;
      await expectLater(store.clearUnused(), throwsStateError);
      expect(store.sizeBytes, 3);
      expect(store.cacheBytes, 3);
      metadata.failRemove = false;
      await store.clearUnused();
      expect(store.sizeBytes, 0);
      expect(store.cacheBytes, 0);
    },
  );
}

final class _FaultMetadata implements SegmentMetadata {
  _FaultMetadata(this.inner);
  final SegmentMetadata inner;
  bool failPut = false, failRemove = false;
  @override
  Future<void> put(String key, StoredResource value) {
    if (failPut) throw StateError('put failure');
    return inner.put(key, value);
  }

  @override
  Future<void> remove(String key) {
    if (failRemove) throw StateError('remove failure');
    return inner.remove(key);
  }

  @override
  Future<Map<String, StoredResource>> entries() => inner.entries();
  @override
  Future<Set<String>> protectedKeys() => inner.protectedKeys();
  @override
  Future<Set<String>> ownedKeys(String owner) => inner.ownedKeys(owner);
  @override
  Future<Map<String, Set<String>>> ownedKeysFor(Set<String> owners) =>
      inner.ownedKeysFor(owners);
  @override
  Future<void> pin(String owner, String key) => inner.pin(owner, key);
  @override
  Future<void> unpin(String owner) => inner.unpin(owner);
  @override
  Future<void> retainPins(String owner, Set<String> keys) =>
      inner.retainPins(owner, keys);
}
