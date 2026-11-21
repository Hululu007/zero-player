import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<T> withPublicationCatalogue<T>(
  Future<T> Function(PublicationCatalogueFixture) run,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final fixture = PublicationCatalogueFixture._(server.port);
  server.listen((request) => unawaited(fixture._serve(request)));
  try {
    return await HttpOverrides.runZoned(
      () => run(fixture),
      createHttpClient: (_) => fixture,
    );
  } finally {
    fixture.release();
    await server.close(force: true);
    fixture.close(force: true);
  }
}

final class PublicationCatalogueFixture implements HttpClient {
  PublicationCatalogueFixture._(this._port);
  static const _host = 'catalogue.fixture.example';
  final int _port;
  final _client = HttpClient()..findProxy = (_) => 'DIRECT';
  final requests = <Uri>[];
  final pending = Completer<void>();
  final _gate = Completer<void>();
  String? holdSearchAt;
  int status = HttpStatus.ok;

  static String configuration(String path) => jsonEncode({
    'version': 1,
    'kind': 'jsonSearch',
    'name': 'Catalogue',
    'endpoint': 'https://$_host$path',
    'field': {'title': 'title', 'pdf': 'link'},
  });

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  List<int> pages(String path) => [
    for (final request in requests)
      if (request.path == path) int.parse(request.queryParameters['page']!),
  ];

  Future<void> _serve(HttpRequest request) async {
    final uri = request.uri;
    final first = uri.queryParameters['page'] == '1';
    if (!pending.isCompleted &&
        first &&
        uri.path == holdSearchAt &&
        uri.queryParameters['q']?.isNotEmpty == true) {
      pending.complete();
      await _gate.future;
    }
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(
        jsonEncode([
          if (first)
            {
              'title': 'Reference ${uri.pathSegments.single}',
              'link': '/book.pdf',
            },
        ]),
      );
    await request.response.close();
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) {
    if (uri.host != _host || uri.scheme != 'https' || uri.port != 443) {
      throw const SocketException('Unexpected catalogue fixture target');
    }
    requests.add(uri);
    return _client.openUrl(
      method,
      uri.replace(scheme: 'http', host: '127.0.0.1', port: _port),
    );
  }

  @override
  void close({bool force = false}) => _client.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isSetter) return null;
    return super.noSuchMethod(invocation);
  }
}
