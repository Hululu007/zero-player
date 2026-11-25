import 'dart:async';
import 'dart:io';

import 'cancellation_token.dart';
import 'header_policy.dart';
import 'request_scheduler.dart';
import 'request_trace.dart';
import 'network_target_policy.dart';
import 'source_certificate.dart';

final class HttpPayload {
  const HttpPayload(this.uri, this.response, this.body);
  final Uri uri;
  final HttpClientResponse response;
  final Stream<List<int>> body;
}

/// Shared transport with scoped headers, cancellation and a bounded scheduler.
/// Consumers must subscribe to or cancel the response body to release a permit.
final class MediaHttpClient {
  MediaHttpClient({
    this.timeout = const Duration(seconds: 15),
    this.maxConnectionsPerHost = 4,
    RequestScheduler? scheduler,
    bool allowPrivateNetworks = false,
    bool Function(Uri)? allowLanOrigin,
    bool allowLegacyQueryEncoding = false,
    this.publicHttpsRoute,
  }) : _scheduler =
           scheduler ?? RequestScheduler(globalLimit: 20, playbackReserve: 2),
       _ownsScheduler = scheduler == null,
       targetPolicy = NetworkTargetPolicy(
         allowPrivateNetworks: allowPrivateNetworks,
         allowLanOrigin: allowLanOrigin,
         allowLegacyQueryEncoding: allowLegacyQueryEncoding,
       ) {
    _configureClient(_client);
  }

  void _configureClient(
    HttpClient client, {
    SourceCertificate? certificate,
    Uri? legacyQueryTarget,
  }) {
    client.connectionTimeout = timeout;
    client.connectionFactory = (uri, proxy, port) {
      Future<ConnectionTask<Socket>> direct() => targetPolicy.connect(
        uri,
        proxy,
        port,
        certificate: certificate,
        timeout: timeout,
        legacyQueryEncoding: uri == legacyQueryTarget,
      );
      final route = publicHttpsRoute;
      if (route == null || proxy != null || uri.scheme != 'https') {
        return direct();
      }
      return route(
        uri,
        certificate,
      ).then((connection) => connection ?? direct());
    };
    client.findProxy = (_) => 'DIRECT';
    client.autoUncompress = false;
    client.maxConnectionsPerHost = maxConnectionsPerHost;
    client.idleTimeout = const Duration(seconds: 20);
    client.userAgent = 'ZeroPlayer/0.1';
  }

  final Duration timeout;
  final int maxConnectionsPerHost;
  final NetworkTargetPolicy targetPolicy;
  final Future<ConnectionTask<Socket>?> Function(Uri, SourceCertificate?)?
  publicHttpsRoute;
  final RequestScheduler _scheduler;
  final bool _ownsScheduler;
  HttpClient _client = HttpClient();
  bool _closed = false;

  void resetConnections() {
    if (_closed) return;
    _client.close(force: true);
    _client = HttpClient();
    _configureClient(_client);
  }

  Future<HttpPayload> open(
    Uri uri, {
    required HeaderPolicy policy,
    String method = 'GET',
    List<int>? body,
    String? range,
    String? ifRange,
    CancellationToken? cancellation,
    RequestPriority priority = RequestPriority.playback,
    void Function(bool active)? onActivity,
    void Function(Uri target)? validateTarget,
    Uri Function(Uri target)? mapRedirect,
    SourceCertificate? certificate,
    bool followRedirects = true,
    bool legacyQueryEncoding = false,
  }) async {
    if (!{'GET', 'POST'}.contains(method) ||
        (body != null && (method != 'POST' || body.length > 65536)) ||
        (legacyQueryEncoding && (method != 'GET' || followRedirects))) {
      throw const FormatException('不支持的请求方式或请求体过大');
    }
    final initialOrigin = HeaderPolicy.origin(uri);
    final legacyQueryTarget = legacyQueryEncoding ? uri : null;
    for (var redirects = 0; redirects <= 5; redirects++) {
      cancellation?.check();
      validateTarget?.call(uri);
      targetPolicy.validateAccess(
        uri,
        originalOrigin:
            HeaderPolicy.origin(uri) == initialOrigin &&
            policy.containsOrigin(uri),
        legacyQueryEncoding: uri == legacyQueryTarget,
      );
      final headers = policy.forUri(uri);
      final scoped =
          method == 'GET' &&
              range == null &&
              certificate?.permits(uri, headers) == true
          ? certificate
          : null;
      onActivity?.call(false);
      final permit = await _scheduler.acquire(
        uri,
        priority: priority,
        cancellation: cancellation,
      );
      final payload = await _openResource(
        uri,
        method,
        headers,
        permit,
        body: body,
        range: range,
        ifRange: HeaderPolicy.origin(uri) == initialOrigin ? ifRange : null,
        cancellation: cancellation,
        onActivity: onActivity,
        certificate: scoped,
        legacyQueryTarget: uri == legacyQueryTarget ? uri : null,
      );
      if (!followRedirects ||
          method != 'GET' ||
          !{301, 302, 303, 307, 308}.contains(payload.response.statusCode)) {
        return payload;
      }
      final location = payload.response.headers.value(
        HttpHeaders.locationHeader,
      );
      await payload.body.take(0).drain<void>();
      if (location == null) throw const HttpException('Missing Location');
      final rawTarget = uri.resolve(location);
      final target = mapRedirect?.call(rawTarget) ?? rawTarget;
      if (scoped != null && !scoped.permits(target, policy.forUri(target))) {
        throw const HttpException('证书例外期间禁止跳转到未确认的地址');
      }
      uri = target;
    }
    throw const HttpException('Redirect limit exceeded');
  }

  Future<HttpPayload> _openResource(
    Uri uri,
    String method,
    Map<String, String> headers,
    RequestPermit permit, {
    required List<int>? body,
    required String? range,
    required String? ifRange,
    required CancellationToken? cancellation,
    required void Function(bool)? onActivity,
    required SourceCertificate? certificate,
    required Uri? legacyQueryTarget,
  }) async {
    HttpClientRequest? request;
    void Function()? remove;
    HttpClient? isolated;
    final watch = Stopwatch();
    try {
      onActivity?.call(true);
      watch.start();
      cancellation?.check();
      if (certificate != null || legacyQueryTarget != null) {
        if (certificate?.active() == false) throw const RequestCancelled();
        isolated = HttpClient();
        _configureClient(
          isolated,
          certificate: certificate,
          legacyQueryTarget: legacyQueryTarget,
        );
      }
      request = await _createRequest(
        isolated ?? _client,
        uri,
        cancellation,
        method,
      );
      request.followRedirects = false;
      if (certificate != null) {
        if (!certificate.active()) throw const RequestCancelled();
        request.persistentConnection = false;
      }
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      headers.forEach(request.headers.set);
      if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
      if (ifRange != null) {
        request.headers.set(HttpHeaders.ifRangeHeader, ifRange);
      }
      remove = cancellation?.listen(
        () => request!.abort(const RequestCancelled()),
      );
      cancellation?.check();
      if (body != null) {
        request.contentLength = body.length;
        request.add(body);
      }
      final response = await request.close().timeout(timeout);
      _recordResponse(
        uri,
        watch.elapsedMilliseconds,
        request.headers,
        response,
      );
      final scopedClient = isolated;
      return HttpPayload(
        uri,
        response,
        _body(
          response,
          request,
          remove,
          cancellation,
          permit,
          onRelease: scopedClient == null
              ? null
              : () => scopedClient.close(force: true),
        ),
      );
    } catch (error) {
      recordRequestTrace(
        uri: uri,
        elapsedMs: watch.elapsedMilliseconds,
        requestHeaders: headers,
        error: error.runtimeType.toString(),
      );
      request?.abort();
      remove?.call();
      isolated?.close(force: true);
      permit.release();
      rethrow;
    }
  }

  Future<HttpClientRequest> _createRequest(
    HttpClient client,
    Uri uri,
    CancellationToken? token,
    String method,
  ) async {
    final result = Completer<HttpClientRequest>();
    var abandoned = false;
    final remove = token?.listen(() {
      abandoned = true;
      if (!result.isCompleted) result.completeError(const RequestCancelled());
    });
    unawaited(
      client
          .openUrl(method, uri)
          .then(
            (request) {
              if (abandoned) {
                request.done.ignore();
                request.abort();
              } else {
                result.complete(request);
              }
            },
            onError: (Object error, StackTrace stack) {
              if (!result.isCompleted) result.completeError(error, stack);
            },
          ),
    );
    try {
      return await result.future.timeout(timeout);
    } finally {
      abandoned = true;
      remove?.call();
    }
  }

  void _recordResponse(
    Uri uri,
    int elapsed,
    HttpHeaders headers,
    HttpClientResponse response,
  ) => recordRequestTrace(
    uri: uri,
    elapsedMs: elapsed,
    requestHeaders: diagnosticHttpHeaders(headers),
    status: response.statusCode,
    responseHeaders: {
      for (final name in [
        'content-type',
        'content-length',
        'server',
        'location',
      ])
        name: ?response.headers.value(name),
    },
  );

  Stream<List<int>> _body(
    HttpClientResponse response,
    HttpClientRequest request,
    void Function()? remove,
    CancellationToken? cancellation,
    RequestPermit permit, {
    void Function()? onRelease,
  }) {
    StreamSubscription<List<int>>? upstream;
    late final StreamController<List<int>> body;
    void release() {
      remove?.call();
      permit.release();
      onRelease?.call();
    }

    body = StreamController<List<int>>(
      onListen: () {
        upstream = response
            .timeout(timeout)
            .listen(
              (chunk) {
                if (cancellation?.isCancelled == true) {
                  body.addError(const RequestCancelled());
                } else {
                  body.add(chunk);
                }
              },
              onError: (Object error, StackTrace stack) =>
                  body.addError(error, stack),
              onDone: () {
                release();
                body.close();
              },
            );
      },
      onPause: () => upstream?.pause(),
      onResume: () => upstream?.resume(),
      onCancel: () async {
        // Rejected/partial bodies must cancel the actual upstream subscription,
        // including a take(0) consumer which never reads a payload chunk.
        request.abort();
        try {
          await upstream?.cancel();
        } finally {
          release();
        }
      },
    );
    remove?.call();
    remove = cancellation?.listen(() {
      if (!body.isClosed) body.addError(const RequestCancelled());
      request.abort(const RequestCancelled());
    });
    return body.stream;
  }

  void close() {
    _closed = true;
    _client.close(force: true);
    if (_ownsScheduler) _scheduler.close();
  }
}
