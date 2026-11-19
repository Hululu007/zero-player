import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/header_policy.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/media/cache/segment_fetcher.dart';
import 'package:zero_player/media/cache/segment_store.dart';
import 'package:zero_player/media/hls/hls_manifest.dart';
import 'package:zero_player/media/hls/offline_rewriter.dart';
import '../../test_support/http_test_server.dart';

void main() {
  for (final value in [
    null,
    'bytes 8-11/*',
    'bytes 8-11/10',
    'bytes 9-12/16',
    'bytes 8-10/16',
    'not-a-range',
  ]) {
    test('AUD-02 rejects missing or inconsistent range $value', () async {
      await _rangeCase('bytes=8-11', value, [8, 9, 10, 11], false);
    });
  }
  for (final request in ['bytes=8-20', 'bytes=8-', 'bytes=-4']) {
    test('AUD-02 accepts exact EOF clipping for $request', () async {
      await _rangeCase(request, 'bytes 8-11/12', [8, 9, 10, 11], true);
    });
  }
  test('AUD-02 rejects body shorter than a valid response range', () async {
    await _rangeCase('bytes=8-11', 'bytes 8-11/16', [8, 9], false);
  });
  test(
    'AUD-01 typed references select each default, including in-band audio',
    () {
      final manifest = HlsManifest.parse('''#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="main",NAME="Other",DEFAULT=NO,URI="other.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="main",NAME="In-band",DEFAULT=YES
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="main",NAME="Other",DEFAULT=NO,URI="other-sub.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="main",NAME="Default",DEFAULT=YES,URI="sub.m3u8"
#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="unreferenced",NAME="main",DEFAULT=YES,URI="wrong.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=100,AUDIO="main",SUBTITLES="main",CLOSED-CAPTIONS=NONE
video.m3u8
''', Uri.parse('https://hls.test/master.m3u8'));
      final selected = selectOfflineVariant(manifest);
      final renditions = selected.lines
          .where((line) => line.startsWith('#EXT-X-MEDIA:'))
          .toList();
      expect(renditions, hasLength(2));
      expect(renditions.first, contains('NAME="In-band"'));
      expect(renditions.last, contains('URI="sub.m3u8"'));
      expect(selected.playlistUris.map((uri) => uri.path), [
        '/sub.m3u8',
        '/video.m3u8',
      ]);
    },
  );
}

Future<void> _rangeCase(
  String range,
  String? header,
  List<int> bytes,
  bool valid,
) async {
  final root = await Directory.systemTemp.createTemp('audit-range-boundary-');
  final http = MediaHttpClient(allowPrivateNetworks: true);
  final server = await HttpTestServer.start((request) {
    request.response.statusCode = 206;
    if (header != null) request.response.headers.set('content-range', header);
    // Chunked framing makes the cached byte count validate the actual body.
    request.response.add(bytes);
  });
  try {
    final store = SegmentStore(root);
    await store.initialize();
    final operation = SegmentFetcher(store, http).fetch(
      server.baseUri.resolve('part'),
      HeaderPolicy({server.baseUri: {}}),
      range: range,
    );
    if (valid) {
      final lease = await operation;
      expect(await lease.resource.file.readAsBytes(), bytes);
      lease.release();
    } else {
      await expectLater(operation, throwsA(isA<HttpException>()));
      expect(await root.list().toList(), isEmpty);
    }
  } finally {
    http.close();
    await server.close();
    await root.delete(recursive: true);
  }
}
