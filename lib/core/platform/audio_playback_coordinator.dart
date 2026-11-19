/// Serializes complete audio handoffs outside individual player command queues.
final class AudioPlaybackCoordinator {
  Future<void>? _pending;

  Future<void> run(Future<void> Function() handoff) {
    final previous = _pending;
    final next = previous == null
        ? Future<void>.sync(handoff)
        : previous.then((_) => handoff());
    final settled = next.catchError((Object _) {});
    _pending = settled;
    settled.then((_) {
      if (identical(_pending, settled)) _pending = null;
    });
    return next;
  }
}
