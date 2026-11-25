import 'dart:async';

import '../../../core/network/cancellation_token.dart';
import '../domain/book.dart';

/// Keeps a rolling window of speculative reads. Normal reads still validate
/// offline and cache evidence before presenting a chapter.
final class ReaderPreloader {
  ReaderPreloader(this.read, {this.delay = const Duration(milliseconds: 700)});
  final Future<void> Function(BookChapter, CancellationToken) read;
  final Duration delay;
  Timer? _timer;
  CancellationToken? _token;
  final _ready = <String>{};
  List<BookChapter> _pending = [];
  String? _inFlight;
  Completer<void>? _inFlightDone;
  bool _closed = false;

  void schedule(
    List<BookChapter> chapters, {
    Future<bool> Function()? allowed,
    int refillAt = 0,
  }) {
    if (_closed || chapters.isEmpty) return;
    final ids = chapters.map((chapter) => chapter.id).toSet();
    _ready.retainAll(ids);
    final ahead = chapters
        .takeWhile((chapter) => _ready.contains(chapter.id))
        .length;
    if (_token != null || ahead <= refillAt) {
      _pending = chapters
          .where(
            (chapter) =>
                !_ready.contains(chapter.id) && chapter.id != _inFlight,
          )
          .toList();
    }
    if (_token != null || _pending.isEmpty) return;
    final token = _token = CancellationToken();
    _timer = Timer(ahead == 0 ? delay : Duration.zero, () {
      _timer = null;
      unawaited(_run(token, allowed));
    });
  }

  Future<void> enter(BookChapter chapter, CancellationToken token) async {
    final ready = _ready.remove(chapter.id);
    if (chapter.id == _inFlight) {
      final done = Completer<void>();
      final unlink = token.listen(() {
        if (!done.isCompleted) done.complete();
      });
      try {
        await Future.any([_inFlightDone!.future, done.future]);
        _ready.remove(chapter.id);
        token.check();
      } finally {
        unlink();
      }
      return;
    }
    final queued = _pending.indexWhere((item) => item.id == chapter.id);
    if (queued >= 0) {
      _pending = _pending.sublist(queued + 1);
    } else if (!ready) {
      cancel();
    }
  }

  Future<void> _run(
    CancellationToken token,
    Future<bool> Function()? allowed,
  ) async {
    try {
      if (allowed != null && !await allowed()) return;
      while (_pending.isNotEmpty) {
        token.check();
        final chapter = _pending.removeAt(0);
        final finished = _inFlightDone = Completer<void>();
        _inFlight = chapter.id;
        try {
          await read(chapter, token);
          token.check();
          _ready.add(chapter.id);
        } on Object {
          // A speculative read cannot interrupt the foreground reader.
        } finally {
          if (identical(_inFlightDone, finished)) {
            _inFlight = null;
            _inFlightDone = null;
          }
          if (!finished.isCompleted) finished.complete();
        }
      }
    } on Object {
      // A failed network decision or cancellation ends this window.
    } finally {
      if (identical(_token, token)) {
        _token = null;
        _pending = [];
      }
    }
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _token?.cancel();
    _token = null;
    _pending = [];
    _ready.clear();
    _inFlight = null;
    final done = _inFlightDone;
    if (done != null && !done.isCompleted) done.complete();
    _inFlightDone = null;
  }

  void dispose() {
    _closed = true;
    cancel();
  }
}
