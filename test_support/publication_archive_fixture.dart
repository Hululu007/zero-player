import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'local_book_fixtures.dart';

const archiveFixtureId = 'alicesadventures00928gut';
const archiveFixtureTitle = "Alice's Adventures in Wonderland";
const _host = 'archive.org';
const _storage = 'dn721504.ca.archive.org';
const _metadataPath = '/metadata/$archiveFixtureId';
const _downloadPath = '/download/$archiveFixtureId/pg928.epub';
const _storagePath = '/0/items/$archiveFixtureId/pg928.epub';

Future<void> withPublicationArchiveFixture(
  Future<void> Function(String digest) run,
) async {
  final signature = 'application/epub+zip'.codeUnits;
  final archive = Archive()
    ..addFile(ArchiveFile.noCompress('mimetype', signature.length, signature));
  for (final entry in ZipDecoder().decodeBytes(sampleEpub())) {
    archive.addFile(entry);
  }
  final bytes = ZipEncoder().encode(archive);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final clients = <HttpClient>[];
  server.listen((request) => unawaited(_serve(request, bytes)));
  try {
    await HttpOverrides.runZoned(
      () => run(sha256.convert(bytes).toString()),
      createHttpClient: (_) {
        final client = _ArchiveClient(server.port);
        clients.add(client);
        return client;
      },
    );
  } finally {
    for (final client in clients) {
      client.close(force: true);
    }
    await server.close(force: true);
  }
}

Future<void> _serve(HttpRequest request, List<int> bytes) async {
  final response = request.response;
  switch (request.uri.path) {
    case '/advancedsearch.php':
      final query = request.uri.queryParameters['q'] ?? '';
      final keyword = query.contains('title:');
      if (!query.contains('mediatype:texts') ||
          query.contains('collection:gutenberg') == keyword ||
          (keyword && !query.contains(archiveFixtureTitle))) {
        response.statusCode = HttpStatus.badRequest;
        break;
      }
      _json(response, {
        'response': {
          'docs': [
            {'identifier': archiveFixtureId},
          ],
        },
      });
    case _metadataPath:
      _json(response, {
        'metadata': {
          'identifier': archiveFixtureId,
          'title': archiveFixtureTitle,
          'mediatype': 'texts',
          'collection': 'gutenberg',
          'contributor': 'Project Gutenberg',
          'uploader': 'ximm@archive.org',
          'rights': 'Public domain in the USA.',
        },
        'files': [
          {
            'name': 'pg928.epub',
            'source': 'original',
            'format': 'EPUB',
            'size': bytes.length,
          },
        ],
      });
    case _downloadPath:
      response
        ..statusCode = HttpStatus.found
        ..headers.set(
          HttpHeaders.locationHeader,
          'https://$_storage$_storagePath',
        );
    case _storagePath:
      response
        ..headers.contentType = ContentType('application', 'epub+zip')
        ..contentLength = bytes.length
        ..add(bytes);
    default:
      response.statusCode = HttpStatus.notFound;
  }
  await response.close();
}

void _json(HttpResponse response, Map<String, Object> data) {
  response
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(data));
}

// Test-only transport keeps the production request and redirect guards active.
final class _ArchiveClient implements HttpClient {
  _ArchiveClient(this.port);

  final int port;
  final _client = _BaseHttpOverrides().createHttpClient(null)
    ..findProxy = (_) => 'DIRECT';

  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) {
    if (uri.scheme != 'https' ||
        uri.port != 443 ||
        !const {_host, _storage}.contains(uri.host)) {
      throw const SocketException('Unexpected archive fixture target');
    }
    return _client.openUrl(
      method,
      uri.replace(scheme: 'http', host: '127.0.0.1', port: port),
    );
  }

  @override
  void close({bool force = false}) => _client.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.isSetter ? null : super.noSuchMethod(invocation);
}

final class _BaseHttpOverrides extends HttpOverrides {}
