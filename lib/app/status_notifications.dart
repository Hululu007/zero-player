import 'dart:async';

import 'package:flutter/services.dart';

import 'app_services.dart';

final class StatusNotifications {
  StatusNotifications(this.services) {
    _channel.setMethodCallHandler(_handle);
    services.bookDownloads.addListener(refresh);
    services.musicPlayer.addListener(refresh);
    services.contentPolicy.addListener(refresh);
    services.books.sourceRiskChanges.addListener(refresh);
    services.books.store.vault.addListener(refresh);
    refresh();
  }

  final AppServices services;
  static const _channel = MethodChannel('zero_player/status_notifications');
  Timer? _timer;
  bool _closed = false;
  ({int count, int total, int finished})? _downloadState;
  ({bool active, bool playing, bool loading})? _musicState;

  Future<void> _handle(MethodCall call) async {
    if (_closed) return;
    switch (call.method) {
      case 'refresh':
        invalidate();
      case 'toggleMusic':
        if (services.musicPlayer.active) await services.musicPlayer.toggle();
    }
  }

  void invalidate() {
    _downloadState = null;
    _musicState = null;
    refresh();
  }

  void refresh() {
    if (_closed) return;
    _timer ??= Timer(const Duration(milliseconds: 350), () {
      _timer = null;
      unawaited(_update());
    });
  }

  Future<void> _update() async {
    try {
      final books = services.books;
      final vault = books.store.vault;
      await vault.ensureLoaded();
      if (_closed) return;
      var count = 0, total = 0, finished = 0;
      for (final task in services.bookDownloads.activeTasks) {
        if (vault.isPrivate(task.book.id) || !books.bookAllowed(task.book)) {
          continue;
        }
        count++;
        total += task.total;
        finished += task.finished;
      }
      final downloads = (count: count, total: total, finished: finished);
      final player = services.musicPlayer;
      final music = (
        active: player.active,
        playing: player.playing,
        loading: player.loading,
      );
      final updates = <Future<void>>[];
      if (downloads != _downloadState) {
        _downloadState = downloads;
        updates.add(
          _channel.invokeMethod('downloads', {
            'count': count,
            'total': total,
            'finished': finished,
          }),
        );
      }
      if (music != _musicState) {
        _musicState = music;
        updates.add(
          _channel.invokeMethod('music', {
            'active': music.active,
            'playing': music.playing,
            'loading': music.loading,
          }),
        );
      }
      await Future.wait(updates);
    } catch (_) {
      // A restarted activity or unavailable platform channel can retry on resume.
      _downloadState = null;
      _musicState = null;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _channel.setMethodCallHandler(null);
    services.bookDownloads.removeListener(refresh);
    services.musicPlayer.removeListener(refresh);
    services.contentPolicy.removeListener(refresh);
    services.books.sourceRiskChanges.removeListener(refresh);
    services.books.store.vault.removeListener(refresh);
    unawaited(_clear());
  }

  Future<void> _clear() async {
    try {
      await Future.wait([
        _channel.invokeMethod<void>('downloads', {'count': 0}),
        _channel.invokeMethod<void>('music', {'active': false}),
      ]);
    } on Exception {
      // Android also clears the notifications when the activity is destroyed.
    }
  }
}
