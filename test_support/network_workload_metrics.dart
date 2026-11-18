/// Test-only observations of exact scheduler permit transitions.
/// Origin labels are fixture ordinals; no address, headers or payload is kept.
final class NetworkWorkloadMetrics {
  NetworkWorkloadMetrics({required this.enabled});
  final bool enabled;
  final _clock = Stopwatch()..start();
  final _jobs = <int, _ObservedRequest>{};
  final _all = _Totals();
  final _modules = <String, _Totals>{};
  final _priorities = <String, _Totals>{};
  final _origins = <int, _Totals>{};

  void queued(int id, String module, String priority, int origin) {
    if (!enabled) return;
    final job = _ObservedRequest(_clock.elapsedMicroseconds, [
      _all,
      _modules.putIfAbsent(module, _Totals.new),
      _priorities.putIfAbsent(priority, _Totals.new),
      _origins.putIfAbsent(origin, _Totals.new),
    ]);
    _jobs[id] = job;
    for (final totals in job.totals) {
      totals.requested++;
      totals.queued++;
      totals.peakQueued = _max(totals.peakQueued, totals.queued);
    }
  }

  void activity(int id, bool active) {
    final job = _jobs[id];
    if (job == null || job.active == active && job.started) return;
    if (active) {
      final wait = _clock.elapsedMicroseconds - job.queuedAt;
      for (final totals in job.totals) {
        if (job.waiting) {
          totals.queued--;
          totals.started++;
          totals.waitMicroseconds += wait;
          totals.maxWaitMicroseconds = _max(totals.maxWaitMicroseconds, wait);
        }
        totals.active++;
        totals.peakActive = _max(totals.peakActive, totals.active);
      }
      job.started = true;
      job.waiting = false;
    } else if (job.active) {
      for (final totals in job.totals) {
        totals.active--;
      }
    }
    job.active = active;
  }

  void cancelled(int id) {
    final job = _jobs[id];
    if (job == null || !job.waiting) return;
    for (final totals in job.totals) {
      totals.queued--;
    }
    job.waiting = false;
  }

  void finished(int id, {int bytes = 0, bool cancelled = false}) {
    final job = _jobs.remove(id);
    if (job == null) return;
    for (final totals in job.totals) {
      if (job.waiting) totals.queued--;
      if (job.active) totals.active--;
      totals.completed++;
      totals.bytes += bytes;
      if (cancelled) totals.cancelled++;
    }
  }

  Map<String, Object> snapshot() => enabled
      ? {
          'all': _all.toJson(),
          'modules': _modules.map(
            (key, value) => MapEntry(key, value.toJson()),
          ),
          'priorities': _priorities.map(
            (key, value) => MapEntry(key, value.toJson()),
          ),
          'origins': _origins.map(
            (key, value) => MapEntry('origin-$key', value.toJson()),
          ),
        }
      : const {};
}

int _max(int a, int b) => a > b ? a : b;

final class _ObservedRequest {
  _ObservedRequest(this.queuedAt, this.totals);
  final int queuedAt;
  final List<_Totals> totals;
  bool started = false;
  bool waiting = true;
  bool active = false;
}

final class _Totals {
  int requested = 0, started = 0, completed = 0, cancelled = 0;
  int queued = 0, active = 0, peakQueued = 0, peakActive = 0;
  int bytes = 0, waitMicroseconds = 0, maxWaitMicroseconds = 0;

  Map<String, int> toJson() => {
    'requested': requested,
    'started': started,
    'completed': completed,
    'cancelled': cancelled,
    'queued': queued,
    'active': active,
    'peakQueued': peakQueued,
    'peakActive': peakActive,
    'bytes': bytes,
    'waitMicroseconds': waitMicroseconds,
    'maxWaitMicroseconds': maxWaitMicroseconds,
  };
}
