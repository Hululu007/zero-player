import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/catalog/domain/catalog_item.dart';
import 'package:zero_player/features/library/data/history_repository.dart';
import 'package:zero_player/features/supervision/data/content_records.dart';
import '../../test_support/supervision_fixture.dart';

void main() {
  test(
    'history listener rechecks filtering after a label-only change',
    () async {
      final fixture = SupervisionFixture();
      addTearDown(fixture.close);
      await fixture.load();
      final history = HistoryRepository(fixture.db, policy: fixture.policy);
      const item = CatalogItem(sourceId: 'source', id: 'item', title: '普通影片');
      final episode = Episode('第一集', Uri.parse('https://fixture.test/a.mp4'));
      await history.save(
        item,
        PlayLine('线路', [episode]),
        episode,
        const Duration(seconds: 1),
        const Duration(minutes: 30),
      );
      await Future<void>.delayed(Duration.zero);
      expect(await history.all(), hasLength(1));
      final refreshed = history.changes.asyncMap((_) => history.all()).first;
      await rememberContent(
        fixture.db,
        const CatalogItem(
          sourceId: 'source',
          id: 'item',
          title: '普通影片',
          tags: '色情',
        ),
      );
      expect(await refreshed.timeout(const Duration(seconds: 2)), isEmpty);
    },
  );
}
