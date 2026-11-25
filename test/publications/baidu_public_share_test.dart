import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/data/publication_share.dart';
import 'package:zero_player/features/publications/data/publication_space.dart';
import 'package:zero_player/features/publications/data/publication_store.dart';
import 'package:zero_player/features/publications/data/publication_transfer.dart';
import 'package:zero_player/features/publications/domain/publication.dart';

import '../../test_support/local_book_fixtures.dart';
import '../../test_support/publication_catalogue_fixture.dart';

final _link = Uri.https('pan.baidu.com', '/s/1abcdefghijklmnopqrstuv');
final _pdf = samplePdf();
const _access = 'fixture-access-token';
final _file = {
  'fs_id': '9007199254740997',
  'server_filename': 'Reference.pdf',
  'isdir': 0,
  'size': _pdf.length,
};

void main() {
  test(
    'Baidu verifies the code and binds the selected file to its download',
    () {
      return _withShare((shares, fixture) async {
        await expectLater(
          shares.inspect(_link, null, CancellationToken()),
          _problem(PublicationProblem.shareCode),
        );
        final file = (await shares.inspect(
          _link,
          'ab12',
          CancellationToken(),
        )).single;
        expect(file.name, 'Reference.pdf');
        expect(file.id, _file['fs_id']);
        expect(file.bytes, _pdf.length);

        final download = await shares.resolve(
          AcquisitionCandidate(
            source: 'manual',
            link: _link,
            format: file.format,
            bytes: file.bytes,
            fileId: file.id,
            sharedFileName: file.name,
          ),
          null,
          'ab12',
          CancellationToken(),
        );
        expect(download.uri, Uri.https('d.pcs.baidu.com', '/file'));
        expect(download.guest, isNull);
        expect(download.referer, _link);
        expect(
          () => download.scope!(
            Uri.https('d.pcs.baidu.com.example.org', '/file'),
          ),
          _problem(PublicationProblem.unsupported),
        );
        expect(
          fixture.requests.where((uri) => uri.path == '/api/sharedownload'),
          hasLength(1),
        );
      });
    },
  );

  test(
    'authorized Baidu download writes a verified PDF through the shared transfer',
    () {
      return _withShare((shares, fixture) async {
        final file = (await shares.inspect(
          _link,
          'ab12',
          CancellationToken(),
        )).single;
        final candidate = AcquisitionCandidate(
          source: 'manual',
          link: _link,
          format: file.format,
          bytes: file.bytes,
          fileId: file.id,
          sharedFileName: file.name,
        );
        final download = await shares.resolve(
          candidate,
          null,
          'ab12',
          CancellationToken(),
          baiduAccessToken: _access,
        );
        expect(candidate.toJson().toString(), isNot(contains(_access)));
        final redirected = Uri.https('example.baidupcs.com', '/file', {
          'access_token': _access,
        });
        expect(
          () => download.scope!(redirected),
          _problem(PublicationProblem.unsupported),
        );

        final root = await Directory.systemTemp.createTemp(
          'baidu-publication-',
        );
        final db = AppDatabase.memory();
        try {
          final space = PublicationSpace(
            PublicationStore(db),
            root,
            freeBytes: (_) async => 4 << 30,
          );
          await space.store.initialize();
          final saved = await PublicationTransfer(shares.http, space).download(
            publicationId('fixture-task'),
            candidate,
            download,
            CancellationToken(),
            (_, _) async {},
            () {},
            allowRanges: download.allowRanges,
          );
          expect(await saved.readAsBytes(), _pdf);
          expect(
            fixture.requests.where((uri) => uri.host == 'd.pcs.baidu.com'),
            hasLength(1),
          );
        } finally {
          await db.close();
          await root.delete(recursive: true);
        }
      });
    },
  );

  test('Baidu rejects changed files before requesting a download', () {
    return _withShare((shares, fixture) async {
      final file = (await shares.inspectResources(
        _link,
        'ab12',
        CancellationToken(),
      )).single;
      await expectLater(
        shares.resolveResource(
          _link,
          (id: file.id, name: file.name, bytes: _pdf.length + 1),
          'ab12',
          CancellationToken(),
        ),
        _problem(PublicationProblem.invalid),
      );
      expect(
        fixture.requests.map((uri) => uri.path),
        isNot(contains('/api/sharedownload')),
      );
    });
  });

  test(
    'Baidu honors login, verification, and client download restrictions',
    () async {
      for (final (reply, problem) in [
        ({'errno': -6}, PublicationProblem.login),
        ({'errno': -20}, PublicationProblem.challenge),
        ({'errno': 0, 'list': 'client-only'}, PublicationProblem.guestLimit),
      ]) {
        await _withShare((shares, fixture) async {
          final file = (await shares.inspectResources(
            _link,
            'ab12',
            CancellationToken(),
          )).single;
          await expectLater(
            shares.resolveResource(_link, file, 'ab12', CancellationToken()),
            _problem(problem),
          );
          expect(
            fixture.requests.where((uri) => uri.path == '/api/sharedownload'),
            hasLength(1),
          );
        }, downloadReply: reply);
      }
    },
  );
}

Matcher _problem(PublicationProblem problem) => throwsA(
  isA<PublicationFailure>().having(
    (value) => value.problem,
    'problem',
    problem,
  ),
);

Future<void> _withShare(
  Future<void> Function(PublicationShareResolver, PublicationCatalogueFixture)
  run, {
  Map<String, Object?>? downloadReply,
}) => withPublicationCatalogue(
  (fixture) async {
    final transport = MediaHttpClient();
    try {
      await run(
        PublicationShareResolver(PublicationHttp(transport, authorize: (_) {})),
        fixture,
      );
    } finally {
      transport.close();
    }
  },
  host: 'pan.baidu.com',
  extraHosts: const {'d.pcs.baidu.com'},
  respond: (request) => _respond(request, downloadReply),
);

Future<void> _respond(HttpRequest request, Map<String, Object?>? reply) async {
  final response = request.response;
  final cookie = request.cookies.any((value) => value.name == 'BDCLND');
  if (request.uri.path == '/file') {
    if (request.uri.queryParameters['access_token'] == _access &&
        request.headers.value(HttpHeaders.userAgentHeader) == 'pan.baidu.com' &&
        request.cookies.isEmpty) {
      response.headers.contentType = ContentType('application', 'pdf');
      response.contentLength = _pdf.length;
      response.add(_pdf);
    } else {
      response.statusCode = HttpStatus.forbidden;
    }
    await response.close();
    return;
  }
  final body = switch (request.uri.path) {
    '/share/verify' => await _verify(request),
    '/share/list'
        when cookie && request.uri.queryParameters['dir'] == '/Books' =>
      {
        'errno': 0,
        'list': [_file],
      },
    '/share/tplconfig' when cookie => {
      'errno': 0,
      'data': {'sign': 'fixture-signature', 'timestamp': 1795420000},
    },
    '/api/sharedownload' when cookie => await _download(request, reply),
    _ => null,
  };
  if (body != null) {
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
  } else if (request.uri.path == _link.path) {
    response.headers.contentType = ContentType.html;
    response.cookies.add(Cookie('BAIDUID', 'fixture-guest')..path = '/');
    if (!cookie) {
      response.write('<script>window.SHAREPAGETYPE = "init";</script>');
    } else {
      response.write('<script id="locals-data" type="application/json">');
      response.write(
        jsonEncode({
          'shareid': '12',
          'share_uk': '34',
          'file_list': [
            {'isdir': 1, 'path': '/Books'},
          ],
        }),
      );
      response.write('</script>');
    }
  } else {
    response.statusCode = HttpStatus.badRequest;
  }
  await response.close();
}

Future<Map> _verify(HttpRequest request) async {
  final fields = Uri.splitQueryString(await utf8.decoder.bind(request).join());
  if (fields['pwd'] != 'ab12' ||
      request.uri.queryParameters['surl'] != 'abcdefghijklmnopqrstuv') {
    return {'errno': -9};
  }
  request.response.cookies.add(Cookie('BDCLND', 'fixture-ticket')..path = '/');
  return {'errno': 0, 'randsk': 'fixture-ticket'};
}

Future<Map> _download(HttpRequest request, Map<String, Object?>? reply) async {
  final fields = Uri.splitQueryString(await utf8.decoder.bind(request).join());
  if (fields['fid_list'] != '[${_file['fs_id']}]' ||
      fields['uk'] != '34' ||
      fields['primaryid'] != '12' ||
      jsonDecode(fields['extra'] ?? '{}')['sekey'] != 'fixture-ticket' ||
      request.uri.queryParameters['sign'] != 'fixture-signature') {
    return {'errno': -1};
  }
  return reply ??
      {
        'errno': 0,
        'list': [
          {..._file, 'dlink': 'https://d.pcs.baidu.com/file'},
        ],
      };
}
