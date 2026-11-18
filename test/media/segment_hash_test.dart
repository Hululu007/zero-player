import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/media/cache/segment_store.dart';

void main() {
  test(
    'streaming hash covers empty, uneven chunks and post-write tampering',
    () async {
      final root = await Directory.systemTemp.createTemp('stream-hash-');
      final store = SegmentStore(root);
      addTearDown(() => root.delete(recursive: true));
      for (var i = 0; i < 3; i++) {
        final chunks = <List<int>>[
          [],
          if (i > 0) [1, 2, 3],
          if (i > 1) List.filled(1048577, 9),
        ];
        final key = i.toRadixString(16).padLeft(64, '0');
        final bytes = chunks.expand((c) => c).toList();
        final resource = await store.write(
          key,
          Stream.fromIterable(chunks),
          statusCode: 206,
          headers: {'content-type': 'video/mp2t'},
          expectedLength: bytes.length,
        );
        expect(resource.digest, sha256.convert(bytes).toString());
        expect(await resource.file.readAsBytes(), bytes);
        await store.verify(key);
        if (bytes.isNotEmpty) {
          bytes[0] ^= 1;
          await resource.file.writeAsBytes(bytes);
          await expectLater(
            store.verify(key),
            throwsA(isA<FileSystemException>()),
          );
          expect(store.find(key), isNull);
        }
      }
    },
  );
  for (final failure in ['error', 'cancel', 'length', 'capacity', 'rename']) {
    test('$failure preserves no provisional entry or partial file', () async {
      final root = await Directory.systemTemp.createTemp('stream-fail-');
      final store = SegmentStore(root, maxResourceBytes: 3);
      addTearDown(() => root.delete(recursive: true));
      final key = 'a' * 64;
      if (failure == 'rename') {
        await Directory('${root.path}/$key.bin').create();
      }
      Stream<List<int>> body() async* {
        yield [1, 2, 3];
        if (failure == 'error') throw StateError('stream failed');
        if (failure == 'cancel') throw const RequestCancelled();
        if (failure == 'capacity') yield [4];
      }

      await expectLater(
        store.write(
          key,
          body(),
          statusCode: 200,
          headers: {},
          expectedLength: failure == 'length' ? 4 : null,
        ),
        throwsA(anything),
      );
      expect(store.sizeBytes, 0);
      expect(store.find(key), isNull);
      expect(await File('${root.path}/$key.part').exists(), false);
      if (failure == 'rename') {
        await Directory('${root.path}/$key.bin').delete();
      }
      final retry = await store.write(
        key,
        Stream.value([1]),
        statusCode: 200,
        headers: {},
      );
      expect(retry.digest, sha256.convert([1]).toString());
    });
  }
}
