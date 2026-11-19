import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/header_policy.dart';
import 'package:zero_player/media/cache/segment_store.dart';
import 'package:zero_player/media/gateway/media_gateway.dart';
import 'package:zero_player/media/gateway/offline_server.dart';
import '../../test_support/http_test_server.dart';

void main() {
  _rollingManifestTest();
  _offlineLeaseTest();
}

void _rollingManifestTest() {
  test(
    'rolling HLS exceeds 20000 lifetime resources while retaining recent keys, maps and playlists',
    () async {
      final root = await Directory.systemTemp.createTemp('rolling-gateway-');
      var generation = 0;
      final server = await HttpTestServer.start((request) {
        final index = generation;
        request.response.write(
          '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:${index * 400}\n'
          '#EXT-X-KEY:METHOD=AES-128,URI="key$index.bin"\n'
          '#EXT-X-MAP:URI="init$index.mp4"\n'
          '${List.generate(400, (i) => '#EXTINF:4,\n${index * 400 + i}.ts\n').join()}',
        );
      });
      final gateway = MediaGateway(
        SegmentStore(root),
        allowPrivateNetworks: true,
      );
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await gateway.close();
        await server.close();
        await root.delete(recursive: true);
      });
      await gateway.start();
      final session = gateway.createSession(HeaderPolicy({}));
      final playlist = session.register(
        server.baseUri.resolve('live.m3u8'),
        playlist: true,
      );
      final capabilities = <Uri>[];
      for (generation = 0; generation < 55; generation++) {
        final response = await (await client.getUrl(playlist)).close();
        final text = await utf8.decoder.bind(response).join();
        expect(
          response.statusCode,
          200,
          reason: 'generation $generation: $text',
        );
        final segment = Uri.parse(
          text.split('\n').firstWhere((line) => line.startsWith('http')),
        );
        expect(gateway.isRegisteredResource(segment), isTrue);
        if (capabilities.isNotEmpty) {
          expect(gateway.isRegisteredResource(capabilities.last), isTrue);
        }
        if (capabilities.length >= 2) {
          expect(
            gateway.isRegisteredResource(capabilities[capabilities.length - 2]),
            isFalse,
          );
        }
        capabilities.add(segment);
        expect(gateway.isRegisteredPlaylist(playlist), isTrue);
      }
      expect(
        capabilities.toSet(),
        hasLength(55),
        reason: 'Retired IDs must never alias new resources',
      );
      session.close();
    },
  );
}

void _offlineLeaseTest() {
  test(
    'offline session leases prevent eviction and are released on close or failed open',
    () async {
      final root = await Directory.systemTemp.createTemp('offline-lease-');
      final store = SegmentStore(Directory('${root.path}/cache'));
      await store.initialize();
      final server = OfflineServer(store);
      addTearDown(() async {
        await server.close();
        await root.delete(recursive: true);
      });
      final key = sha256.convert([1, 2, 3]).toString();
      await store.write(
        key,
        Stream.value([1, 2, 3]),
        statusCode: 200,
        headers: {},
      );
      final manifest = File('${root.path}/index.m3u8');
      await manifest.writeAsString(
        '#EXTM3U\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n',
      );
      await File('${root.path}/resources.json').writeAsString(
        jsonEncode({
          'index.m3u8': {
            'local': 'index.m3u8',
            'digest': sha256.convert(await manifest.readAsBytes()).toString(),
          },
          'segment.ts': {'key': key},
        }),
      );
      final session = await server.open('task', root, 'index.m3u8');
      await store.clearUnused();
      expect(store.find(key), isNotNull);
      session.close();
      await store.clearUnused();
      expect(store.find(key), isNull);
      await store.write(
        key,
        Stream.value([1, 2, 3]),
        statusCode: 200,
        headers: {},
      );
      await expectLater(
        server.open('task', root, 'missing.m3u8'),
        throwsFormatException,
      );
      await store.clearUnused();
      expect(store.find(key), isNull);
    },
  );
}
