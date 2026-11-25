import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:zero_player/features/publications/domain/publication.dart';

import 'local_book_fixtures.dart';

final class PublicationRangeFixture {
  PublicationRangeFixture(this.server, this.bytes);
  final HttpServer server;
  final Uint8List bytes;
  final requests = <String>[];
  final unsatisfiedRanges = <String, int>{};
  final interruptedRanges = <String>{};
  var entryVisits = 0;
  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}/licensed.pdf');
  Uri get entry => uri.replace(path: '/download');
  AcquisitionCandidate get candidate => AcquisitionCandidate(
    source: 'manual',
    link: uri,
    format: PublicationFormat.pdf,
    bytes: bytes.length,
  );

  static Future<PublicationRangeFixture> start({
    bool wrongRange = false,
    bool changedWhole = false,
    bool unknownLength = false,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bytes = Uint8List(9 << 20);
    final pdf = samplePdf();
    bytes.setRange(0, pdf.length, pdf);
    for (var i = 256; i < bytes.length; i += 256) {
      bytes[i] = (i >> 8) & 255;
    }
    final fixture = PublicationRangeFixture(server, bytes);
    server.listen(
      (request) => unawaited(
        fixture._serve(request, wrongRange, changedWhole, unknownLength),
      ),
    );
    return fixture;
  }

  Future<void> _serve(
    HttpRequest request,
    bool wrongRange,
    bool changedWhole,
    bool unknownLength,
  ) async {
    if (request.uri.path == entry.path) {
      entryVisits++;
      await request.response.redirect(uri);
      return;
    }
    final range = request.headers.value('range');
    requests.add(range ?? 'all');
    final response = request.response;
    final match = unknownLength
        ? null
        : RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range ?? '');
    final start = match == null ? 0 : int.parse(match[1]!);
    final end = match == null ? bytes.length - 1 : int.parse(match[2]!);
    response.headers.set(
      'etag',
      range == null && changedWhole ? '"release-v2"' : '"release-v1"',
    );
    response.headers.contentType = ContentType('application', 'pdf');
    if (unsatisfiedRanges[range] case final length?) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
      response.contentLength = 0;
      await response.close();
      return;
    }
    if (match != null) {
      response.statusCode = 206;
      response.headers.set(
        'content-range',
        'bytes $start-${wrongRange && end > 0 ? end - 1 : end}/${bytes.length}',
      );
    }
    if (unknownLength) {
      response.headers.chunkedTransferEncoding = true;
    } else {
      response.contentLength = end - start + 1;
    }
    if (interruptedRanges.remove(range ?? 'all')) {
      final socket = await response.detachSocket();
      socket.add(bytes.sublist(start, start + 1024));
      await socket.flush();
      await socket.close();
      return;
    }
    try {
      for (var offset = start; offset <= end; offset += 256 << 10) {
        response.add(
          Uint8List.sublistView(
            bytes,
            offset,
            min(offset + (256 << 10), end + 1),
          ),
        );
        await response.flush();
      }
      await response.close();
    } on IOException {
      // Test clients deliberately cancel malformed or interrupted responses.
    }
  }

  Future<void> close() async {
    await server.close(force: true);
  }
}
