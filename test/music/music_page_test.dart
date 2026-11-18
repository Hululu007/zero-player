import 'dart:io';
import 'package:zero_player/features/music/application/music_downloads.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/music/domain/music_track.dart';
import 'package:zero_player/features/music/presentation/music_page.dart';
import 'package:zero_player/features/music/presentation/music_player.dart';
import 'package:zero_player/features/music/data/music_recommendations.dart';
import 'package:zero_player/features/music/presentation/music_chart_browser.dart';
import '../../test_support/fake_player_engine.dart';

void main() {
  for (final (size, scale) in [
    (const Size(320, 640), 1.6),
    (const Size(568, 320), 1.6),
    (const Size(390, 844), 2.0),
  ]) {
    testWidgets(
      'chart search and keyboard leave content scrollable at $size/$scale',
      (tester) => _exercisePhoneCharts(tester, size, scale),
    );
  }
  testWidgets('search list offers one-tap return to top', (tester) async {
    final (root, services, _) = (await tester.runAsync(_setup))!;
    services.musicBrowser.result = MusicSearchResult([
      for (var i = 0; i < 40; i++)
        MusicTrack(
          id: 'track-$i',
          title: '测试音乐 $i',
          artist: '测试歌手',
          url: Uri.parse('https://example.com/$i.mp3'),
          fetchedAt: DateTime.now(),
        ),
    ]);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MusicPage(services: services)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).first, const Offset(0, -700));
      await tester.pumpAndSettle();
      expect(find.byTooltip('返回页首'), findsOneWidget);
      await tester.tap(find.byTooltip('返回页首'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('返回页首'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _closeFixture(tester, services, root);
    }
  });
  testWidgets(
    'downloaded search result stays visible when online search fails',
    (tester) async {
      final (root, services, _) = (await tester.runAsync(_setup))!;
      final track = services.musicBrowser.result.tracks.single;
      services.musicDownloads.items = [
        MusicDownload(track, 'complete', 100, entry: 'audio.mp3'),
      ];
      services.musicBrowser.result = const MusicSearchResult([]);
      services.musicBrowser.error = '网络不可用';
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: MusicPage(services: services)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('music-test')),
          200,
          scrollable: find
              .descendant(
                of: find.byType(ListView).first,
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(find.textContaining('已下载 · 本地播放'), findsOneWidget);
        expect(find.byTooltip('已下载 · 优先本地播放'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await _closeFixture(tester, services, root);
      }
    },
  );
  for (final size in [
    const Size(390, 850),
    const Size(844, 390),
    const Size(1280, 850),
  ]) {
    testWidgets(
      'music page and mini player at $size with enlarged text',
      (tester) => _exercise(tester, size),
    );
  }
}

Future<void> _exercisePhoneCharts(
  WidgetTester tester,
  Size size,
  double scale,
) async {
  final (root, services, _) = (await tester.runAsync(_setup))!;
  services.musicBrowser.query = '';
  services.musicRecommendations.chart = 'wfu';
  services.musicRecommendations.items = [
    for (var i = 0; i < 20; i++) MusicRecommendation('测试榜单曲目$i', '歌手', ''),
  ];
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  try {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: MaterialApp(
          home: Scaffold(body: MusicPage(services: services)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('music-search')), findsNothing);
    await tester.tap(find.byTooltip('展开音乐搜索'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('music-search')));
    await tester.tap(find.byKey(const ValueKey('music-search')));
    tester.view.viewInsets = FakeViewPadding(
      bottom: size.height > 500 ? 260 : 120,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(const ValueKey('music-search')));
    await tester.pumpAndSettle();
    final field = tester.getRect(find.byKey(const ValueKey('music-search')));
    expect(
      field.bottom,
      lessThanOrEqualTo(size.height - tester.view.viewInsets.bottom),
    );
    tester.view.resetViewInsets();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final content = find.byKey(const ValueKey('music-recommendation-0'));
    final scroll = find
        .descendant(
          of: find.byType(MusicChartBrowser),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(content, 100, scrollable: scroll);
    await tester.pumpAndSettle();
    expect(content.hitTestable(), findsOneWidget);
    expect(find.byTooltip('收起音乐搜索').hitTestable(), findsNothing);
    await tester.scrollUntilVisible(
      find.byTooltip('收起音乐搜索'),
      -150,
      scrollable: scroll,
    );
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('music-search')), findsNothing);
    expect(find.byTooltip('展开音乐搜索'), findsOneWidget);
    expect(tester.takeException(), isNull);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await _closeFixture(tester, services, root);
  }
}

Future<void> _exercise(WidgetTester tester, Size size) async {
  final setup = (await tester.runAsync(_setup))!;
  final (root, services, engine) = setup;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  Widget frame(Widget child) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: size,
        textScaler: const TextScaler.linear(1.6),
      ),
      child: Scaffold(body: child),
    ),
  );
  try {
    await tester.pumpWidget(frame(MusicPage(services: services)));
    await tester.pumpAndSettle();
    expect(
      find.text(size.width < 620 ? '多源聚合' : '多源聚合 · 并发搜索'),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('music-test')),
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    if (tester.getCenter(find.byKey(const ValueKey('music-test'))).dy >
        size.height - 100) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -150));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const ValueKey('music-test')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    for (var i = 0; i < 50 && services.musicPlayer.loading; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pumpAndSettle();
    expect(engine.snapshot.playing, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      frame(MusicPlayer(controller: services.musicPlayer, compact: true)),
    );
    await tester.pumpAndSettle();
    expect(engine.snapshot.playing, isTrue);
    await tester.tap(find.byTooltip('暂停音乐'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(engine.snapshot.playing, isFalse);
    await tester.tap(find.byTooltip('播放音乐'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(engine.snapshot.playing, isTrue);
    await tester.tap(find.byTooltip('停止音乐'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(services.musicPlayer.active, isFalse);
    expect(services.musicBrowser.query, '测试');
    expect(tester.takeException(), isNull);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await _closeFixture(tester, services, root);
  }
}

Future<(Directory, AppServices, FakePlayerEngine)> _setup() async {
  final root = await Directory.systemTemp.createTemp('music-page-');
  final engine = FakePlayerEngine();
  final services = AppServices.scoped(
    root,
    AppDatabase.memory(),
    musicEngine: () => engine,
  );
  await services.settings.load();
  await services.musicLibrary.load();
  await services.musicDownloads.load();
  services.musicBrowser.query = '测试';
  services.musicBrowser.result = MusicSearchResult([
    MusicTrack(
      id: 'test',
      title: '测试音乐',
      artist: '测试歌手',
      url: Uri.parse('https://example.com/test.mp3'),
      fetchedAt: DateTime.now(),
    ),
  ]);
  services.musicPlayer;
  return (root, services, engine);
}

Future<void> _closeFixture(
  WidgetTester tester,
  AppServices services,
  Directory root,
) async {
  var flushed = false;
  services.musicLibrary.pendingWrites.then((_) => flushed = true);
  for (var i = 0; i < 50 && !flushed; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(flushed, isTrue);
  var closed = false;
  Object? closeError;
  services.close().then(
    (_) {
      closed = true;
    },
    onError: (Object error) {
      closeError = error;
      closed = true;
    },
  );
  for (var i = 0; i < 300 && !closed; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(closed, isTrue);
  expect(closeError, isNull);
  await tester.runAsync(() => root.delete(recursive: true));
}
