import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/media/cache/segment_store.dart';
import 'package:zero_player/media/gateway/offline_server.dart';

void main() {
  test(
    'revoking an offline session interrupts a response already streaming',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'offline-revoke-stream-',
      );
      final media = File('${root.path}/video.mp4');
      const size = 64 * 1024 * 1024;
      final writer = await media.open(mode: FileMode.write);
      await writer.truncate(size);
      await writer.close();
      final server = OfflineServer(
        SegmentStore(Directory('${root.path}/segments')),
      );
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await server.close();
        await root.delete(recursive: true);
      });

      final session = await server.openLocal(media);
      final response = await (await client.getUrl(session.uri)).close();
      expect(response.statusCode, 200);
      expect(response.contentLength, size);
      var received = 0;
      var revoked = false;
      final done = Completer<void>();
      response.listen(
        (chunk) {
          received += chunk.length;
          if (!revoked) {
            revoked = true;
            session.close();
          }
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object _, StackTrace _) {
          // The declared body is deliberately truncated on revocation.
          if (!done.isCompleted) done.complete();
        },
      );
      await done.future.timeout(const Duration(seconds: 10));
      expect(revoked, isTrue);
      expect(received, greaterThan(0));
      expect(received, lessThan(size));
      final after = await (await client.getUrl(session.uri)).close();
      expect(after.statusCode, 404);
      await after.drain<void>();
    },
  );
}
