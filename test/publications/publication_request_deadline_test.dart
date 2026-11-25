import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/core/network/request_scheduler.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/domain/publication.dart';

void main() {
  test('catalogue gzip is opt-in and bounded after decompression', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final transport = MediaHttpClient(allowPrivateNetworks: true);
    addTearDown(() async {
      transport.close();
      await server.close(force: true);
    });
    final body = List.filled(4096, 0x61);
    server.listen((request) async {
      final response = request.response;
      if (request.headers.value(HttpHeaders.acceptEncodingHeader) == 'gzip') {
        response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
        response.add(gzip.encode(body));
      } else {
        response.add(body);
      }
      await response.close();
    });
    final http = PublicationHttp(
      transport,
      authorize: (_) {},
      allowLoopback: true,
    );
    final uri = Uri.parse('http://127.0.0.1:${server.port}/');
    expect(
      (await http.text(uri, CancellationToken(), allowGzip: true)).length,
      4096,
    );
    await expectLater(
      http.text(uri, CancellationToken(), allowGzip: true, maxBytes: 128),
      throwsA(isA<PublicationFailure>()),
    );
  });

  test(
    'the directory deadline cancels a slow body and releases its permit',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final scheduler = RequestScheduler(globalLimit: 1, playbackReserve: 0);
      final transport = MediaHttpClient(
        allowPrivateNetworks: true,
        scheduler: scheduler,
        timeout: const Duration(seconds: 3),
      );
      addTearDown(() async {
        transport.close();
        scheduler.close();
        await server.close(force: true);
      });
      final streamed = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      server.listen((request) async {
        final response = request.response;
        if (request.uri.path == '/slow') {
          try {
            response
              ..bufferOutput = false
              ..write('partial');
            await response.flush();
            streamed.complete();
            await release.future;
          } on IOException {
            // The deadline may close the response while the server is writing.
          } finally {
            await response.close().catchError((Object _) => response);
          }
        } else {
          response.write('ready');
          await response.close();
        }
      });
      final http = PublicationHttp(
        transport,
        authorize: (_) {},
        allowLoopback: true,
      );
      final base = Uri(scheme: 'http', host: '127.0.0.1', port: server.port);
      final parent = CancellationToken();
      final failed = expectLater(
        http.text(
          base.resolve('/slow'),
          parent,
          deadline: const Duration(milliseconds: 350),
        ),
        throwsA(
          isA<PublicationFailure>().having(
            (error) => error.problem,
            'problem',
            PublicationProblem.timeout,
          ),
        ),
      );
      await streamed.future.timeout(const Duration(seconds: 2));
      await failed;
      expect(parent.isCancelled, isFalse);
      expect(
        await http
            .text(base.resolve('/ready'), parent)
            .timeout(const Duration(seconds: 2)),
        'ready',
      );
    },
  );

  test('cancelling the caller remains a cancellation', () async {
    final parent = CancellationToken();
    final operation = withPublicationRequestDeadline(
      parent,
      const Duration(seconds: 2),
      (token) {
        final failure = Completer<void>();
        token.listen(() => failure.completeError(const RequestCancelled()));
        return failure.future;
      },
    );
    final expectation = expectLater(
      operation,
      throwsA(isA<RequestCancelled>()),
    );
    parent.cancel();
    await expectation;
  });
}
