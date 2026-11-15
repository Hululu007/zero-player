import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/network/cancellation_token.dart';
import '../../../core/network/document_client.dart';
import '../../../core/platform/background_audio_session.dart';
import '../../../media/gateway/offline_server.dart';
import '../../playback/domain/player_engine.dart';
import '../data/books_repository.dart';
import '../domain/book.dart';

/// Owns audiobook playback for the application lifetime, including page exits.
final class AudiobookController extends ChangeNotifier
    implements BackgroundAudioSession {
  AudiobookController(this.books, this.createEngine, this.beforePlay) {
    books.policy.addListener(_policyChanged);
  }

  final BooksRepository books;
  final PlayerEngine Function() createEngine;
  final Future<void> Function() beforePlay;
  Book? book;
  List<BookChapter> chapters = const [];
  BookChapter? chapter;
  PlayerEngine? _engine;
  OfflineSession? _session;
  CancellationToken? _token;
  StreamSubscription<PlaybackSnapshot>? _states;
  StreamSubscription<String>? _errors;
  Future<void>? _loading;
  Future<void>? _closing;
  BookChapter? _pending;
  PlaybackSnapshot snapshot = const PlaybackSnapshot();
  String? error;
  bool autoNext = true;
  double rate = 1;
  DateTime? sleepUntil;
  Timer? _sleepTimer;
  double? _resumeMs;
  int _savedAt = 0;
  String? _completed;

  @override
  bool get active => book != null && _closing == null;
  @override
  bool get loading => _loading != null;
  @override
  bool get playing => snapshot.playing;
  @override
  String get title =>
      chapter == null ? '' : '${book?.title} · ${chapter!.title}';
  int get index => chapter == null ? -1 : chapters.indexOf(chapter!);

  void start(
    Book work,
    List<BookChapter> items,
    BookChapter initial, {
    bool resume = true,
  }) {
    if (_closing != null) return;
    if (book?.id == work.id && chapter?.id == initial.id && active) return;
    if (book?.id != work.id) {
      save();
      _session?.close();
      _session = null;
      _token?.cancel();
      _pending = null;
      book = work;
      chapters = List.unmodifiable(items);
    } else {
      chapters = List.unmodifiable(items);
    }
    _start(initial, resume: resume);
  }

  void choose(BookChapter next) => _start(next);

  void _start(BookChapter next, {bool resume = false}) {
    if (_closing != null || book == null) return;
    if (_loading != null) {
      _pending = next;
      _token?.cancel();
      return;
    }
    save();
    _completed = null;
    final pending = _open(next, resume: resume);
    _loading = pending;
    notifyListeners();
    unawaited(
      pending.whenComplete(() {
        _loading = null;
        if (_closing != null) return;
        notifyListeners();
        final queued = _pending;
        _pending = null;
        if (queued != null) _start(queued);
      }),
    );
  }

  Future<void> _open(BookChapter next, {required bool resume}) async {
    final work = book!;
    final workChapters = chapters;
    final token = _token = CancellationToken();
    chapter = next;
    error = null;
    snapshot = const PlaybackSnapshot();
    _resumeMs = null;
    notifyListeners();
    try {
      await _engine?.stop();
      _session?.close();
      _session = null;
      books.requireBook(work, next);
      final old = await books.store.entry(work);
      if (!await books.audioFiles.contains(work, next)) {
        await books.download(work, next, token);
      }
      token.check();
      books.requireBook(work, next);
      _session = await books.audioFiles.open(work, next);
      token.check();
      await beforePlay();
      token.check();
      books.requireBook(work, next);
      final engine = _engine ??= _createEngine();
      await engine.open(_session!.uri);
      token.check();
      await engine.setRate(rate);
      token.check();
      if (resume && old?.last == next.id && old!.position > 0) {
        _resumeMs = old.position;
        _restore(engine.snapshot);
      }
      await books.store.saveBook(
        work,
        chapters: workChapters,
        last: next,
        position: old?.last == next.id ? old?.position ?? 0 : 0,
      );
    } on RequestCancelled {
      error ??= '已取消加载音频';
    } on FormatException catch (failure) {
      if (!token.isCancelled) error = failure.message;
    } on RemoteFailure catch (failure) {
      if (!token.isCancelled) error = failure.message;
    } catch (_) {
      if (!token.isCancelled) error = '无法打开音频或内容受限';
    }
    notifyListeners();
  }

  PlayerEngine _createEngine() {
    final engine = createEngine();
    _states = engine.states.listen((value) {
      if (_closing != null || book == null || chapter == null) return;
      snapshot = value;
      notifyListeners();
      if (loading) return;
      _restore(value);
      if (value.completed && _completed != chapter!.id) {
        _completed = chapter!.id;
        save();
        if (autoNext && index + 1 < chapters.length) {
          _start(chapters[index + 1]);
        }
      } else if ((value.position.inSeconds - _savedAt).abs() >= 5) {
        _savedAt = value.position.inSeconds;
        save();
      }
    });
    _errors = engine.errors.listen((_) {
      error = '音频解码失败，请换源或重新下载';
      notifyListeners();
    });
    return engine;
  }

  void _restore(PlaybackSnapshot value) {
    final position = _resumeMs;
    if (position == null || value.duration <= Duration.zero) return;
    _resumeMs = null;
    unawaited(
      _engine?.seek(
        Duration(
          milliseconds: position.round().clamp(
            0,
            value.duration.inMilliseconds,
          ),
        ),
      ),
    );
  }

  void save() {
    if (_session == null ||
        _engine == null ||
        book == null ||
        chapter == null) {
      return;
    }
    unawaited(
      books.store
          .saveBook(
            book!,
            last: chapter!,
            position: _engine!.snapshot.position.inMilliseconds.toDouble(),
          )
          .onError((_, _) {}),
    );
  }

  Future<void> pause() async {
    if (loading) _token?.cancel();
    await _engine?.pause();
  }

  @override
  Future<void> toggle() async {
    if (!active || loading || chapter == null || error != null) return;
    books.requireBook(book!, chapter!);
    if (!playing) await beforePlay();
    if (active && books.kindAllowed(BookKind.audio)) {
      await _engine?.playOrPause();
    }
  }

  Future<void> seek(Duration position) async => _engine?.seek(position);

  Future<void> setRate(double value) async {
    rate = value;
    notifyListeners();
    await _engine?.setRate(value);
  }

  void setAutoNext(bool value) {
    autoNext = value;
    notifyListeners();
  }

  void setSleep(Duration? duration) {
    _sleepTimer?.cancel();
    sleepUntil = duration == null ? null : DateTime.now().add(duration);
    notifyListeners();
    if (duration == null) return;
    _sleepTimer = Timer(duration, () {
      sleepUntil = null;
      notifyListeners();
      unawaited(pause());
    });
  }

  void _policyChanged() {
    if (book == null || chapter == null) return;
    if (books.kindAllowed(BookKind.audio) &&
        books.bookAllowed(book!) &&
        books.policy.textAllowed(chapter!.title)) {
      return;
    }
    _token?.cancel();
    unawaited(pause());
    error = '当前内容策略限制播放该章节';
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    _pending = null;
    _token?.cancel();
    await _loading;
    save();
    await _engine?.stop();
    _session?.close();
    _session = null;
    _sleepTimer?.cancel();
    sleepUntil = null;
    book = null;
    chapter = null;
    chapters = const [];
    snapshot = const PlaybackSnapshot();
    notifyListeners();
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    await stop();
    await _states?.cancel();
    await _errors?.cancel();
    await _engine?.dispose();
    books.policy.removeListener(_policyChanged);
    super.dispose();
  }
}
