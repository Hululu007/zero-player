import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/publications/application/publication_discovery.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/data/publication_rule_examples.dart';
import 'package:zero_player/features/publications/data/publication_store.dart';
import 'package:zero_player/features/publications/presentation/publication_rule_editor.dart';

void main() {
  testWidgets(
    'selecting the Open Logic example saves an editable version 2 rule',
    (tester) async {
      final db = AppDatabase.memory();
      final network = MediaHttpClient();
      final discovery = PublicationDiscovery(
        PublicationStore(db),
        PublicationHttp(network, authorize: (_) {}),
        (_) => true,
      );
      addTearDown(db.close);
      addTearDown(network.close);
      addTearDown(discovery.close);
      String? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => saved = await editPublicationRule(
                  context,
                  discovery,
                  importFile: () async => null,
                ),
                child: const Text('打开规则编辑器'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开规则编辑器'));
      await tester.pumpAndSettle();
      final examples = find.text('规则示例');
      await tester.ensureVisible(examples);
      await tester.tap(examples);
      await tester.pumpAndSettle();
      await tester.tap(find.text(openLogicProjectRule['name'] as String));
      await tester.pumpAndSettle();
      expect(find.text('规则校验通过'), findsOneWidget);
      final ruleField = tester.widget<TextField>(find.byType(TextField).first);
      expect(
        ruleField.controller?.text,
        contains('builds.openlogicproject.org'),
      );
      await tester.tap(find.text('保存规则'));
      await tester.pumpAndSettle();
      final rule = jsonDecode(saved!) as Map;
      expect(rule['version'], 2);
      expect(rule['detail'], openLogicProjectRule['detail']);
    },
  );
}
