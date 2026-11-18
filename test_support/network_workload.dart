import 'dart:async';
import 'dart:io';

import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/document_client.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/core/network/request_scheduler.dart';

import 'http_test_server.dart';
import 'network_workload_metrics.dart';

/// Real transport clients with the production shared/reading connection limits.
/// The fixture drives request demand, not repository or native-player traffic.
final class NetworkWorkload {
  NetworkWorkload({required bool observe})
    : metrics = NetworkWorkloadMetrics(enabled: observe);

  final shared = MediaHttpClient(allowPrivateNetworks: true);
  final reading = MediaHttpClient(
    allowPrivateNetworks: true,
    maxConnectionsPerHost: 2,
    allowLegacyQueryEncoding: true,
  );
  final NetworkWorkloadMetrics metrics;
  final _servers = <HttpTestServer>[];
  final jobs = <NetworkWorkloadJob>[];
  int _serverActive = 0;
  int peakServerActive = 0;

  Future<void> initialize({int origins = 10}) async {
    for (var i = 0; i < origins; i++) {
      _servers.add(await HttpTestServer.start(_respond));
    }
  }

  NetworkWorkloadJob start({
    required String module,
    required int origin,
    bool books = false,
    RequestPriority priority = RequestPriority.interactive,
  }) {
    final id = jobs.length;
    final job = NetworkWorkloadJob(id);
    jobs.add(job);
    final client = DocumentClient(books ? reading : shared);
    job.result = metrics.enabled
        ? observeRequests(
            RequestObservation((phase) {
              switch (phase) {
                case RequestPhase.queued:
                  metrics.queued(id, module, priority.name, origin);
                case RequestPhase.started:
                  metrics.activity(id, true);
                case RequestPhase.released:
                  metrics.activity(id, false);
                case RequestPhase.cancelled:
                  metrics.cancelled(id);
              }
            }),
            () => _read(client, job, origin, priority),
          )
        : _read(client, job, origin, priority);
    return job;
  }

  Future<NetworkWorkloadResult> _read(
    DocumentClient client,
    NetworkWorkloadJob job,
    int origin,
    RequestPriority priority,
  ) async {
    try {
      final document = await client.get(
        _servers[origin].baseUri.resolve('work/${job.id}'),
        maxBytes: NetworkWorkloadJob.payloadBytes,
        priority: priority,
        cancellation: job.token,
      );
      final valid =
          document.bytes.length == NetworkWorkloadJob.payloadBytes &&
          document.bytes.every((byte) => byte == job.id % 251);
      metrics.finished(job.id, bytes: document.bytes.length);
      return NetworkWorkloadResult(valid: valid, bytes: document.bytes.length);
    } on RemoteFailure catch (error) {
      final cancelled = error.kind == FailureKind.cancelled;
      metrics.finished(job.id, cancelled: cancelled);
      return NetworkWorkloadResult(
        cancelled: cancelled,
        error: error.kind.name,
      );
    } catch (error) {
      metrics.finished(job.id);
      return NetworkWorkloadResult(error: error.runtimeType.toString());
    }
  }

  Future<void> _respond(HttpRequest request) async {
    final job = jobs[int.parse(request.uri.pathSegments.last)];
    _serverActive++;
    if (_serverActive > peakServerActive) peakServerActive = _serverActive;
    try {
      request.response.contentLength = NetworkWorkloadJob.payloadBytes;
      request.response.add([job.id % 251]);
      await request.response.flush();
      job.started.complete();
      await job.gate.future;
      if (!job.token.isCancelled) {
        request.response.add(
          List.filled(NetworkWorkloadJob.payloadBytes - 1, job.id % 251),
        );
      }
    } on HttpException {
      // Cancellation legitimately aborts a response before the complete body.
    } on SocketException {
      // The client owns cancellation; the fixture still releases its handler.
    } finally {
      _serverActive--;
    }
  }

  Future<void> waitFor(Iterable<NetworkWorkloadJob> requests) => Future.wait([
    for (final job in requests)
      job.started.future.timeout(const Duration(seconds: 5)),
  ]);

  Future<List<NetworkWorkloadResult>> finish() async {
    for (final job in jobs) {
      job.release();
    }
    return Future.wait([for (final job in jobs) job.result]);
  }

  Map<String, Object> snapshot() => {
    ...metrics.snapshot(),
    'serverPeakActive': peakServerActive,
  };

  Future<void> close() async {
    for (final job in jobs) {
      job.token.cancel();
      job.release();
    }
    shared.close();
    reading.close();
    await Future.wait([for (final job in jobs) job.result]);
    for (final server in _servers) {
      await server.close();
    }
  }
}

final class NetworkWorkloadJob {
  NetworkWorkloadJob(this.id);
  static const payloadBytes = 64 * 1024;
  final int id;
  final token = CancellationToken();
  final started = Completer<void>();
  final gate = Completer<void>();
  late final Future<NetworkWorkloadResult> result;
  void release() {
    if (!gate.isCompleted) gate.complete();
  }
}

final class NetworkWorkloadResult {
  const NetworkWorkloadResult({
    this.valid = false,
    this.bytes = 0,
    this.cancelled = false,
    this.error,
  });
  final bool valid, cancelled;
  final int bytes;
  final String? error;
}
