/// Verifies every native safety option before a player may open media.
/// Concurrent callers share one attempt; a failed attempt is retryable.
final class PlayerSecurity {
  PlayerSecurity({
    required this.setProperty,
    required this.getProperty,
    this.audioReadAhead,
    this.networkTimeout,
  });
  final Future<void> Function(String, String) setProperty;
  final Future<String> Function(String) getProperty;
  final Duration? audioReadAhead, networkTimeout;
  Future<void>? _ready;

  Future<void> ensureReady() async {
    final attempt = _ready ??= _configure();
    try {
      await attempt;
    } catch (_) {
      if (identical(_ready, attempt)) _ready = null;
      rethrow;
    }
  }

  Future<void> _configure() async {
    for (final entry in const {
      'load-scripts': 'no',
      'config': 'no',
      'load-unsafe-playlists': 'no',
      'access-references': 'no',
      'sub-auto': 'no',
      'audio-file-auto': 'no',
      'cache-on-disk': 'no',
    }.entries) {
      await setProperty(entry.key, entry.value);
      if (await getProperty('options/${entry.key}') != entry.value) {
        throw StateError('播放器安全选项未生效：${entry.key}');
      }
    }
    if (audioReadAhead case final ahead?) {
      await setProperty('cache', 'yes');
      await setProperty('cache-secs', '${ahead.inSeconds}');
      await setProperty('cache-pause-initial', 'yes');
    }
    if (networkTimeout case final timeout?) {
      final seconds = timeout.inSeconds.clamp(1, 60);
      await setProperty('network-timeout', '$seconds');
      if (double.tryParse(await getProperty('options/network-timeout')) !=
          seconds) {
        throw StateError('播放器网络等待时间未生效');
      }
    }
  }
}
