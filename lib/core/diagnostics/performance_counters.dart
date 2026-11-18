/// Opt-in aggregate work counts. No URLs, SQL, metadata or per-event logging.
/// Enable in profile builds with --dart-define=ZERO_PLAYER_PERF_COUNTERS=true.
abstract final class PerformanceCounters {
  static bool enabled = const bool.fromEnvironment('ZERO_PLAYER_PERF_COUNTERS');
  static final _values = <String, int>{};

  static void add(String name, [int amount = 1]) {
    if (enabled) {
      _values.update(name, (value) => value + amount, ifAbsent: () => amount);
    }
  }

  static Map<String, int> snapshot() => Map.unmodifiable(_values);
  static void reset() => _values.clear();
}
