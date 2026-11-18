import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/document_client.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/core/network/request_scheduler.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/catalog/domain/catalog_item.dart';
import 'package:zero_player/features/playback/application/line_probe.dart';
import 'package:zero_player/features/settings/application/settings_controller.dart';
import 'package:zero_player/features/sources/domain/video_source.dart';
import 'package:zero_player/features/supervision/application/content_policy.dart';
import 'package:zero_player/features/supervision/application/supervision_controller.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

import '../../test_support/http_test_server.dart';

const _item = CatalogItem(sourceId: 'fixture', id: 'movie', title: '测试电影');

void main() {
  _requestTests();
  _resolutionTest();
  _cancellationTests();
  _inflightTests();
}

void _requestTests() {
  test(
    'direct probing uses scoped headers and leaves shared clients available',
    () async {
      final seen = <String?>[];
      final server = await HttpTestServer.start((r) {
        seen.add(r.headers.value('authorization'));
        r.response.add(List.filled(256, 0x47));
      });
      addTearDown(server.close);
      final f = await _Fixture.create(server.baseUri);
      final probe = f.probe();
      expect(
        (await probe.probe(
          _item,
          Episode('1', server.baseUri.resolve('one.ts')),
          CancellationToken(),
        )).bytes,
        greaterThan(0),
      );
      expect(seen, ['Bearer fixture']);
      await probe.probe(
        _item,
        Episode('2', server.baseUri.resolve('two.ts')),
        CancellationToken(),
      );
      expect(server.calls['/two.ts'], 1);
    },
  );
  test('cross-origin media never receives source authorization', () async {
    String? authorization;
    final media = await HttpTestServer.start((r) {
      authorization = r.headers.value('authorization');
      r.response.add(List.filled(256, 0x47));
    });
    addTearDown(media.close);
    final f = await _Fixture.create(Uri.parse('https://source.example/api'));
    await f.probe().probe(
      _item,
      Episode('1', media.baseUri.resolve('movie.ts')),
      CancellationToken(),
    );
    expect(authorization, isNull);
  });
  test(
    'missing and unavailable sources never reach the media server',
    () async {
      final server = await HttpTestServer.start((r) => r.response.add([1]));
      addTearDown(server.close);
      final f = await _Fixture.create(server.baseUri);
      for (final source in [
        null,
        VideoSource(id: 'fixture', name: '来源', endpoint: server.baseUri),
      ]) {
        await expectLater(
          f
              .probe(find: (_) async => source)
              .probe(
                _item,
                Episode('1', server.baseUri.resolve('movie.ts')),
                CancellationToken(),
              ),
          throwsFormatException,
        );
      }
      expect(server.calls, isEmpty);
    },
  );
}

void _resolutionTest() {
  test('resolved playback page stays on the controlled provider path', () async {
    final server = await HttpTestServer.start((r) {
      if (r.uri.path.endsWith('.html')) {
        r.response.headers.contentType = ContentType.html;
        r.response.write(
          '<script>var player_aaaa={"url":"${r.requestedUri.resolve('/video.ts')}","encrypt":0};</script>',
        );
      } else {
        r.response.add(List.filled(256, 0x47));
      }
    });
    addTearDown(server.close);
    final f = await _Fixture.create(server.baseUri);
    final source = VideoSource(
      id: 'fixture',
      name: '来源',
      endpoint: server.baseUri,
      enabled: true,
      kind: 'macCmsHtml',
    );
    await f
        .probe(find: (_) async => source)
        .probe(
          _item,
          Episode(
            '1',
            server.baseUri.resolve('vodplay/1-1-1.html'),
            requiresResolution: true,
          ),
          CancellationToken(),
        );
    expect(server.calls, {'/vodplay/1-1-1.html': 1, '/video.ts': 1});
  });
}

void _cancellationTests() {
  test(
    'cancellation during source lookup prevents the media request',
    () async {
      final server = await HttpTestServer.start((r) => r.response.add([1]));
      addTearDown(server.close);
      final f = await _Fixture.create(server.baseUri);
      final token = CancellationToken();
      await expectLater(
        f
            .probe(
              find: (_) async {
                token.cancel();
                return f.source;
              },
            )
            .probe(
              _item,
              Episode('1', server.baseUri.resolve('movie.ts')),
              token,
            ),
        throwsA(isA<RequestCancelled>()),
      );
      expect(server.calls, isEmpty);
    },
  );
}

void _inflightTests() {
  for (final byPolicy in [false, true]) {
    test(
      'in-flight ${byPolicy ? 'policy revocation' : 'cancellation'} releases request capacity',
      () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        final server = await HttpTestServer.start((r) async {
          if (r.uri.path == '/stall.ts') {
            entered.complete();
            await release.future;
          } else {
            r.response.add(List.filled(256, 0x47));
          }
        });
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          await server.close();
        });
        final f = await _Fixture.create(server.baseUri);
        final token = CancellationToken();
        final waiting = expectLater(
          f.probe().probe(
            _item,
            Episode('1', server.baseUri.resolve('stall.ts')),
            token,
          ),
          throwsA(byPolicy ? isA<ContentBlocked>() : isA<RequestCancelled>()),
        );
        await entered.future;
        if (byPolicy) {
          f.policy.rememberSource(
            VideoSource(
              id: 'fixture',
              name: '来源',
              endpoint: server.baseUri,
              enabled: true,
              classification: 'adult',
            ),
          );
        } else {
          token.cancel();
        }
        await waiting.timeout(const Duration(seconds: 3));
        expect(token.isCancelled, !byPolicy);
        release.complete();
        final next = CatalogItem(sourceId: 'next', id: 'movie', title: '下一部');
        final source = VideoSource(
          id: 'next',
          name: '普通来源',
          endpoint: server.baseUri,
          enabled: true,
        );
        await f
            .probe(find: (_) async => source)
            .probe(
              next,
              Episode('2', server.baseUri.resolve('next.ts')),
              CancellationToken(),
            )
            .timeout(const Duration(seconds: 3));
        expect(server.calls['/next.ts'], 1);
      },
    );
  }
}

final class _Fixture {
  _Fixture(this.source, this.http, this.policy);
  final VideoSource source;
  final MediaHttpClient http;
  final ContentPolicy policy;

  static Future<_Fixture> create(Uri endpoint) async {
    final db = AppDatabase.memory();
    final settings = SettingsController(db);
    final supervision = SupervisionController(db);
    final policy = ContentPolicy(settings, supervision);
    final http = MediaHttpClient(
      allowPrivateNetworks: true,
      scheduler: RequestScheduler(globalLimit: 1, originLimit: 1),
    );
    addTearDown(() async {
      http.close();
      policy.dispose();
      supervision.dispose();
      settings.dispose();
      await db.close();
    });
    await settings.load();
    await supervision.load();
    return _Fixture(
      VideoSource(
        id: 'fixture',
        name: '来源',
        endpoint: endpoint,
        enabled: true,
        headers: const {'Authorization': 'Bearer fixture'},
      ),
      http,
      policy,
    );
  }

  EpisodeProbe probe({Future<VideoSource?> Function(String)? find}) =>
      EpisodeProbe(
        findSource: find ?? (_) async => source,
        network: DocumentClient(http),
        http: http,
        policy: policy,
      );
}
