import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/publications/data/cloud_resource_search.dart';
import 'package:zero_player/features/publications/data/cloud_shared_file.dart';
import 'package:zero_player/features/publications/presentation/cloud_search_share_preview.dart';

void main() {
  testWidgets(
    'Baidu result loads details on expansion and opens its download page',
    (tester) async {
      final listing = Completer<CloudShareListing>();
      var requests = 0;
      var downloads = 0;
      final link = Uri.https('pan.baidu.com', '/s/1sample');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CloudSearchSharePreview(
              hit: CloudSearchHit(
                title: '参考资料',
                link: link,
                source: 'PanHub',
                code: 'ab12',
              ),
              inspect: (target, code, _) {
                expect(target, link);
                expect(code, 'ab12');
                requests++;
                return listing.future;
              },
              allowed: (text) => text != 'hidden.txt',
              download: () => downloads++,
              open: () {},
            ),
          ),
        ),
      );
      expect(requests, 0);
      expect(find.text('解析并选择文件'), findsNothing);
      await tester.tap(find.text('参考资料'));
      await tester.pump();
      expect(requests, 1);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      listing.complete((
        files: [
          const CloudShareItem(
            (name: 'visible.txt', id: '1', bytes: 1),
            ['资料'],
          ),
          const CloudShareItem((name: 'hidden.txt', id: '2', bytes: 1), ['资料']),
        ],
        truncated: false,
      ));
      await tester.pumpAndSettle();
      expect(find.text('资料 / visible.txt · 1 B'), findsOneWidget);
      expect(find.textContaining('hidden'), findsNothing);
      await tester.tap(find.text('解析并选择文件'));
      expect(downloads, 1);
      await tester.tap(find.text('参考资料'));
      await tester.pumpAndSettle();
      expect(find.textContaining('visible.txt'), findsNothing);
      await tester.tap(find.text('参考资料'));
      await tester.pumpAndSettle();
      expect(requests, 1);
    },
  );
}
