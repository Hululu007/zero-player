import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/catalog/domain/catalog_item.dart';
import 'package:zero_player/features/downloads/data/download_repository.dart';

void main() {
  test('failed metadata removal rolls back the task deletion', () async {
    final root = await Directory.systemTemp.createTemp('download-delete-');
    final db = AppDatabase.memory();
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    final repository = DownloadRepository(db, root);
    final episode = Episode('EP1', Uri.parse('https://media.test/video.mp4'));
    final line = PlayLine('line', [episode]);
    final item = CatalogItem(
      sourceId: 's',
      id: 'w',
      title: 'Work',
      lines: [line],
    );
    final id = await repository.create(
      item,
      line,
      episode,
      {},
      destination: 'chosen',
    );
    await db.customStatement(
      "CREATE TRIGGER reject_meta_delete BEFORE DELETE ON app_meta "
      "WHEN OLD.key LIKE 'download_output:%' BEGIN SELECT RAISE(ABORT, 'blocked'); END",
    );
    await expectLater(repository.remove(id), throwsA(isA<Exception>()));
    expect(await repository.find(id), isNotNull);
    expect(await repository.output(id), 'chosen');
    await db.customStatement('DROP TRIGGER reject_meta_delete');
    await repository.remove(id);
    expect(await repository.find(id), isNull);
    expect(await repository.output(id), isNull);
  });
}
