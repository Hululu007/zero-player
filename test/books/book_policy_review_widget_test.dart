import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/persistence/installation_metadata.dart';
import 'package:zero_player/features/books/data/aoaostar_book_catalog.dart';
import 'package:zero_player/features/books/data/book_policy_evidence.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/book_sources_page.dart';

import '../../test_support/verified_temp_directory.dart';

void main() {
  testWidgets('saved work requires confirmation and hides on policy change', (
    tester,
  ) async {
    late VerifiedTempDirectory temp;
    late AppServices services;
    late Book book;
    await tester.runAsync(() async {
      temp = await VerifiedTempDirectory.create('book-review-widget-');
      services = AppServices.scoped(temp.directory, AppDatabase.memory());
      await services.db.write(
        'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
        [installationAccessKey, upgradedInstallationAccess],
      );
      await services.settings.load();
      await services.supervision.load();
      await services.settings.update({'filterAdult': false});
      final revision = (await AoaoStarBookCatalog.load()).revision;
      await services.books.store.write(
        'books_catalog_revision',
        '$revision:adult-all:2',
      );
      final source = BookSource.fromJson({
        'name': '本地测试来源',
        'kind': 'text',
        'format': 'feed',
        'url': 'https://review-widget.example/feed',
      });
      await services.books.importSources([source]);
      book = Book(
        source.id,
        source.kind,
        '书架复核样本',
        '测试作者',
        source.endpoint.resolve('/book/1'),
      );
      await services.books.store.saveBook(book);
      await BookPolicyEvidenceStore(
        services.db,
      ).merge(book.id, BookPolicyEvidence(adult: true), () {});
      await services.books.refreshSourceRisks();
    });
    addTearDown(() => _close(tester, services, temp));

    await tester.pumpWidget(
      MaterialApp(
        home: BookSourcesPage(services: services, kind: BookKind.text),
      ),
    );
    await _waitFor(
      tester,
      () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
    );
    await tester.tap(find.text('作品标记复核'));
    await _waitFor(tester, () => find.text('书架复核样本').evaluate().isNotEmpty);
    await tester.tap(find.text('人工复核'));
    await _waitFor(tester, () => find.text('确认解除').evaluate().isNotEmpty);
    await tester.tap(find.text('取消'));
    await _waitFor(
      tester,
      () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
    );
    await tester.runAsync(() async {
      expect(
        (await BookPolicyEvidenceStore(services.db).load())[book.id]!.adult,
        isTrue,
      );
    });

    await tester.tap(find.text('作品标记复核'));
    await _waitFor(tester, () => find.text('书架复核样本').evaluate().isNotEmpty);
    await tester.runAsync(
      () => services.settings.update({'filterAdult': true}),
    );
    await tester.pump();
    expect(find.text('书架复核样本'), findsNothing);
    expect(find.text('没有可复核的书架作品'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await _waitFor(
      tester,
      () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
    );
    await tester.runAsync(
      () => services.settings.update({'filterAdult': false}),
    );
    await tester.pump();
    await tester.tap(find.text('作品标记复核'));
    await _waitFor(tester, () => find.text('书架复核样本').evaluate().isNotEmpty);
    await tester.tap(find.text('人工复核'));
    await _waitFor(tester, () => find.text('确认解除').evaluate().isNotEmpty);
    await tester.tap(find.text('确认解除'));
    await _waitFor(
      tester,
      () => find.textContaining('已解除该作品的自动成人标记').evaluate().isNotEmpty,
    );
    await tester.runAsync(() async {
      expect(
        (await BookPolicyEvidenceStore(services.db).load())[book.id]!.adult,
        isFalse,
      );
    });
    expect(tester.takeException(), isNull);
  });
}

Future<void> _waitFor(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 400 && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(condition(), isTrue, reason: '本地异步操作应完成');
}

Future<void> _close(
  WidgetTester tester,
  AppServices services,
  VerifiedTempDirectory temp,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  var closed = false;
  final closing = services.close().whenComplete(() => closed = true);
  await _waitFor(tester, () => closed);
  await closing;
  await tester.runAsync(temp.delete);
}
