import 'dart:async';

import 'cancellation_token.dart';
import 'header_policy.dart';
import '../diagnostics/performance_counters.dart';

enum RequestPriority { playback, interactive, background }

final _requestPriorityKey = Object();
RequestPriority get currentRequestPriority =>
    Zone.current[_requestPriorityKey] as RequestPriority? ??
    RequestPriority.interactive;

Future<T> withRequestPriority<T>(
  RequestPriority priority,
  Future<T> Function() action,
) => runZoned(action, zoneValues: {_requestPriorityKey: priority});

enum RequestPhase { queued, started, released, cancelled }

final _requestObservationKey = Object();

/// Opt-in permit lifecycle observations. The observer receives no request data.
/// Keep one observation per logical request when measuring mixed workloads.
final class RequestObservation {
  const RequestObservation(this.onPhase);
  final void Function(RequestPhase) onPhase;

  void _notify(RequestPhase phase) {
    try {
      onPhase(phase);
    } catch (_) {
      // Diagnostic failures must not alter permit ownership or cancellation.
    }
  }
}

Future<T> observeRequests<T>(
  RequestObservation observation,
  Future<T> Function() action,
) => runZoned(action, zoneValues: {_requestObservationKey: observation});

final class RequestPermit {
  RequestPermit(this._release);
  final void Function() _release;
  bool _released = false;
  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

/// Bounded global/per-origin concurrency. Playback goes ahead of queued
/// background work, without interrupting an already streaming response.
/// The oldest eligible background waits at most one foreground pool turnover.
final class RequestScheduler {
  RequestScheduler({
    this.globalLimit = 8,
    this.originLimit = 2,
    this.playbackReserve = 0,
    this.backgroundLimit = 4,
  }) {
    if (globalLimit < 1 || originLimit < 1) {
      throw ArgumentError('Limits must be positive');
    }
  }
  final int globalLimit;
  final int originLimit;
  final int playbackReserve;
  final int backgroundLimit;
  int _background = 0;
  final _queue = <_WaitingRequest>[];
  final _origins = <String, int>{};
  int _active = 0;
  int _sequence = 0;
  bool _closed = false;

  Future<RequestPermit> acquire(
    Uri uri, {
    RequestPriority priority = RequestPriority.interactive,
    CancellationToken? cancellation,
  }) {
    if (_closed) throw StateError('Request scheduler closed');
    cancellation?.check();
    final pending = _WaitingRequest(
      HeaderPolicy.origin(uri),
      priority,
      _sequence++,
      Zone.current[_requestObservationKey] as RequestObservation?,
    );
    _queue.add(pending);
    PerformanceCounters.add('network.queued');
    pending.observation?._notify(RequestPhase.queued);
    pending.removeListener = cancellation?.listen(() {
      _queue.remove(pending);
      if (!pending.completer.isCompleted) {
        pending.observation?._notify(RequestPhase.cancelled);
        pending.completer.completeError(const RequestCancelled());
      }
    });
    _drain();
    return pending.completer.future;
  }

  void _drain() {
    if (_closed) return;
    _queue.sort((a, b) {
      final priority = a.priority.index.compareTo(b.priority.index);
      return priority == 0 ? a.sequence.compareTo(b.sequence) : priority;
    });
    while (_active < globalLimit) {
      final index = _nextIndex();
      if (index < 0) return;
      final job = _queue.removeAt(index);
      job.removeListener?.call();
      _active++;
      PerformanceCounters.add('network.started');
      if (job.priority == RequestPriority.background) _background++;
      _origins.update(job.origin, (count) => count + 1, ifAbsent: () => 1);
      job.observation?._notify(RequestPhase.started);
      job.completer.complete(
        RequestPermit(() {
          _active--;
          PerformanceCounters.add('network.released');
          if (job.priority == RequestPriority.background) _background--;
          final count = _origins[job.origin]! - 1;
          if (count == 0) {
            _origins.remove(job.origin);
          } else {
            _origins[job.origin] = count;
          }
          job.observation?._notify(RequestPhase.released);
          _drain();
        }),
      );
    }
  }

  int get _foregroundCapacity =>
      globalLimit - playbackReserve.clamp(0, globalLimit - 1);

  bool _eligible(_WaitingRequest job) =>
      (_origins[job.origin] ?? 0) < originLimit &&
      (job.priority == RequestPriority.playback ||
          _active < _foregroundCapacity) &&
      (job.priority != RequestPriority.background ||
          _background < backgroundLimit);

  int _nextIndex() {
    final first = _queue.indexWhere(_eligible);
    if (first < 0 || _queue[first].priority != RequestPriority.interactive) {
      return first;
    }
    final background = _queue.indexWhere(
      (job) => job.priority == RequestPriority.background && _eligible(job),
    );
    if (background < 0) return first;
    final waiting = _queue[background];
    if (waiting.foregroundBypasses < _foregroundCapacity) {
      waiting.foregroundBypasses++;
      return first;
    }
    PerformanceCounters.add('network.background.promoted');
    return background;
  }

  void close() {
    _closed = true;
    for (final job in _queue) {
      job.removeListener?.call();
      job.observation?._notify(RequestPhase.cancelled);
      job.completer.completeError(const RequestCancelled());
    }
    _queue.clear();
  }
}

final class _WaitingRequest {
  _WaitingRequest(this.origin, this.priority, this.sequence, this.observation);
  final String origin;
  final RequestPriority priority;
  final int sequence;
  final RequestObservation? observation;
  int foregroundBypasses = 0;
  final completer = Completer<RequestPermit>();
  void Function()? removeListener;
}
