import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/document_client.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/features/catalog/data/provider_factory.dart';
import 'package:zero_player/features/catalog/domain/catalog_item.dart';
import 'package:zero_player/features/sources/domain/video_source.dart';

import '../../test_support/http_test_server.dart';

void main() {
  _browseTest();
  _challengeTest();
}

void _browseTest() {
  test(
    'WebHome browsing, search and exact fallback preserve channel identities',
    () async {
      final calls = <String>[];
      final server = await HttpTestServer.start((request) async {
        expect(
          request.headers.value('referer'),
          '${request.requestedUri.origin}/',
        );
        final query = request.uri.queryParameters;
        calls.add('${query['action']}:${query['source']}:${query['id']}');
        final action = query['action'];
        request.response.write(
          jsonEncode({
            'success': true,
            if (action == 'home') ...{
              'source_used': 'official',
              'categories': {
                '电影': [_row('1', '同名电影', year: '2026')],
              },
            },
            if (action == 'search')
              'results': [
                {..._row('1', '同名电影', year: '2025'), 'source': 'wrong'},
                {..._row('1', '同名电影', year: '2026'), 'source': 'direct'},
              ],
            if (action == 'detail')
              'details': [
                {
                  ..._row(query['id']!, '同名电影', year: '2026'),
                  'episodes': [
                    {
                      'group': '线路',
                      'episodes': [
                        {
                          'name': '正片',
                          'url': query['source'] == 'official'
                              ? 'https://official.test/watch/1.html'
                              : 'https://media.test/movie.m3u8',
                        },
                      ],
                    },
                  ],
                },
              ],
          }),
        );
      });
      final http = MediaHttpClient(allowPrivateNetworks: true);
      addTearDown(() async {
        http.close();
        await server.close();
      });
      final provider = createVodProvider(
        VideoSource(
          id: 'test',
          name: '洛雪TV',
          endpoint: server.baseUri,
          kind: 'webHome',
        ),
        DocumentClient(http),
      );
      final home = await provider.browse(category: '电影');
      expect(home.categories, {'电影': '电影'});
      expect(home.page.items.single.id, 'official:1');
      final search = await provider.search('同名电影');
      expect(search.items.map((item) => item.id), ['wrong:1', 'direct:1']);
      final detail = await provider.detail(home.page.items.single.id);
      expect(detail.id, 'official:1');
      expect(detail.lines.single.name, 'direct · 线路');
      final media = await provider.resolve(detail.lines.single.episodes.single);
      expect(media.uri, Uri.parse('https://media.test/movie.m3u8'));
      expect(calls, isNot(contains('detail:wrong:1')));
      final before = calls.length;
      await expectLater(
        provider.detail('direct:../admin'),
        throwsFormatException,
      );
      expect(calls.length, before);
      await expectLater(
        provider.resolve(
          Episode(
            '解析',
            Uri.parse('https://parser.test/?url=https://media.test/movie.m3u8'),
          ),
        ),
        throwsA(isA<RemoteFailure>()),
      );
    },
  );
}

void _challengeTest() {
  test(
    'WebHome verification response is not treated as an empty success',
    () async {
      final server = await HttpTestServer.start((request) async {
        request.response.write('{"success":false,"need_captcha":true}');
      });
      final http = MediaHttpClient(allowPrivateNetworks: true);
      addTearDown(() async {
        http.close();
        await server.close();
      });
      final provider = createVodProvider(
        VideoSource(
          id: 'test',
          name: '洛雪TV',
          endpoint: server.baseUri,
          kind: 'webHome',
        ),
        DocumentClient(http),
      );
      await expectLater(provider.search('电影'), throwsFormatException);
    },
  );
}

Map<String, Object?> _row(String id, String title, {required String year}) => {
  'id': id,
  'name': title,
  'year': year,
  'type': '电影',
};
