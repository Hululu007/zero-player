import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../../core/network/cancellation_token.dart';
import '../../../core/platform/background_audio_session.dart';
import '../../../core/platform/audio_playback_coordinator.dart';
import '../../live/domain/live_channel.dart';
import '../../playback/domain/player_engine.dart';
import '../../supervision/application/content_policy.dart';

/// Serializes native player commands, discarding superseded station selections.
final class RadioController extends ChangeNotifier
    implements BackgroundAudioSession {
  RadioController(
    this.createEngine, {
    this.operationTimeout = const Duration(seconds: 20),
    this.policy,
    this.beforePlay,
    AudioPlaybackCoordinator? playbackCoordinator,
  }) : _playbackCoordinator =
           playbackCoordinator ?? AudioPlaybackCoordinator() {
    policy?.addListener(_policyChanged);
  }
  final ContentPolicy? policy;
  final Future<void> Function()? beforePlay;
  final AudioPlaybackCoordinator _playbackCoordinator;

  void _policyChanged() {
    final current = selected;
    if (current != null &&
        !(policy?.channelAllowed(current, radio: true) ?? true)) {
      unawaited(stop().catchError((Object _) {}));
    }
  }

  final PlayerEngine Function() createEngine;
  final Duration operationTimeout;
  final _closing = CancellationToken();
  Future<void>? _closeFuture;
  PlayerEngine? _engine;
  StreamSubscription<PlaybackSnapshot>? _states;
  StreamSubscription<String>? _errors;
  Future<void> _pending = Future<void>.value();
  int _generation = 0;
  bool _closed = false;
  Completer<void>? _selectionInterrupt;
  bool _needsOpen = false;
  bool _userPaused = false;
  @override
  bool loading = false;
  @override
  bool playing = false;
  bool buffering = false;
  double volume = 80;
  String? error;
  LiveChannel? selected;
  int line = 0;
  @override
  bool get active => selected != null && !_closed;
  @override
  String get title => selected?.name ?? '';

  PlayerEngine _player() {
    if (_engine case final engine?) return engine;
    final engine = _engine = createEngine();
    _states = engine.states.listen((state) {
      if (_closed || !identical(_engine, engine)) return;
      playing = state.playing;
      buffering = state.buffering;
      if (state.playing && !_userPaused) {
        error = null;
        _needsOpen = false;
      }
      notifyListeners();
    });
    _errors = engine.errors.listen((_) {
      if (_closed || !identical(_engine, engine)) return;
      error = '电台暂时无法播放，请重试或选择其他线路/电台。';
      _needsOpen = true;
      playing = false;
      buffering = false;
      if (loading) {
        notifyListeners();
        return;
      }
      if (!_userPaused &&
          !loading &&
          selected != null &&
          line + 1 < selected!.playbackUrls.length) {
        unawaited(select(selected!, lineIndex: line + 1));
        return;
      }
      loading = false;
      notifyListeners();
    });
    return engine;
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _pending.then((_) => action());
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<void> _handoff(int generation, Future<void> Function() action) =>
      _playbackCoordinator.run(() async {
        if (_closed || generation != _generation) return;
        try {
          await _untilClosed(beforePlay?.call() ?? Future.value());
          if (_closed || generation != _generation) return;
          await action();
        } catch (_) {
          if (!_closed && generation == _generation) {
            loading = false;
            error = '播放操作失败，请重新选择电台。';
            notifyListeners();
          }
        }
      });

  Future<void> select(LiveChannel station, {int lineIndex = 0}) {
    if (_closed || station.playbackUrls.isEmpty) return Future<void>.value();
    if (!(policy?.channelAllowed(station, radio: true) ?? true)) {
      error = '当前电台已被内容策略拦截';
      notifyListeners();
      return Future<void>.value();
    }
    final retire = (loading || error != null) && _engine != null;
    final generation = ++_generation;
    _interruptSelection();
    final interrupt = _selectionInterrupt = Completer<void>();
    selected = station;
    _userPaused = false;
    line = lineIndex.clamp(0, station.playbackUrls.length - 1);
    final uri = station.playbackUrls[line];
    loading = true;
    playing = false;
    error = null;
    _needsOpen = false;
    notifyListeners();
    return _handoff(
      generation,
      () => _enqueue(() async {
        if (_closed || generation != _generation) return;
        try {
          if (retire) await _discardEngine();
          if (_closed || generation != _generation) return;
          final engine = _player();
          await _untilClosed(engine.stop(), interrupted: interrupt.future);
          if (_closed || generation != _generation) return;
          await _untilClosed(
            engine.setVolume(volume),
            interrupted: interrupt.future,
          );
          if (_closed || generation != _generation) return;
          policy?.requireChannel(station, radio: true);
          await _untilClosed(
            engine.open(uri, headers: station.headersFor(uri)),
            interrupted: interrupt.future,
          );
          if (!_closed && generation == _generation) {
            if (error != null) {
              await _discardEngine();
            } else {
              _needsOpen = false;
            }
          }
        } on TimeoutException {
          await _discardEngine();
          if (!_closed && generation == _generation) error = '电台连接超时，请重试或换台。';
        } catch (_) {
          await _discardEngine();
          if (!_closed && generation == _generation) error = '电台连接失败，请重试或换台。';
        } finally {
          if (!_closed && generation == _generation) {
            loading = false;
            notifyListeners();
            if (error != null && line + 1 < station.playbackUrls.length) {
              unawaited(select(station, lineIndex: line + 1));
            }
          }
        }
      }),
    );
  }

  @override
  Future<void> toggle() {
    if (_closed || selected == null) return Future<void>.value();
    if (selected != null &&
        !(policy?.channelAllowed(selected!, radio: true) ?? true)) {
      return stop();
    }
    if (_needsOpen && selected != null) {
      return select(selected!, lineIndex: line);
    }
    final generation = _generation;
    final resume = !playing;
    _userPaused = !resume;
    Future<void> command() => _command((engine) async {
      if (_closed || generation != _generation) return;
      if (selected == null ||
          !(policy?.channelAllowed(selected!, radio: true) ?? true)) {
        return;
      }
      if (resume) {
        await engine.play();
      } else {
        await engine.pause();
      }
    });
    return resume ? _handoff(generation, command) : command();
  }

  Future<void> pause() => _suspend(clear: false);
  @override
  Future<void> stop() => _suspend(clear: true);

  Future<void> _suspend({required bool clear}) {
    if (_closed) return Future<void>.value();
    final retire = loading;
    _userPaused = true;
    ++_generation;
    _interruptSelection();
    loading = false;
    playing = false;
    buffering = false;
    if (retire) _needsOpen = true;
    if (clear) {
      selected = null;
      error = null;
    }
    notifyListeners();
    if (retire) return _enqueue(_discardEngine);
    return _command((engine) => clear ? engine.stop() : engine.pause());
  }

  void _interruptSelection() {
    final interrupt = _selectionInterrupt;
    if (interrupt != null && !interrupt.isCompleted) interrupt.complete();
  }

  Future<void> setVolume(double value) {
    if (_closed) return Future<void>.value();
    volume = value.clamp(0, 100);
    notifyListeners();
    return _command((engine) => engine.setVolume(volume));
  }

  Future<void> _command(Future<void> Function(PlayerEngine) operation) =>
      _enqueue(() async {
        if (_closed || _engine == null) return;
        try {
          await _untilClosed(operation(_engine!));
        } catch (_) {
          if (!_closed) error = '播放操作失败，请重新选择电台。';
        }
        if (!_closed) notifyListeners();
      });

  Future<void> _untilClosed(
    Future<void> operation, {
    Future<void>? interrupted,
  }) async {
    final stopped = Completer<void>();
    final unlink = _closing.listen(stopped.complete);
    final expired = Completer<void>();
    final timer = Timer(
      operationTimeout,
      () =>
          expired.completeError(TimeoutException('Radio operation timed out')),
    );
    try {
      await Future.any([
        operation,
        expired.future,
        stopped.future,
        ?interrupted,
      ]);
    } finally {
      timer.cancel();
      unlink();
    }
  }

  Future<void> _discardEngine() async {
    _needsOpen = true;
    playing = false;
    buffering = false;
    final engine = _engine;
    _engine = null;
    await _states?.cancel();
    await _errors?.cancel();
    _states = null;
    _errors = null;
    await engine?.dispose();
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    policy?.removeListener(_policyChanged);
    _closed = true;
    _interruptSelection();
    ++_generation;
    _closing.cancel();
    await _states?.cancel();
    await _errors?.cancel();
    try {
      // Native disposal interrupts a pending open; waiting for it first deadlocks.
      await _engine?.dispose();
    } finally {
      super.dispose();
    }
  }
}
