import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/media/cache/segment_metadata.dart';
import 'package:zero_player/media/cache/segment_store.dart';

void main() {
  test(
    'acquire waits for an in-progress deletion before leasing or reloading',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'cache-eviction-race-',
      );
      addTearDown(() => root.delete(recursive: true));
      final key = 'a' * 64;
      final file = await File(
        '${root.path}/$key.bin',
      ).writeAsBytes(List.filled(8, 1));
      final blocked = _BlockingDelete(file);
      final metadata = _Metadata({
        key: StoredResource(
          file: blocked,
          length: 8,
          digest: 'old',
          statusCode: 200,
          headers: {},
        ),
      });
      final store = SegmentStore(root, maxBytes: 10, metadata: metadata);
      await store.initialize();
      Future<StoredResource> write(String id, int value) => store.write(
        id,
        Stream.value(List.filled(8, value)),
        statusCode: 200,
        headers: {},
      );
      final eviction = write('b' * 64, 2);
      await blocked.started.future;
      var acquired = false, loads = 0;
      final pending = store
          .acquire(key, () {
            loads++;
            return write(key, 3);
          })
          .then((lease) {
            acquired = true;
            return lease;
          });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final leasedDuringDelete = acquired;
      blocked.release.complete();
      await eviction;
      final lease = await pending;
      try {
        expect(leasedDuringDelete, isFalse);
        expect(loads, 1);
        expect(await lease.resource.file.readAsBytes(), List.filled(8, 3));
      } finally {
        lease.release();
      }
    },
  );
}

final class _BlockingDelete extends Fake implements File {
  _BlockingDelete(this.file);
  final File file;
  final started = Completer<void>(), release = Completer<void>();
  @override
  String get path => file.path;
  @override
  File get absolute => this;
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<int> length() => file.length();
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    started.complete();
    await release.future;
    return file.delete(recursive: recursive);
  }
}

final class _Metadata extends Fake implements SegmentMetadata {
  _Metadata(this.values);
  final Map<String, StoredResource> values;
  @override
  Future<Map<String, StoredResource>> entries() async => Map.of(values);
  @override
  Future<Set<String>> protectedKeys() async => {};
  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }

  @override
  Future<void> put(String key, StoredResource value) async {
    values[key] = value;
  }
}
