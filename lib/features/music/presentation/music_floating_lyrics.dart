import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../application/music_controller.dart';

/// Android system overlay, enabled only after a user action and OS permission.
final class MusicFloatingLyrics extends ChangeNotifier {
  MusicFloatingLyrics._();
  static final instance = MusicFloatingLyrics._();
  static const _channel = MethodChannel('zero_player/platform');
  MusicController? _controller;
  bool enabled = false;
  bool _sending = false;
  bool _queued = false;
  Future<void>? _inFlight;
  Future<void>? _toggleOperation;

  Future<void> toggle(BuildContext context, MusicController controller) =>
      _toggleOperation ??= _toggle(context, controller).whenComplete(() {
        _toggleOperation = null;
      });

  Future<void> _toggle(BuildContext context, MusicController controller) async {
    if (enabled) {
      await disable();
      return;
    }
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _inFlight;
    if (!context.mounted) return;
    final bool permitted;
    try {
      permitted =
          await _channel.invokeMethod<bool>('musicOverlayPermission') ?? false;
    } on Exception {
      return;
    }
    if (!permitted) {
      if (!context.mounted) return;
      final open = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('开启悬浮歌词'),
          content: const Text(
            '需要在系统设置中允许本应用显示在其他应用上层。授权后返回并再次点击悬浮歌词即可开启；拒绝授权时不会显示悬浮窗。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('前往授权'),
            ),
          ],
        ),
      );
      if (open == true) {
        try {
          await _channel.invokeMethod<void>('requestMusicOverlayPermission');
        } on Exception {
          return;
        }
      }
      return;
    }
    _controller = controller;
    controller.addListener(_update);
    enabled = true;
    notifyListeners();
    _update();
  }

  Future<void> disable() async {
    _detach();
    await _inFlight;
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _channel.invokeMethod<void>('hideMusicOverlay');
      } on Exception {
        // The activity may already have been destroyed.
      }
    }
  }

  void _detach() {
    _controller?.removeListener(_update);
    _controller = null;
    if (!enabled) return;
    enabled = false;
    notifyListeners();
  }

  void _update() {
    if (!enabled) return;
    if (_sending) {
      _queued = true;
      return;
    }
    final controller = _controller;
    if (controller == null) return;
    _sending = true;
    _inFlight = _send(controller);
    unawaited(_inFlight);
  }

  Future<void> _send(MusicController controller) async {
    try {
      final track = controller.selected;
      if (track == null) {
        await _channel.invokeMethod<void>('hideMusicOverlay');
        return;
      }
      final line = controller.lyrics.lineAt(controller.lyricPosition);
      final lyric = [
        line?.text ?? '',
        line?.translation ?? '',
      ].where((part) => part.isNotEmpty).join('\n');
      final shown = await _channel.invokeMethod<bool>('updateMusicOverlay', {
        'title': '${track.title} · ${track.artist}',
        'lyric': lyric.isEmpty
            ? (controller.lyricsLoading ? '正在获取歌词…' : '暂无同步歌词')
            : lyric,
        'status': controller.loading
            ? '连接中…'
            : controller.snapshot.buffering
            ? '缓冲中…'
            : controller.playing
            ? '正在播放'
            : '已暂停',
      });
      if (shown != true) _detach();
    } on Exception {
      _detach();
    } finally {
      _sending = false;
      _inFlight = null;
      if (!enabled && defaultTargetPlatform == TargetPlatform.android) {
        try {
          await _channel.invokeMethod<void>('hideMusicOverlay');
        } on Exception {
          // The activity may already have been destroyed.
        }
      }
      if (_queued) {
        _queued = false;
        _update();
      }
    }
  }
}
