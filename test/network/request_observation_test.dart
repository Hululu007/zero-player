import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/request_scheduler.dart';

void main() {
  final uri = Uri.parse('https://permit.test');
  test(
    'observations follow each permit across scopes, cancel and close',
    () async {
      final scheduler = RequestScheduler(globalLimit: 1);
      final first = <RequestPhase>[];
      final cancelled = <RequestPhase>[];
      final closed = <RequestPhase>[];
      final token = CancellationToken();
      final active = await observeRequests(
        RequestObservation(first.add),
        () => scheduler.acquire(uri),
      );
      final pending = observeRequests(
        RequestObservation(cancelled.add),
        () => scheduler.acquire(uri, cancellation: token),
      );
      final checked = expectLater(pending, throwsA(isA<RequestCancelled>()));
      token.cancel();
      await checked;
      final last = observeRequests(
        RequestObservation(closed.add),
        () => scheduler.acquire(uri),
      );
      final closedCheck = expectLater(last, throwsA(isA<RequestCancelled>()));
      scheduler.close();
      await closedCheck;
      active.release();
      active.release();
      expect(first, [
        RequestPhase.queued,
        RequestPhase.started,
        RequestPhase.released,
      ]);
      expect(cancelled, [RequestPhase.queued, RequestPhase.cancelled]);
      expect(closed, [RequestPhase.queued, RequestPhase.cancelled]);
    },
  );

  test(
    'an observer failure cannot leak a permit or stop cancellation',
    () async {
      final scheduler = RequestScheduler(globalLimit: 1);
      addTearDown(scheduler.close);
      final broken = RequestObservation((_) => throw StateError('diagnostic'));
      final active = await observeRequests(
        broken,
        () => scheduler.acquire(uri),
      );
      final token = CancellationToken();
      final waiting = observeRequests(
        broken,
        () => scheduler.acquire(uri, cancellation: token),
      );
      final checked = expectLater(waiting, throwsA(isA<RequestCancelled>()));
      token.cancel();
      await checked;
      active.release();
      final next = await scheduler.acquire(uri);
      next.release();
    },
  );
}
