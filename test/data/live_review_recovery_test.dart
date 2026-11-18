import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/document_client.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/live/data/live_repository.dart';
import 'package:zero_player/features/live/data/playlist_channels.dart';
import 'package:zero_player/features/live/domain/live_channel.dart';

late AppDatabase db;
late MediaHttpClient http;
late LiveRepository live;
final listUrl = Uri.parse('https://list.test/main');
const playlist =
    '#EXTM3U\n#EXTINF:-1 tvg-id="one",CCTV1\nhttps://media.test/1.ts\n'
    '#EXTINF:-1 tvg-id="two",CCTV2\nhttps://media.test/2.ts';

void main() {
  setUp(() {
    db = AppDatabase.memory();
    http = MediaHttpClient();
    live = LiveRepository(db, DocumentClient(http));
  });
  tearDown(() async {
    http.close();
    await db.close();
  });
  _identityTests();
  _corruptionTests();
}

void _identityTests() {
  test(
    'unique channel header rotation retains favorite and recent identity',
    () async {
      await live.importText(
        'List',
        listUrl,
        playlist,
        headers: {'User-Agent': 'old'},
        verify: false,
      );
      final before = (await live.channels()).first;
      await live.favorite(before, true);
      await live.watched(before);
      await live.importText(
        'List',
        listUrl,
        playlist,
        headers: {'User-Agent': 'new'},
        verify: false,
      );
      final after = (await live.channels()).firstWhere(
        (c) => c.id == before.id,
      );
      expect(after.favorite, isTrue);
      expect(after.recent, isTrue);
      expect(after.headers['User-Agent'], 'new');
      expect(await db.rows('SELECT * FROM channel_preferences'), hasLength(1));
    },
  );
  test(
    'same-name channels with distinct headers retain separate identities',
    () {
      LiveChannel variant(String id, String agent) => LiveChannel(
        id: id,
        listId: 'list',
        name: 'Channel',
        urls: [Uri.parse('https://media.test/1.ts')],
        headers: {'User-Agent': agent},
      );
      final prepared = preparePlaylistChannels(
        [variant('a', 'one'), variant('b', 'two')],
        [
          {
            'id': 'old',
            'name': 'Channel',
            'headers': jsonEncode({'User-Agent': 'old'}),
          },
        ],
        {},
      );
      expect(prepared.map((c) => c.id).toSet(), {'a', 'b'});
    },
  );
}

void _corruptionTests() {
  test(
    'bad channel JSON does not hide other channels and remains recoverable',
    () async {
      await live.importText('List', listUrl, playlist, verify: false);
      final before = await live.channels();
      await db.write('UPDATE live_channels SET headers=? WHERE id=?', [
        '{',
        before.first.id,
      ]);
      expect((await live.channels()).map((c) => c.id), [before.last.id]);
      expect(await db.rows('SELECT * FROM live_channels'), hasLength(2));
      await live.importText('List', listUrl, playlist, verify: false);
      expect(await live.channels(), hasLength(2));
    },
  );
  test('bad EPG timestamps are isolated within the selected guide', () async {
    await live.importText(
      'List',
      listUrl,
      playlist,
      epg: Uri.parse('https://guide.test/epg'),
      verify: false,
    );
    final channel = (await live.channels()).firstWhere((c) => c.tvgId == 'one');
    final end = DateTime.now()
        .add(const Duration(hours: 1))
        .millisecondsSinceEpoch;
    for (final start in [0, 'bad']) {
      await db.write('INSERT INTO epg_programs VALUES(?,?,?,?,?)', [
        'https://guide.test/epg',
        'one',
        start,
        end,
        'Programme',
      ]);
    }
    expect((await live.schedule(channel)).single.title, 'Programme');
    expect(await db.rows('SELECT * FROM epg_programs'), hasLength(2));
  });
}
