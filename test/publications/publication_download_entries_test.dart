import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/publications/domain/publication.dart';
import 'package:zero_player/features/publications/presentation/publication_catalog_cards.dart';

void main() {
  testWidgets('catalogue cards open deferred and secondary guest entries', (
    tester,
  ) async {
    final page = Uri.https('catalogue.test', '/book');
    final external = PublicationResource(
      source: 'sample',
      link: Uri.https('catalogue.test', '/external'),
      label: '其他网盘',
    );
    final lookup = PublicationResource.lookup(source: 'sample', link: page);
    final guest = PublicationResource(
      source: 'sample',
      link: Uri.https('pan.quark.cn', '/s/testbook'),
      label: '夸克网盘',
      canListFiles: true,
    );
    final calls = <(PublicationResource, bool)>[];

    Future<void> show(List<PublicationResource> resources) => tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: PublicationWorkCard(
            key: ValueKey(resources.first.link),
            editions: [
              PublicationEdition(
                id: 'sample',
                title: '示例书',
                page: page,
                resources: resources,
              ),
            ],
            featured: false,
            initiallyExpanded: true,
            covers: null,
            allowed: (_) => true,
            sourceName: (_) => '示例目录',
            onBuy: (_, _) {},
            onResource: (_, resource, external) =>
                calls.add((resource, external)),
            onPage: (_) {},
            onFind: (_) {},
            onAddToList: (_) {},
            isLocal: (_, _) => false,
          ),
        ),
      ),
    );

    await show([lookup]);
    await tester.tap(find.text('查看下载入口'));
    await show([external, guest]);
    await tester.tap(find.text('查看夸克网盘文件'));
    expect(calls, [(lookup, false), (guest, false)]);
  });
}
