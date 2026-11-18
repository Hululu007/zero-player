import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/diagnostics/performance_counters.dart';
import 'package:zero_player/core/network/request_scheduler.dart';

import '../../test_support/network_workload.dart';

void main() {
  for (final observe in [false, true]) {
    test('two transport clients capacity envelope, observe=$observe', () async {
      final fixture = await _fixture(observe);
      final initial = [
        for (var i = 0; i < 18; i++) ...[
          fixture.start(module: 'catalog', origin: i ~/ 2),
          fixture.start(module: 'reading', origin: i ~/ 2, books: true),
        ],
      ];
      await fixture.waitFor(initial);
      final playback = [
        for (final books in [false, true])
          for (var i = 0; i < 2; i++)
            fixture.start(
              module: books ? 'audiobook' : 'playback',
              origin: 9,
              books: books,
              priority: RequestPriority.playback,
            ),
      ];
      await fixture.waitFor(playback);
      final pending = [
        for (final books in [false, true])
          fixture.start(
            module: books ? 'book-download' : 'poster',
            origin: 9,
            books: books,
            priority: RequestPriority.background,
          ),
      ];
      expect(pending.every((job) => !job.started.isCompleted), true);
      final held = fixture.snapshot();
      final results = await fixture.finish();
      expect(results.every((result) => result.valid), true);
      expect(results.fold(0, (sum, result) => sum + result.bytes), 42 * 65536);
      _report('two-client-capacity-envelope', fixture, held, observe);
    });
  }
  _sustainedDemand();
  _queuePressure();
}

void _sustainedDemand() {
  test(
    'background admission under 40 replacement interactive grants',
    () async {
      final fixture = await _fixture(true);
      final active = [
        for (var i = 0; i < 18; i++)
          fixture.start(module: 'search', origin: i ~/ 2),
      ];
      await fixture.waitFor(active);
      final background = fixture.start(
        module: 'download',
        origin: 9,
        priority: RequestPriority.background,
      );
      var bypassed = 0;
      for (var i = 0; i < 40; i++) {
        final next = fixture.start(module: 'search', origin: i % 9);
        final index = (i % 9) * 2;
        active[index].release();
        expect((await active[index].result).valid, true);
        await fixture.waitFor([next]);
        active[index] = next;
        if (!background.started.isCompleted) bypassed++;
      }
      final held = fixture.snapshot();
      active.first.release();
      expect((await active.first.result).valid, true);
      await fixture.waitFor([background]);
      expect((await fixture.finish()).every((result) => result.valid), true);
      _report(
        'sustained-interactive',
        fixture,
        held,
        true,
        additional: {'interactiveGrantsWhileBackgroundWaited': bypassed},
      );
    },
  );
}

void _queuePressure() {
  test('1000 queued requests cancel before transport admission', () async {
    final fixture = await _fixture(true, origins: 1);
    final active = [
      fixture.start(module: 'streaming', origin: 0),
      fixture.start(module: 'streaming', origin: 0),
    ];
    await fixture.waitFor(active);
    final pending = [
      for (var i = 0; i < 1000; i++)
        fixture.start(
          module: 'prefetch',
          origin: 0,
          priority: RequestPriority.background,
        ),
    ];
    final held = fixture.snapshot();
    for (final job in pending) {
      job.token.cancel();
    }
    final cancelled = await Future.wait([
      for (final job in pending) job.result,
    ]);
    expect(cancelled.every((result) => result.cancelled), true);
    expect(pending.every((job) => !job.started.isCompleted), true);
    for (final job in active) {
      job.release();
      expect((await job.result).valid, true);
    }
    _report('queue-1000-cancel', fixture, held, true);
  });
}

Future<NetworkWorkload> _fixture(bool observe, {int origins = 10}) async {
  final fixture = NetworkWorkload(observe: observe);
  final enabled = PerformanceCounters.enabled;
  PerformanceCounters.enabled = observe;
  PerformanceCounters.reset();
  addTearDown(() async {
    await fixture.close();
    PerformanceCounters.enabled = enabled;
    PerformanceCounters.reset();
  });
  await fixture.initialize(origins: origins);
  return fixture;
}

void _report(
  String scenario,
  NetworkWorkload fixture,
  Map<String, Object> held,
  bool observe, {
  Map<String, Object> additional = const {},
}) {
  final after = fixture.snapshot();
  if (observe) {
    final all = after['all'] as Map<String, int>;
    expect(all['active'], 0);
    expect(all['queued'], 0);
    expect(all['completed'], all['requested']);
    expect(all['peakActive'], after['serverPeakActive']);
    final counters = PerformanceCounters.snapshot();
    expect(all['requested'], counters['network.queued']);
    expect(all['started'], counters['network.started']);
    expect(all['started'], counters['network.released']);
  } else {
    expect(PerformanceCounters.snapshot(), isEmpty);
    expect(after.keys, ['serverPeakActive']);
  }
  stdout.writeln(
    jsonEncode({
      'scenario': scenario,
      'observe': observe,
      'held': held,
      'after': after,
      'counters': PerformanceCounters.snapshot(),
      ...additional,
    }),
  );
}
