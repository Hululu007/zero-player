import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/diagnostics/performance_counters.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/media/cache/segment_index.dart';
import 'package:zero_player/media/cache/segment_store.dart';

const _optimized = bool.fromEnvironment('EXPECT_OPTIMIZED_SEGMENTS');
const _constantCapacity = true;

void main() {
  setUp(() {
    PerformanceCounters.enabled = true;
    PerformanceCounters.reset();
  });
  tearDown(() {
    PerformanceCounters.enabled = false;
    PerformanceCounters.reset();
  });
  _pinWorkloads();
  _capacityWorkloads();
  _hashWorkloads();
}

void _pinWorkloads() {
  for (final count in [1, 100, 1000]) {
    test('$count owner pin workload', () async {
      final root = await Directory.systemTemp.createTemp('pins-workload-');
      final db = AppDatabase.memory();
      final store = SegmentStore(root, metadata: SegmentIndex(db));
      addTearDown(() async {
        await db.close();
        await root.delete(recursive: true);
      });
      final key = 'a' * 64;
      await store.write(
        key,
        Stream.value([1, 2, 3]),
        statusCode: 200,
        headers: {},
      );
      await db.batch((batch) {
        for (var i = 0; i < count; i++) {
          batch.customStatement('INSERT INTO segment_references VALUES(?,?)', [
            'owner-$i',
            key,
          ]);
        }
      });
      PerformanceCounters.reset();
      final result = await store.pinnedResourcesFor({
        for (var i = 0; i < count; i++) 'owner-$i',
      });
      final counts = PerformanceCounters.snapshot();
      expect(result, hasLength(count));
      expect(result.values.every((pins) => pins[key] == 3), true);
      expect(counts['db.queries'], (count / 400).ceil());
      _report('pins-$count', counts);
    });
  }
}

void _capacityWorkloads() {
  for (final count in [1000, 10000, 50000]) {
    test('$count entry capacity workload', () async {
      final root = await Directory.systemTemp.createTemp('capacity-workload-');
      final store = SegmentStore(root);
      addTearDown(() => root.delete(recursive: true));
      // Populate the supported external-loader path without 50k filesystem writes.
      final file = await File('${root.path}/fixture').writeAsBytes([1]);
      for (var i = 0; i < count; i++) {
        final lease = await store.acquire(
          '$i',
          () async => StoredResource(
            file: file,
            length: 1,
            digest: '',
            statusCode: 200,
            headers: {},
          ),
        );
        lease.release();
      }
      PerformanceCounters.reset();
      for (var i = 0; i < 10; i++) {
        expect(store.sizeBytes, count);
        expect(store.cacheBytes, count);
      }
      await store.write(
        'f' * 64,
        Stream.value([1]),
        statusCode: 200,
        headers: {},
      );
      final counts = PerformanceCounters.snapshot();
      expect(store.sizeBytes, count + 1);
      expect(
        counts['cache.capacity.visited'] ?? 0,
        _constantCapacity ? 0 : count * 21,
      );
      _report('capacity-$count', counts);
    });
  }
}

void _hashWorkloads() {
  for (final chunkSize in [4096, 65536]) {
    test('4MiB hash in $chunkSize chunks', () async {
      final root = await Directory.systemTemp.createTemp('hash-workload-');
      final store = SegmentStore(root);
      addTearDown(() => root.delete(recursive: true));
      final chunk = List.generate(chunkSize, (i) => i % 251);
      final stopwatch = Stopwatch()..start();
      final resource = await store.write(
        'a' * 64,
        Stream.fromIterable(
          List.generate(4 * 1024 * 1024 ~/ chunkSize, (_) => chunk),
        ),
        statusCode: 200,
        headers: {},
        expectedLength: 4 * 1024 * 1024,
      );
      stopwatch.stop();
      final counts = PerformanceCounters.snapshot();
      expect(resource.length, 4 * 1024 * 1024);
      expect(
        resource.digest,
        '${await sha256.bind(resource.file.openRead()).first}',
      );
      expect(
        counts['cache.hash.read_bytes'] ?? 0,
        _optimized ? 0 : resource.length,
      );
      _report(
        'hash-4MiB-$chunkSize',
        counts,
        micros: stopwatch.elapsedMicroseconds,
      );
    });
  }
}

void _report(String scenario, Map<String, int> counts, {int? micros}) =>
    stdout.writeln(
      jsonEncode({
        'scenario': scenario,
        'counts': counts,
        if (micros != null) 'elapsedMicros': micros,
        'mode': 'flutter-test-debug',
      }),
    );
