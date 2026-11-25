import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/features/publications/data/cloud_shared_catalogs.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';

import '../../test_support/publication_catalogue_fixture.dart';

final class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('invalid cached rows leave the shared catalog accessible', () async {
    final root = await Directory.systemTemp.createTemp('cloud-view-cache-');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/cloud-catalog-pcGames.json').writeAsString(
      '[null, {"name":"invalid","url":123}, '
      '{"name":"valid","url":"https://pan.quark.cn/s/1234"}]',
    );
    final transport = MediaHttpClient();
    addTearDown(transport.close);
    final catalogs = CloudSharedCatalogs(
      PublicationHttp(transport, authorize: (_) {}),
      root,
    );
    final source = CloudSharedCatalog.pcGames;
    final loading = catalogs.load(source);
    expect(catalogs.load(source), same(loading));
    final entry = await loading;
    expect(entry.link, source.uri);
    expect(entry.rows.single.name, 'valid');
  });

  test(
    'KDocs guest sync binds rows and keeps the snapshot after a broken workbook',
    () async {
      final root = await Directory.systemTemp.createTemp('kdocs-cache-');
      addTearDown(() => root.delete(recursive: true));
      final source = CloudSharedCatalog.pcSoftware;
      final share = source.uri.pathSegments.last;
      final workbook = _kdocsWorkbook();
      var broken = false;
      await HttpOverrides.runZoned(
        () => withPublicationCatalogue(
          (_) async {
            final transport = MediaHttpClient();
            try {
              final http = PublicationHttp(transport, authorize: (_) {});
              final catalogs = CloudSharedCatalogs(http, root);
              final result = await catalogs.refresh(source);
              expect(result.rows.map((row) => (row.name, row.link!.path)), [
                ('示例工具', '/s/example'),
              ]);
              expect(result.updated, isNotNull);
              broken = true;
              await expectLater(
                catalogs.refresh(source),
                throwsFormatException,
              );
              final cached = await CloudSharedCatalogs(http, root).load(source);
              expect(cached.rows.single.name, '示例工具');
              expect(cached.rows.single.link, result.rows.single.link);
            } finally {
              transport.close();
            }
          },
          host: source.uri.host,
          respond: (request) async {
            final response = request.response;
            expect(
              request.headers.value('cookie'),
              contains('hadSingleSign=true'),
            );
            if (request.uri.path == source.uri.path) {
              expect(request.method, 'GET');
              response.write(
                '<script>window.__WPSENV__=${jsonEncode({
                  'file_info': {
                    'file': {
                      'name': 'fixture.dbt',
                      'attrs': {'link_range': 'anyone', 'link_id': share},
                    },
                  },
                  'csrf_token': 'fixture-csrf',
                  'conn_id': 'fixture-guest',
                  'request_header_inject': {'x-forward-region': 'test'},
                  'user_group': 'fixture-group',
                  'file_version': 'fixture-version',
                })}; window.__WPSENV__.next={};</script>',
              );
            } else {
              expect(request.uri.path, '/api/v3/office/file/$share/open/db');
              expect(request.headers.value('x-csrf-rand'), 'fixture-csrf');
              expect(request.method, 'POST');
              final body =
                  jsonDecode(await utf8.decoder.bind(request).join()) as Map;
              expect(body['connid'], 'fixture-guest');
              expect((body['args'] as Map)['readonly'], isTrue);
              response.headers.contentType = ContentType.binary;
              response.add(
                broken ? workbook.sublist(0, workbook.length - 6) : workbook,
              );
            }
            await response.close();
          },
        ),
        createHttpClient: _RealHttp().createHttpClient,
      );
    },
  );

  test(
    'Tencent refresh pages the selected view and preserves the last complete catalog',
    () async {
      final root = await Directory.systemTemp.createTemp('cloud-views-');
      addTearDown(() => root.delete(recursive: true));
      final source = CloudSharedCatalog.pcGames;
      var changing = false;
      await HttpOverrides.runZoned(
        () => withPublicationCatalogue(
          (fixture) async {
            final transport = MediaHttpClient();
            try {
              final http = PublicationHttp(transport, authorize: (_) {});
              final catalogs = CloudSharedCatalogs(http, root);
              final result = await catalogs.refresh(source);
              expect(result.rows.map((item) => item.name), [
                for (var i = 0; i < 62; i++) 'Game $i',
              ]);
              expect(
                fixture.requests
                    .where((uri) => uri.path == '/dop-api/opendoc')
                    .map((uri) => uri.queryParameters['startrow']),
                ['0', '61'],
              );
              changing = true;
              await expectLater(
                catalogs.refresh(source),
                throwsFormatException,
              );
              final previous = await CloudSharedCatalogs(
                http,
                root,
              ).load(source);
              expect(
                previous.rows.map((item) => item.link),
                result.rows.map((item) => item.link),
              );
            } finally {
              transport.close();
            }
          },
          host: source.uri.host,
          respond: (request) async {
            final response = request.response;
            if (request.uri.path == source.uri.path) {
              response.headers
                ..add('set-cookie', 'guest=sample; Path=/; Secure')
                ..add(
                  'set-cookie',
                  'old=; expires=31 Dec 2000 23:55:55 GMT; max-age=0',
                );
              response.write(
                '<script id="opendoc-jsonp" src="/dop-api/opendoc?'
                'id=DQWtRWFNCdU9tc1J0&amp;tab=BB08J2&amp;viewId=vEjgSC&amp;'
                'callback=clientVarsCallback"></script>',
              );
            } else {
              expect(request.headers.value('cookie'), 'guest=sample');
              final first = request.uri.queryParameters['startrow'] == '0';
              response.write(_openDoc(first, changing && !first ? 2 : 1));
            }
            await response.close();
          },
        ),
        createHttpClient: _RealHttp().createHttpClient,
      );
    },
  );
}

String _openDoc(bool first, int revision) {
  final orders = [for (var i = 0; i < 62; i++) 'r$i'];
  final table = [
    [
      if (first)
        {
          't': 3005,
          'c': {
            'k1': 'BB08J2',
            'k3': {
              'k3': {
                'title': {'k30': '游戏名称', 'k31': 1},
                'download': {'k31': 8},
              },
              'k4': [
                {
                  'k30': 'vEjgSC',
                  'k3': {'k1': orders},
                },
              ],
            },
          },
        },
      {
        't': 3028,
        'c': {
          'k1': 'BB08J2',
          'k2': {
            'k1': {
              for (final (i, id) in orders.indexed)
                if (first ? i < 61 : i == 61)
                  id: {
                    'k1': {
                      'title': {
                        'k1': [
                          {'k2': 'Game $i'},
                        ],
                      },
                      'download': {
                        'k8': [
                          {'k3': 'https://pan.quark.cn/s/$id'},
                        ],
                      },
                    },
                  },
            },
          },
        },
      },
    ],
  ];
  final bytes = zlib.encode(utf8.encode(jsonEncode(table)));
  final payload = jsonEncode({
    'clientVars': {
      'calcRev': revision,
      'collab_client_vars': {
        'initialAttributedText': {
          'text': [
            {'smartsheet': base64Encode(bytes)},
          ],
        },
      },
    },
  });
  return 'clientVarsCallback($payload);';
}

Uint8List _kdocsWorkbook() {
  const keys = [
    'blockRowIndex',
    'prevStep',
    'cells',
    'ExecTokenSTR',
    'tokenMajorType',
    'str',
    'isSqLeading',
    'handle',
    'displayText',
    'address',
  ];
  final bytes = BytesBuilder();
  void number(int value, int width) {
    for (var index = 0; index < width; index++) {
      bytes.addByte(value >> (8 * index) & 255);
    }
  }

  void field(String name) => number(keys.indexOf(name) + 1, 2);
  void wide(String value, {bool length = true}) {
    if (length) number(value.codeUnits.length, 4);
    for (final char in value.codeUnits) {
      number(char, 2);
    }
  }

  number(keys.length, 2);
  for (final (index, key) in keys.indexed) {
    number(index + 1, 2);
    bytes.addByte(key.length);
    bytes.add(utf8.encode(key));
    number(0, 2);
  }
  field('blockRowIndex');
  number(0, 2);
  field('prevStep');
  number(0, 2);
  field('cells');
  field('ExecTokenSTR');
  field('tokenMajorType');
  number(0x10000000, 4);
  field('str');
  wide('示例工具');
  field('isSqLeading');
  wide('ET_HANDLE_DBHYPERLINK', length: false);
  field('handle');
  field('displayText');
  wide('打开分享');
  field('address');
  wide('https://pan.quark.cn/s/example');
  return bytes.takeBytes();
}
