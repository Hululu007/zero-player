import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../application/music_controller.dart';

Future<void> showMusicLyrics(
  BuildContext context,
  MusicController controller,
) => Navigator.of(context, rootNavigator: true).push<void>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => _MusicLyricsPage(controller: controller),
  ),
);

final class _MusicLyricsPage extends StatefulWidget {
  const _MusicLyricsPage({required this.controller});
  final MusicController controller;

  @override
  State<_MusicLyricsPage> createState() => _MusicLyricsPageState();
}

final class _MusicLyricsPageState extends State<_MusicLyricsPage> {
  final _scroll = ScrollController();
  Object? _lastLine;
  DateTime? _manualScrollUntil;
  double get _offsetSeconds =>
      widget.controller.lyricOffset.inMilliseconds / 1000;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final current = controller.lyrics.indexAt(controller.lyricPosition);
      final extent = MediaQuery.textScalerOf(context).scale(92);
      _followCurrent(current, extent);
      final colors = Theme.of(context).colorScheme;
      return Scaffold(
        appBar: AppBar(title: const Text('同步歌词')),
        body: SafeArea(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  colors.surface,
                  colors.primaryContainer.withValues(alpha: .55),
                  colors.surface,
                ],
              ),
            ),
            child: Column(
              children: [
                _header(context),
                Expanded(child: _lyrics(context, current, extent)),
                _calibration(),
                _controls(),
              ],
            ),
          ),
        ),
      );
    },
  );

  void _followCurrent(int current, double extent) {
    final line = (widget.controller.lyrics, current, extent);
    if (_lastLine == line) return;
    _lastLine = line;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _lastLine != line ||
          !_scroll.hasClients ||
          (_manualScrollUntil?.isAfter(DateTime.now()) ?? false)) {
        return;
      }
      _scroll.jumpTo(
        (current * extent).clamp(0.0, _scroll.position.maxScrollExtent),
      );
    });
  }

  Widget _header(BuildContext context) {
    final track = widget.controller.selected;
    if (track == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Column(
        children: [
          Icon(Icons.graphic_eq, size: 38, color: theme.colorScheme.primary),
          const SizedBox(height: 8),
          Text(
            track.title,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall,
          ),
          Text(
            track.artist,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          if (widget.controller.lyrics.lines.isNotEmpty)
            Text(switch (widget.controller.lyrics.sourceId) {
              'kugou' => '歌词来源：酷狗',
              'lrclib' => '歌词来源：LRCLIB',
              _ => '歌词来源：网易云',
            }, style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }

  Widget _lyrics(BuildContext context, int current, double extent) {
    final controller = widget.controller;
    final lines = controller.lyrics.lines;
    if (lines.isEmpty) {
      return Center(
        child: Text(controller.lyricsLoading ? '正在获取歌词…' : '暂无可显示的同步歌词'),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final margin = ((constraints.maxHeight - extent) / 2).clamp(
          0.0,
          double.infinity,
        );
        return NotificationListener<UserScrollNotification>(
          onNotification: (notification) {
            if (notification.direction != ScrollDirection.idle) {
              _manualScrollUntil = DateTime.now().add(
                const Duration(seconds: 5),
              );
            }
            return false;
          },
          child: ListView.builder(
            controller: _scroll,
            itemCount: lines.length,
            itemExtent: extent,
            padding: EdgeInsets.symmetric(vertical: margin, horizontal: 24),
            itemBuilder: (context, index) =>
                _lyricTile(context, index, current),
          ),
        );
      },
    );
  }

  Widget _lyricTile(BuildContext context, int index, int current) {
    final lyric = widget.controller.lyrics.lines[index];
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final active = index == current;
    return TextButton(
      onPressed: () => widget.controller.seek(lyric.time),
      style: TextButton.styleFrom(
        foregroundColor: active
            ? colors.onPrimaryContainer
            : colors.onSurfaceVariant,
        backgroundColor: active ? colors.primaryContainer : Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            lyric.text.isEmpty ? '♪' : lyric.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: active
                ? theme.textTheme.titleLarge
                : theme.textTheme.bodyLarge,
          ),
          if (lyric.translation.isNotEmpty)
            Text(
              lyric.translation,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
    );
  }

  Widget _calibration() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Row(
      children: [
        const Icon(Icons.sync, size: 18),
        const SizedBox(width: 8),
        Text(
          '歌词校准 ${_offsetSeconds >= 0 ? '+' : ''}${_offsetSeconds.toStringAsFixed(1)} 秒',
        ),
        Expanded(
          child: Slider(
            value: _offsetSeconds,
            min: -3,
            max: 3,
            divisions: 60,
            onChanged: (value) => widget.controller.setLyricOffset(
              Duration(milliseconds: (value * 1000).round()),
            ),
          ),
        ),
        IconButton(
          tooltip: '重置歌词校准',
          onPressed: () => widget.controller.setLyricOffset(Duration.zero),
          icon: const Icon(Icons.restart_alt),
        ),
      ],
    ),
  );

  Widget _controls() {
    final controller = widget.controller;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: '上一首',
          onPressed: controller.previous,
          icon: const Icon(Icons.skip_previous),
        ),
        IconButton(
          tooltip: controller.playing ? '暂停音乐' : '播放音乐',
          onPressed: controller.loading ? null : controller.toggle,
          icon: Icon(controller.playing ? Icons.pause : Icons.play_arrow),
        ),
        IconButton(
          tooltip: '下一首',
          onPressed: controller.hasNext ? controller.next : null,
          icon: const Icon(Icons.skip_next),
        ),
      ],
    );
  }
}
