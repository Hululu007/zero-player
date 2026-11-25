import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/features/publications/data/cloud_drive_accounts.dart';
import 'package:zero_player/features/publications/data/cloud_resource_search.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/data/publication_share.dart';
import 'package:zero_player/features/publications/domain/publication.dart';
import 'package:zero_player/features/publications/domain/share_text.dart';

import '../../test_support/publication_catalogue_fixture.dart';

void main() {
  test(
    'Tianyi and Mobile share identifiers survive paste and search deduplication',
    () {
      final mobile = publicationShareInputs(
        'https://caiyun.139.com/shareweb/#/w/i/abcdefgh?pwd=ab12',
      ).single;
      expect(
        mobile.link.toString(),
        'https://yun.139.com/shareweb/#/w/i/abcdefgh',
      );
      expect(mobile.code, 'ab12');
      String key(Uri link) =>
          CloudSearchHit(title: 'T', link: link, source: 'S').key;
      expect(
        key(mobile.link),
        key(
          Uri.parse('https://caiyun.139.com/shareweb/#/w/i/abcdefgh?pwd=1234'),
        ),
      );
      expect(
        key(mobile.link),
        isNot(key(Uri.parse('https://yun.139.com/shareweb/#/w/i/different'))),
      );
      final tianyi = publicationShareInputs(
        'https://cloud.189.cn/web/share?code=abcdefgh&accessCode=cd34',
      ).single;
      expect(tianyi.link.toString(), 'https://cloud.189.cn/t/abcdefgh');
      expect(tianyi.code, 'cd34');
      expect(
        key(tianyi.link),
        key(Uri.parse('https://h5.cloud.189.cn/share.html#/t/abcdefgh')),
      );
    },
  );

  test(
    'Tianyi verifies the code, maps nested files and scopes authorization',
    () {
      final link = Uri.https('cloud.189.cn', '/web/share', {
        'code': 'abcdefgh',
      });
      const credential = 'tianyi-fixture-access-token';
      var downloadCalls = 0;
      return _withShares(
        (shares, accounts) async {
          await expectLater(
            shares.inspectTree(link, null, CancellationToken()),
            _problem(PublicationProblem.shareCode),
          );
          final tree = await shares.inspectTree(
            link,
            'ab12',
            CancellationToken(),
          );
          expect(tree.truncated, isFalse);
          final item = tree.files.single;
          expect(item.folders, ['reference']);
          expect(item.file, (name: 'test.pdf', id: '10:34', bytes: 52));
          await expectLater(
            shares.resolveResource(
              link,
              item.file,
              'ab12',
              CancellationToken(),
            ),
            _problem(PublicationProblem.login),
          );
          accounts.useTianyi(credential);
          final download = await shares.resolveResource(
            link,
            item.file,
            'ab12',
            CancellationToken(),
          );
          expect(download.uri.host, 'download.cloud.189.cn');
          expect(download.guest, isNull);
          expect(downloadCalls, 1);
          expect(
            () => download.scope!(
              Uri.https('download.cloud.189.cn.example.org', '/file'),
            ),
            _problem(PublicationProblem.unsupported),
          );
        },
        host: 'api.cloud.189.cn',
        respond: (request) async {
          final query = request.uri.queryParameters;
          switch (request.uri.path) {
            case '/open/share/getShareInfoByCodeV2.action':
              expect(request.headers.value('AccessToken'), isNull);
              expect(request.method, 'POST');
              expect(
                Uri.splitQueryString(await utf8.decoder.bind(request).join()),
                {'shareCode': 'abcdefgh'},
              );
              return _respond(request, {
                'res_code': 0,
                'fileId': '1',
                'fileName': 'root',
                'shareMode': 1,
                'needAccessCode': 1,
                'isFolder': true,
              });
            case '/open/share/checkAccessCode.action':
              expect(request.headers.value('AccessToken'), isNull);
              final form = Uri.splitQueryString(
                await utf8.decoder.bind(request).join(),
              );
              expect(form['accessCode'], 'ab12');
              expect(form['uuid'], matches(RegExp(r'^[a-f0-9]{32}$')));
              return _respond(request, {'res_code': 0, 'shareId': 345});
            case '/open/share/listShareDir.action':
              expect(request.headers.value('AccessToken'), isNull);
              expect(query['shareId'], '345');
              expect(query['accessCode'], 'ab12');
              return _respond(request, {
                'res_code': 0,
                'fileListAO': {
                  'count': 1,
                  if (query['fileId'] == '1')
                    'folderList': [
                      {'id': 10, 'name': 'reference'},
                    ]
                  else
                    'fileList': [
                      {'id': 34, 'name': 'test.pdf', 'size': 52},
                    ],
                },
              });
            case '/open/file/getFileDownloadUrl.action':
              downloadCalls++;
              expect(request.headers.value('AccessToken'), credential);
              expect(
                request.headers.value('Signature'),
                matches(RegExp(r'^[0-9a-f]{32}$')),
              );
              expect(query, {'fileId': '34', 'shareId': '345', 'dt': '1'});
              return _respond(request, {
                'res_code': 0,
                'fileDownloadUrl': 'https://download.cloud.189.cn/file',
              });
            default:
              throw StateError('Unexpected Tianyi request');
          }
        },
      );
    },
  );

  test(
    'Mobile follows pages and uses the selected file only with its account',
    () {
      final link = Uri.parse('https://yun.139.com/shareweb/#/w/i/abcdefgh');
      const authorization = 'Basic c2FtcGxlLWF1dGhvcml6YXRpb24=';
      final firstOffsets = <int>[];
      return _withShares(
        (shares, accounts) async {
          final tree = await shares.inspectTree(
            link,
            'ab12',
            CancellationToken(),
          );
          expect(tree.truncated, isFalse);
          expect(firstOffsets.take(2), [1, 51]);
          final item = tree.files.last;
          expect(item.folders, ['sub']);
          expect(item.file, (name: 'test.txt', id: 'child:second', bytes: 257));
          await expectLater(
            shares.resolveResource(
              link,
              item.file,
              'ab12',
              CancellationToken(),
            ),
            _problem(PublicationProblem.login),
          );
          accounts.useMobile('13000000000', authorization);
          final download = await shares.resolveResource(
            link,
            item.file,
            'ab12',
            CancellationToken(),
          );
          expect(download.uri.host, 'cdn.yun.139.com');
          expect(download.guest, isNull);
          expect(
            () => download.scope!(Uri.https('example.org', '/file')),
            _problem(PublicationProblem.unsupported),
          );
        },
        host: 'share-kd-njs.yun.139.com',
        respond: (request) async {
          final payload =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          switch (request.uri.pathSegments.last) {
            case 'getOutLinkInfoV6':
              expect(request.headers.value('authorization'), isNull);
              final input = payload['getOutLinkInfoReq'] as Map;
              final folder = input['pCaID'];
              final offset = input['bNum'] as int;
              if (folder == 'root') firstOffsets.add(offset);
              expect(input['linkID'], 'abcdefgh');
              expect(input['passwd'], 'ab12');
              return _respond(request, {
                'resultCode': '0',
                'data': {
                  'nodNum': folder == 'root' ? 51 : 1,
                  if (folder == 'root' && offset == 1)
                    'coLst': [
                      for (var n = 0; n < 50; n++)
                        {'coID': 'f$n', 'coName': 'file$n.txt', 'coSize': 1},
                    ]
                  else if (folder == 'root')
                    'caLst': [
                      {'caID': 'child', 'caName': 'sub'},
                    ]
                  else
                    'coLst': [
                      {'coID': 'second', 'coName': 'test.txt', 'coSize': '257'},
                    ],
                },
              });
            case 'getContentInfoFromOutLink':
              expect(request.headers.value('authorization'), isNull);
              return _respond(request, {
                'resultCode': '0',
                'data': {
                  'contentInfo': {'presentURL': 'https://yun.139.com/preview'},
                },
              });
            case 'dlFromOutLinkV3':
              expect(request.headers.value('authorization'), authorization);
              expect(payload['dlFromOutLinkReqV3'], {
                'account': '13000000000',
                'linkID': 'abcdefgh',
                'passwd': 'ab12',
                'coIDLst': {
                  'item': ['second'],
                },
              });
              return _respond(request, {
                'resultCode': '0',
                'data': {
                  'extInfo': {'cdnDownloadUrl': 'https://cdn.yun.139.com/file'},
                },
              });
            default:
              throw StateError('Unexpected Mobile request');
          }
        },
      );
    },
  );

  test('123 Cloud uses fresh metadata and reports sharing quota', () {
    final link = Uri.https('www.123pan.cn', '/s/abcdefgh.html');
    return _withShares(
      (shares, _) async {
        final tree = await shares.inspectTree(link, null, CancellationToken());
        expect(tree.files.single.file, (
          name: 'test.pdf',
          id: '0:5',
          bytes: 123,
        ));
        await expectLater(
          shares.resolveResource(
            link,
            tree.files.single.file,
            null,
            CancellationToken(),
          ),
          _problem(PublicationProblem.guestLimit),
        );
      },
      host: 'yun.123pan.com',
      respond: (request) async {
        if (request.uri.path.endsWith('/get')) {
          expect(request.uri.queryParameters['shareKey'], 'abcdefgh');
          return _respond(request, {
            'code': 0,
            'data': {
              'Next': '-1',
              'InfoList': [
                {
                  'Type': 0,
                  'FileId': 5,
                  'FileName': 'test.pdf',
                  'Size': 123,
                  'Etag': 'original-etag',
                  'S3KeyFlag': 'storage',
                },
              ],
            },
          });
        }
        expect(request.uri.path, '/b/api/share/download/info');
        final data = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(data['etag'], 'original-etag');
        expect(data['fileId'], 5);
        return _respond(request, {'code': 5112, 'message': '分享方提取流量包不足'});
      },
    );
  });

  test('Baidu access tokens are replaceable and cleared with the session', () {
    final accounts = CloudDriveAccounts();
    expect(accounts.baiduToken, isNull);
    accounts.useBaiduToken('fixture-baidu-authorized-token');
    expect(accounts.baiduToken, 'fixture-baidu-authorized-token');
    expect(
      () => accounts.useBaiduToken('invalid token'),
      throwsFormatException,
    );
    expect(accounts.baiduToken, 'fixture-baidu-authorized-token');
    accounts.useBaiduToken('fixture-baidu-replacement-token');
    expect(accounts.baiduToken, 'fixture-baidu-replacement-token');
    accounts.clear();
    expect(accounts.baiduToken, isNull);
  });
}

Future<void> _withShares(
  Future<void> Function(PublicationShareResolver, CloudDriveAccounts) run, {
  required String host,
  required Future<void> Function(HttpRequest) respond,
}) => withPublicationCatalogue(
  (_) async {
    final transport = MediaHttpClient();
    try {
      final http = PublicationHttp(transport, authorize: (_) {});
      final accounts = CloudDriveAccounts();
      await run(
        PublicationShareResolver(http, cloudAccounts: accounts),
        accounts,
      );
    } finally {
      transport.close();
    }
  },
  host: host,
  respond: respond,
);

Future<void> _respond(HttpRequest request, Map body, {int status = 200}) async {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  await request.response.close();
}

Matcher _problem(PublicationProblem value) => throwsA(
  isA<PublicationFailure>().having((error) => error.problem, 'problem', value),
);
