import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/document_client.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/features/catalog/data/provider_factory.dart';
import 'package:zero_player/features/sources/domain/video_source.dart';
import '../../test_support/http_test_server.dart';

void main() {
  for (final scenario in ['episodes', 'pageEpisodes', 'pagination']) {
    test(
      'Kanju $scenario shape produces a format error instead of TypeError',
      () async {
        final server = await HttpTestServer.start((request) {
          final first = request.uri.path == '/v1/catalog/movie';
          final data = first
              ? {
                  'id': 'movie',
                  'title': 'Movie',
                  'episodes': scenario == 'episodes' ? {} : [],
                  'episode_pagination': {'has_more': scenario != 'episodes'},
                }
              : {
                  'episodes': scenario == 'pageEpisodes' ? {} : [{}],
                  'episode_pagination': [],
                };
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(data));
        });
        final http = MediaHttpClient(allowPrivateNetworks: true);
        addTearDown(() async {
          http.close();
          await server.close();
        });
        final provider = createVodProvider(
          VideoSource(
            id: 'kanju',
            name: 'Kanju',
            kind: 'kanju',
            endpoint: server.baseUri,
          ),
          DocumentClient(http),
        );
        await expectLater(provider.detail('movie'), throwsFormatException);
      },
    );
  }
}
