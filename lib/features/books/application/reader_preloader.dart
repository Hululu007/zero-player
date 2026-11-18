import 'dart:async';

import '../../../core/network/cancellation_token.dart';
import '../domain/book.dart';

/// One speculative chapter at a time, after a dwell period. No retries, source
/// discovery or UI updates; normal reads still validate offline/cache evidence.
final class ReaderPreloader {
  ReaderPreloader(this.read, {this.delay = const Duration(milliseconds: 700)});
  final Future<void> Function(BookChapter, CancellationToken) read;
  final Duration delay;
  Timer? _timer;
  CancellationToken? _token;
  bool _closed = false;

  void schedule(
    List<BookChapter> chapters, {
    Future<bool> Function()? allowed,
  }) {
    cancel();
    if (_closed || chapters.isEmpty) return;
    final token = _token = CancellationToken();
    _timer = Timer(delay, () => unawaited(_run(chapters, token, allowed)));
  }

  Future<void> _run(
    List<BookChapter> chapters,
    CancellationToken token,
    Future<bool> Function()? allowed,
  ) async {
    try {
      if (allowed != null && !await allowed()) return;
      for (final chapter in chapters) {
        token.check();
        await read(chapter, token);
      }
    } on Object {
      // A speculative failure must not interrupt the chapter being read.
    }
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _token?.cancel();
    _token = null;
  }

  void dispose() {
    _closed = true;
    cancel();
  }
}
