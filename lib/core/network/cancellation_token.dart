final class RequestCancelled implements Exception {
  const RequestCancelled();
  @override
  String toString() => 'Request cancelled';
}

final class CancellationToken {
  final Set<void Function()> _listeners = {};
  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  void check() {
    if (_cancelled) throw const RequestCancelled();
  }

  void Function() listen(void Function() callback) {
    if (_cancelled) {
      callback();
    } else {
      _listeners.add(callback);
    }
    return () => _listeners.remove(callback);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = _listeners.toList(growable: false);
    _listeners.clear();
    Object? firstError;
    StackTrace? firstStack;
    for (final callback in listeners) {
      try {
        callback();
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
  }
}
