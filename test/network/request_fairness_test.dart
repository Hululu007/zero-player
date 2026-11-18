import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/request_scheduler.dart';

final a = Uri.parse('https://foreground.test');
final b = Uri.parse('https://background.test');

void main() {
  _progress();
  _playback();
  _eligibility();
  _cancellation();
  _backgroundOrder();
}

void _progress() {
  for (final capacity in [1, 3, 8]) {
    test(
      'eligible background progresses with foreground capacity $capacity',
      () async {
        final scheduler = RequestScheduler(
          globalLimit: capacity,
          originLimit: capacity,
        );
        addTearDown(scheduler.close);
        var active = await scheduler.acquire(a);
        // Fill the other slots before adding background demand.
        final held = [
          for (var i = 1; i < capacity; i++) await scheduler.acquire(a),
        ];
        var backgroundStarted = false;
        final background = scheduler
            .acquire(b, priority: RequestPriority.background)
            .then((permit) {
              backgroundStarted = true;
              permit.release();
            });
        var bypassed = 0;
        for (var i = 0; i < capacity * 4; i++) {
          final replacement = scheduler.acquire(a);
          active.release();
          active = await replacement;
          if (!backgroundStarted) bypassed++;
        }
        active.release();
        for (final permit in held) {
          permit.release();
        }
        await background;
        expect(bypassed, lessThanOrEqualTo(capacity));
      },
    );
  }
}

void _playback() {
  test(
    'playback still precedes background when foreground turn is exhausted',
    () async {
      final scheduler = RequestScheduler(globalLimit: 1);
      addTearDown(scheduler.close);
      final blocking = await scheduler.acquire(a);
      final order = <String>[];
      final background = scheduler
          .acquire(b, priority: RequestPriority.background)
          .then((permit) {
            order.add('background');
            permit.release();
          });
      final first = scheduler.acquire(a);
      blocking.release();
      final foreground = await first;
      final playing = scheduler
          .acquire(a, priority: RequestPriority.playback)
          .then((permit) {
            order.add('playback');
            permit.release();
          });
      final next = scheduler.acquire(a).then((permit) {
        order.add('foreground');
        permit.release();
      });
      foreground.release();
      await Future.wait([background, playing, next]);
      expect(order, ['playback', 'background', 'foreground']);
    },
  );
}

void _eligibility() {
  test('an origin-blocked background does not stop other origins', () async {
    final scheduler = RequestScheduler(globalLimit: 3, originLimit: 1);
    addTearDown(scheduler.close);
    final occupied = await scheduler.acquire(b);
    var backgroundStarted = false;
    final background = scheduler
        .acquire(b, priority: RequestPriority.background)
        .then((permit) {
          backgroundStarted = true;
          permit.release();
        });
    for (var i = 0; i < 12; i++) {
      final foreground = await scheduler.acquire(a);
      expect(backgroundStarted, false);
      foreground.release();
    }
    occupied.release();
    await background;
  });

  test(
    'background fairness preserves background and reserved-slot caps',
    () async {
      final scheduler = RequestScheduler(
        globalLimit: 4,
        originLimit: 4,
        playbackReserve: 1,
        backgroundLimit: 1,
      );
      addTearDown(scheduler.close);
      final occupied = await scheduler.acquire(
        b,
        priority: RequestPriority.background,
      );
      var backgroundStarted = false;
      final background = scheduler
          .acquire(b, priority: RequestPriority.background)
          .then((permit) {
            backgroundStarted = true;
            permit.release();
          });
      for (var i = 0; i < 12; i++) {
        final first = await scheduler.acquire(a);
        final second = await scheduler.acquire(a);
        final playback = await scheduler.acquire(
          b,
          priority: RequestPriority.playback,
        );
        expect(backgroundStarted, false);
        first.release();
        second.release();
        playback.release();
      }
      occupied.release();
      await background;
    },
  );
}

void _cancellation() {
  test(
    'cancelling an aged background leaves the remaining queue live',
    () async {
      final scheduler = RequestScheduler(globalLimit: 1);
      addTearDown(scheduler.close);
      final first = await scheduler.acquire(a);
      final token = CancellationToken();
      final background = scheduler.acquire(
        b,
        priority: RequestPriority.background,
        cancellation: token,
      );
      final cancelled = expectLater(
        background,
        throwsA(isA<RequestCancelled>()),
      );
      final second = scheduler.acquire(a);
      first.release();
      final next = await second;
      token.cancel();
      await cancelled;
      final third = scheduler.acquire(a);
      next.release();
      (await third).release();
    },
  );
}

void _backgroundOrder() {
  test('older eligible background requests progress in FIFO order', () async {
    final scheduler = RequestScheduler(globalLimit: 1);
    addTearDown(scheduler.close);
    var active = await scheduler.acquire(a);
    final order = <String>[];
    final background = [
      for (final name in ['first', 'second'])
        scheduler.acquire(b, priority: RequestPriority.background).then((
          permit,
        ) {
          order.add(name);
          permit.release();
        }),
    ];
    for (var i = 0; i < 3; i++) {
      final replacement = scheduler.acquire(a);
      active.release();
      active = await replacement;
    }
    final beforeDraining = List<String>.of(order);
    active.release();
    await Future.wait(background);
    expect(beforeDraining, ['first', 'second']);
    expect(order, ['first', 'second']);
  });
}
