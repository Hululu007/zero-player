import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/publications/application/publication_discovery.dart';
import 'package:zero_player/features/publications/data/publication_sources.dart';
import 'package:zero_player/features/publications/presentation/publication_sources_view.dart';

void main() {
  testWidgets('source filters and batch actions use the selected rows', (
    tester,
  ) async {
    final first = _source('first', '第一书源');
    final second = _source('second', '第二书源');
    final checked = <String>[];
    final toggled = <(String, bool)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PublicationSourcesView(
            sources: [_status(first), _status(second)],
            manageable: (_) => true,
            action: (_, _) async {},
            toggle: (_, _) async {},
            batchToggle: (sources, enabled) async {
              toggled.addAll(sources.map((source) => (source.id, enabled)));
            },
            batchCheck: (sources) async {
              checked.addAll(sources.map((source) => source.id));
            },
            onAdd: () {},
            onQuota: () {},
            onDirectory: () {},
            onClearDirectory: () {},
            usage: null,
            hasDirectory: false,
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'first.example');
    await tester.tap(find.text('多选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选当前结果'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 个书源'), findsOneWidget);
    expect(find.text('第二书源'), findsNothing);
    await tester.tap(find.text('批量检查'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('批量启用'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('批量停用'));
    await tester.pumpAndSettle();
    expect(checked, ['first']);
    expect(toggled, [('first', true), ('first', false)]);
  });
}

PublicationSource _source(String id, String name) => PublicationSource(
  id: id,
  name: name,
  kind: PublicationSourceKind.catalogue,
  endpoint: Uri.https('$id.example'),
);

PublicationSourceStatus _status(PublicationSource source) => (
  source: source,
  enabled: false,
  paused: false,
  favorite: false,
  problem: null,
  checked: null,
  synced: null,
  revision: null,
  hasSnapshot: false,
);
