import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/catalog/domain/catalog_item.dart';
import 'package:zero_player/features/downloads/application/download_failover.dart';
import 'package:zero_player/features/downloads/application/download_transfer.dart';

void main() {
  for (final bad in ['{', '[]', '{"title":42}']) {
    test('damaged download metadata fails locally: $bad', () async {
      final root = await Directory.systemTemp.createTemp(
        'download-record-review-',
      );
      final services = AppServices.scoped(root, AppDatabase.memory());
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      await services.settings.load();
      final ep = Episode('1', Uri.parse('https://unreachable.test/video.mp4'));
      final line = PlayLine('line', [ep]);
      final item = CatalogItem(
        sourceId: 's',
        id: 'w',
        title: 'Movie',
        lines: [line],
      );
      final id = await services.downloads.create(item, line, ep, {});
      await services.db.write(
        'UPDATE downloads SET work_json=?,headers=? WHERE id=?',
        [bad, bad, id],
      );
      final task = (await services.downloads.find(id))!;
      expect(
        await DownloadFailover(
          services.sources,
          services.network,
          services.settings,
        ).find(task, CancellationToken(), {}),
        isNull,
      );
      var validated = false;
      await expectLater(
        transferDownload(
          task: task,
          token: CancellationToken(),
          repository: services.downloads,
          fetcher: services.fetcher,
          http: services.http,
          limit: 1024,
          reserve: (_) {},
          validate: (_, _) async {
            validated = true;
          },
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('请求头记录损坏'),
          ),
        ),
      );
      expect(validated, isFalse);
    });
  }
}
