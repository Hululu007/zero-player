import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/persistence/installation_metadata.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/book_search_page.dart';

void main() {
  testWidgets('adult evidence immediately hides an open source dialog', (
    tester,
  ) async {
    final f = await _Fixture.create(tester);
    final ordinary = _featured('ordinary.example', '普通来源', '星际普通作品');
    final restricted = _featured('restricted.example', '待限制来源', '星际限制作品');
    await f.install([ordinary, restricted]);
    var searches = 0;
    await tester.pumpWidget(f.page(onSearchStarted: () => searches++));
    await _waitFor(
      tester,
      'initial results',
      () =>
          find.text('星际普通作品').evaluate().isNotEmpty &&
          find.text('星际限制作品').evaluate().isNotEmpty,
    );
    expect(find.text('星际普通作品'), findsOneWidget);
    expect(find.text('星际限制作品'), findsOneWidget);
    expect(searches, 1);

    await tester.tap(find.text('星际限制作品'));
    await tester.pumpAndSettle();
    expect(find.text('待限制来源'), findsOneWidget);
    await f.run(
      'record adult evidence',
      () => f.services.books.markSourceRisk(restricted, adult: true),
    );
    await tester.pump();
    expect(find.text('待限制来源'), findsNothing);
    expect(find.text('星际限制作品'), findsNothing);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await _waitFor(
      tester,
      'unrestricted results after policy refresh',
      () =>
          find.text('星际普通作品').evaluate().isNotEmpty &&
          find.text('星际限制作品').evaluate().isEmpty,
    );
    expect(find.text('星际普通作品'), findsOneWidget);
    expect(find.text('星际限制作品'), findsNothing);
    expect(searches, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('current enabled source snapshot bounds existing results', (
    tester,
  ) async {
    final f = await _Fixture.create(tester, adultAccess: true);
    final keep = _featured('keep.example', '保留来源', '星际保留');
    final removed = _featured('removed.example', '移除来源', '星际移除');
    final disabled = _featured('disabled.example', '停用来源', '星际停用');
    final old = _featured('www.switch.example', '换域来源', '星际换域旧版');
    final changed = _featured('switch.example', '换域来源', '星际换域新版');
    expect(changed.id, old.id);
    await f.install([keep, removed, disabled, old]);
    var searches = 0;
    await tester.pumpWidget(f.page(onSearchStarted: () => searches++));
    await _waitFor(
      tester,
      'initial source snapshot',
      () =>
          find.text('星际移除').evaluate().isNotEmpty &&
          find.text('星际停用').evaluate().isNotEmpty &&
          find.text('星际换域旧版').evaluate().isNotEmpty,
    );
    expect(find.text('星际移除'), findsOneWidget);
    expect(find.text('星际停用'), findsOneWidget);
    expect(find.text('星际换域旧版'), findsOneWidget);

    final repo = f.services.books;
    await f.run('remove source', () => repo.removeSource(removed));
    // Adult filtering is disabled, so a historical orphan may still pass this
    // generic predicate. It must nevertheless disappear from search results.
    expect(repo.bookAllowed(removed.featured.single), isTrue);
    await f.run(
      'disable source',
      () => repo.saveSource(disabled, {'enabled': false}),
    );
    await f.run(
      'change source host',
      () => repo.saveSource(old, {'source': changed.toJson()}),
    );
    final added = _featured('added.example', '新增来源', '星际新增');
    await f.install([added]);
    await _waitFor(
      tester,
      'filter changed source snapshot',
      () =>
          find.text('星际保留').evaluate().isNotEmpty &&
          find.text('星际移除').evaluate().isEmpty &&
          find.text('星际停用').evaluate().isEmpty &&
          find.text('星际换域旧版').evaluate().isEmpty,
    );
    expect(find.text('星际保留'), findsOneWidget);
    expect(find.text('星际移除'), findsNothing);
    expect(find.text('星际停用'), findsNothing);
    expect(find.text('星际换域旧版'), findsNothing);
    expect(find.text('星际换域新版'), findsNothing);
    expect(find.text('星际新增'), findsNothing);
    expect(searches, 1);

    await tester.tap(find.byTooltip('搜索'));
    await _waitFor(
      tester,
      'new explicit search',
      () =>
          find.text('星际换域新版').evaluate().isNotEmpty &&
          find.text('星际新增').evaluate().isNotEmpty,
    );
    expect(find.text('星际换域新版'), findsOneWidget);
    expect(find.text('星际新增'), findsOneWidget);
    expect(searches, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tightened query policy clears input and dialog details', (
    tester,
  ) async {
    final f = await _Fixture.create(tester, adultAccess: true);
    final source = _featured('ordinary-query.example', '查询来源', '色情作品');
    await f.install([source]);
    var searches = 0;
    await tester.pumpWidget(
      f.page(query: '色情', onSearchStarted: () => searches++),
    );
    await _waitFor(
      tester,
      'initial restricted-query result',
      () => find.text('色情作品').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('色情作品'));
    await tester.pumpAndSettle();
    expect(find.text('查询来源'), findsOneWidget);
    await f.run(
      'enable adult filtering',
      () => f.services.settings.update({'filterAdult': true}),
    );
    await tester.pump();
    expect(find.text('查询来源'), findsNothing);
    expect(find.text('色情作品'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    await tester.pump();
    expect(find.text('选择来源'), findsOneWidget);
    expect(searches, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('policy change cancels an in-progress search until requested', (
    tester,
  ) async {
    final f = await _Fixture.create(tester);
    await f.install([_featured('running.example', '执行来源', '星际执行结果')]);
    var searches = 0;
    await tester.pumpWidget(
      f.page(
        onSearchStarted: () {
          searches++;
          if (searches == 1) f.services.books.suspendSourceRisks();
        },
      ),
    );
    await _waitFor(
      tester,
      'search cancellation',
      () => find.textContaining('已取消').evaluate().isNotEmpty,
    );
    expect(find.textContaining('已取消'), findsWidgets);
    expect(find.text('星际执行结果'), findsNothing);
    await f.run('resume risk snapshot', f.services.books.resumeSourceRisks);
    await tester.pump();
    expect(searches, 1);
    expect(find.text('星际执行结果'), findsNothing);
    await tester.tap(find.byTooltip('搜索'));
    await _waitFor(
      tester,
      'restart explicitly after cancellation',
      () => find.text('星际执行结果').evaluate().isNotEmpty,
    );
    expect(searches, 2);
    expect(find.text('星际执行结果'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'snapshot interruption before search starts resumes that search',
    (tester) async {
      final f = await _Fixture.create(tester);
      await f.install([_featured('starting.example', '启动来源', '星际启动结果')]);
      var interrupted = false;
      var searches = 0;
      await tester.pumpWidget(
        f.page(
          beforeSourceSnapshotForTesting: () {
            if (!interrupted) {
              interrupted = true;
              f.services.books.suspendSourceRisks();
            }
          },
          onSearchStarted: () => searches++,
        ),
      );
      await tester.pump();
      expect(searches, 0);
      await f.run(
        'resume startup risk snapshot',
        f.services.books.resumeSourceRisks,
      );
      await _waitFor(
        tester,
        'resume interrupted initial search',
        () => find.text('星际启动结果').evaluate().isNotEmpty,
      );
      expect(searches, 1);
      expect(find.text('星际启动结果'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('pending risk mutation keeps old results and dialog hidden', (
    tester,
  ) async {
    final f = await _Fixture.create(tester);
    final ordinary = _featured('pending-safe.example', '正常待核来源', '星际保留作品');
    final restricted = _featured('pending-risk.example', '变更中来源', '星际待核作品');
    await f.install([ordinary, restricted]);
    var searches = 0;
    await tester.pumpWidget(f.page(onSearchStarted: () => searches++));
    await _waitFor(
      tester,
      'results before held mutation',
      () =>
          find.text('星际待核作品').evaluate().isNotEmpty &&
          find.text('星际保留作品').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('星际待核作品'));
    await tester.pumpAndSettle();
    expect(find.text('变更中来源'), findsOneWidget);

    final repo = f.services.books;
    late Completer<void> release;
    late Future<void> marking;
    await f.run('start held evidence mutation', () async {
      final entered = Completer<void>();
      release = Completer<void>();
      repo.beforeEvidenceMutationForTesting = () async {
        entered.complete();
        await release.future;
      };
      marking = repo.markSourceRisk(restricted, adult: true);
      await entered.future;
    });
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await f.run('finish held evidence mutation', () async {
        await marking;
        repo.beforeEvidenceMutationForTesting = null;
      });
    });

    expect(repo.sourceRiskMutationPending, isTrue);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.text('变更中来源'), findsNothing);
    expect(find.text('星际待核作品'), findsNothing);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('星际保留作品'), findsNothing);

    // An explicit search during the mutation must wait, not use the old rules.
    await tester.tap(find.byTooltip('搜索'));
    await tester.pump();
    expect(searches, 1);
    expect(find.byTooltip('取消搜索'), findsOneWidget);
    await f.run('commit held evidence mutation', () async {
      release.complete();
      await marking;
      repo.beforeEvidenceMutationForTesting = null;
    });
    await _waitFor(
      tester,
      'explicit search after held mutation',
      () => find.text('星际保留作品').evaluate().isNotEmpty,
    );
    expect(find.text('星际待核作品'), findsNothing);
    expect(searches, 2);
    await tester.pumpWidget(const SizedBox());
  });

  for (final restore in [false, true]) {
    testWidgets(
      '${restore ? 'restore defaults' : 'bulk disable'} hides existing dialog',
      (tester) async {
        final f = await _Fixture.create(tester, adultAccess: true);
        final keep = _featured('bulk-keep.example', '保留批量来源', '星际批量保留');
        final source = _featured('bulk-change.example', '待批量停用来源', '星际批量停用');
        await f.install([keep, source]);
        var searches = 0;
        await tester.pumpWidget(f.page(onSearchStarted: () => searches++));
        await _waitFor(
          tester,
          'bulk initial search',
          () =>
              find.text('星际批量停用').evaluate().isNotEmpty &&
              find.text('星际批量保留').evaluate().isNotEmpty,
        );
        await tester.tap(find.text('星际批量停用'));
        await tester.pumpAndSettle();
        expect(find.text('待批量停用来源'), findsOneWidget);

        final repo = f.services.books;
        await f.run(
          'apply bulk change',
          () => restore
              ? repo.restoreDefaultSources(BookKind.text)
              : repo.setSourcesEnabled(BookKind.text, {source.id}, false),
        );
        await tester.pump();
        expect(find.text('待批量停用来源'), findsNothing);
        expect(find.text('星际批量停用'), findsNothing);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(find.text('星际批量停用'), findsNothing);
        expect(searches, 1);

        if (!restore) {
          await _waitFor(
            tester,
            'unaffected result after bulk disable',
            () => find.text('星际批量保留').evaluate().isNotEmpty,
          );
          await f.run(
            're-enable source',
            () => repo.setSourcesEnabled(BookKind.text, {source.id}, true),
          );
          await _waitFor(
            tester,
            'unaffected result after re-enable',
            () =>
                find.text('星际批量保留').evaluate().isNotEmpty &&
                find.text('星际批量停用').evaluate().isEmpty,
          );
          expect(find.text('星际批量停用'), findsNothing);
          expect(searches, 1);
          await tester.tap(find.byTooltip('搜索'));
          await _waitFor(
            tester,
            'explicit search after re-enable',
            () => find.text('星际批量停用').evaluate().isNotEmpty,
          );
          expect(searches, 2);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}

const _rules = {
  'chapters': 'a',
  'chapterTitle': '@text',
  'chapterUrl': '@href',
  'content': 'p@text',
};

BookSource _featured(String host, String name, String title) =>
    BookSource.fromJson({
      'name': name,
      'url': 'https://$host/',
      'format': 'featured',
      'kind': 'text',
      'featured': [
        {'title': title, 'url': '/book'},
      ],
      'rules': _rules,
    });

final class _Fixture {
  _Fixture(this.tester, this.services);
  final WidgetTester tester;
  final AppServices services;

  static Future<_Fixture> create(
    WidgetTester tester, {
    bool adultAccess = false,
  }) async {
    tester.view.physicalSize = const Size(1200, 1200);
    tester.view.devicePixelRatio = 1;
    late Directory root;
    late AppServices services;
    await _io(tester, 'create fixture', () async {
      root = await Directory.systemTemp.createTemp('book-search-policy-');
      services = AppServices.scoped(root, AppDatabase.memory());
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await _io(tester, 'close fixture', () async {
        await services.close();
        await root.delete(recursive: true);
      });
    });
    await _io(tester, 'load policy and disable builtins', () async {
      if (adultAccess) {
        await services.db.write(
          'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
          [installationAccessKey, upgradedInstallationAccess],
        );
      }
      await services.settings.load();
      await services.supervision.load();
      if (adultAccess) await services.settings.update({'filterAdult': false});
      for (final entry in await services.books.sources(
        BookKind.text,
        enabledOnly: true,
      )) {
        await services.books.saveSource(entry.source, {'enabled': false});
      }
    });
    return _Fixture(tester, services);
  }

  Future<void> run(String stage, Future<void> Function() work) =>
      _io(tester, stage, work);

  Future<void> install(List<BookSource> sources) =>
      run('install sources', () async {
        await services.books.importSources(sources);
        for (final source in sources) {
          await services.books.saveSource(source, {'enabled': true});
        }
      });

  Widget page({
    String query = '星际',
    VoidCallback? onSearchStarted,
    VoidCallback? beforeSourceSnapshotForTesting,
  }) => MaterialApp(
    home: BookSearchPage(
      repository: services.books,
      kind: BookKind.text,
      query: query,
      onOpen: (_) async {},
      onSearchStarted: onSearchStarted,
      beforeSourceSnapshotForTesting: beforeSourceSnapshotForTesting,
    ),
  );
}

Future<void> _io(
  WidgetTester tester,
  String stage,
  Future<void> Function() work,
) async {
  await tester.runAsync(
    () => work().timeout(
      const Duration(seconds: 12),
      onTimeout: () => throw StateError('Timed out: $stage'),
    ),
  );
}

Future<void> _waitFor(
  WidgetTester tester,
  String stage,
  bool Function() complete,
) async {
  for (var i = 0; i < 400; i++) {
    await tester.pump(const Duration(milliseconds: 10));
    if (complete()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(complete(), isTrue, reason: 'Timed out waiting for $stage');
}
