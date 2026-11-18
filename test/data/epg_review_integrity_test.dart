import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/document_client.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/live/data/live_repository.dart';
import '../../test_support/http_test_server.dart';

void main() {
  test(
    'EPG refresh sanitizes titles and notifies both changed tables once',
    () async {
      final db = AppDatabase.memory();
      final http = MediaHttpClient(allowPrivateNetworks: true);
      final now = DateTime.now().toUtc();
      String time(DateTime date) =>
          '${date.toIso8601String().replaceAll(RegExp('[-:T]'), '').substring(0, 14)} +0000';
      final server = await HttpTestServer.start((request) {
        request.response.headers.contentType = ContentType(
          'application',
          'xml',
          charset: 'utf-8',
        );
        request.response.write(
          '<tv><channel id="one"><display-name>Channel</display-name></channel>'
          '<programme channel="one" start="${time(now)}" stop="${time(now.add(const Duration(hours: 1)))}">'
          '<title>&lt;b&gt;Title&lt;/b&gt;${'😀' * 250}</title></programme></tv>',
        );
      });
      final events = <String>[];
      final a = db.changesFor({'app_meta'}).listen((_) => events.add('meta'));
      final b = db
          .changesFor({'epg_programs'})
          .listen((_) => events.add('epg'));
      addTearDown(() async {
        await a.cancel();
        await b.cancel();
        http.close();
        await server.close();
        await db.close();
      });
      await LiveRepository(db, DocumentClient(http)).refreshEpg(server.baseUri);
      await Future<void>.delayed(Duration.zero);
      expect(events, ['meta', 'epg']);
      final title =
          (await db.rows('SELECT title FROM epg_programs')).single['title']
              as String;
      expect(title.runes.length, 200);
      expect(title, startsWith('Title'));
      expect(title, isNot(contains('<b>')));
    },
  );
}
