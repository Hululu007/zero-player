import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/document_client.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/live/application/channel_preflight.dart';
import 'package:zero_player/features/live/application/live_probe.dart';
import 'package:zero_player/features/live/data/live_audit_defaults.dart';
import 'package:zero_player/features/live/data/live_health_repository.dart';
import 'package:zero_player/features/live/data/live_repository.dart';

void main() {
  for (final pending in [false, true]) {
    test(
      'preflight ${pending ? 'pending' : 'defaults'} publishes committed state',
      () async {
        final db = AppDatabase.memory();
        final http = MediaHttpClient();
        final health = LiveHealthRepository(db);
        final probe = LiveProbe(http, health);
        final live = LiveRepository(db, DocumentClient(http));
        await live.importText(
          'TV',
          Uri.parse('https://list.test/a'),
          'CCTV1,https://media.test/a.ts',
          verify: false,
        );
        final channel = (await live.channels()).single;
        final defaults = LiveAuditDefaults(
          () async => jsonEncode({
            'results': [
              if (!pending)
                {
                  'id': channel.id,
                  'signature': channel.urls.join('|'),
                  'availability': 'unavailable',
                  'checkedAt': 1234,
                  'languages': <String>[],
                },
            ],
          }),
        );
        final preflight = ChannelPreflight(defaults, health, probe);
        var events = 0;
        final sub = db
            .changesFor({'app_meta'}, metadataDomains: {MetadataDomain.live})
            .listen((_) => events++);
        addTearDown(() async {
          await sub.cancel();
          await probe.close();
          http.close();
          await db.close();
        });
        if (pending) {
          final token = CancellationToken()..cancel();
          await expectLater(
            preflight.refresh([channel], token),
            throwsA(isA<RequestCancelled>()),
          );
        } else {
          await preflight.prepare([channel]);
        }
        await Future<void>.delayed(Duration.zero);
        expect(events, 1);
        final state =
            jsonDecode(
                  (await db.rows('SELECT value FROM app_meta WHERE key=?', [
                        'live_state:${channel.id}',
                      ])).single['value']
                      as String,
                )
                as Map;
        expect(state['enabled'], false);
        if (pending) expect(state['pendingValidation'], true);
        await preflight.prepare([channel]);
        await Future<void>.delayed(Duration.zero);
        expect(
          events,
          1,
          reason: 'idempotent reads must not form a reload loop',
        );
      },
    );
  }
}
