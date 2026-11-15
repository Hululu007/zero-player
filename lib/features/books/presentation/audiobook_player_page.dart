import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_services.dart';
import '../application/audiobook_controller.dart';
import '../domain/book.dart';
import 'book_page_route.dart';

final class AudiobookPlayerPage extends StatefulWidget {
  const AudiobookPlayerPage({
    super.key,
    required this.services,
    required this.book,
    required this.chapters,
    required this.initial,
  });
  final AppServices services;
  final Book book;
  final List<BookChapter> chapters;
  final BookChapter initial;

  @override
  State<AudiobookPlayerPage> createState() => _AudiobookPlayerPageState();
}

final class _AudiobookPlayerPageState extends State<AudiobookPlayerPage> {
  late final AudiobookController player = widget.services.audiobookPlayer;

  @override
  void initState() {
    super.initState();
    player.addListener(_refresh);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) player.start(widget.book, widget.chapters, widget.initial);
    });
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    player.removeListener(_refresh);
    super.dispose();
  }

  String _time(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${hours == 0 ? '' : '$hours:'}$minutes:$seconds';
  }

  Future<void> _chooseChapter() async {
    final chapter = await showModalBottomSheet<BookChapter>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .7,
          child: ListenableBuilder(
            listenable: Listenable.merge([
              player,
              widget.services.contentPolicy,
            ]),
            builder: (context, _) {
              final books = widget.services.books;
              final work = player.book;
              if (work == null || !books.bookAllowed(work)) {
                return const Center(child: Text('当前内容策略限制访问此作品'));
              }
              final chapters = player.chapters
                  .where((item) => books.policy.textAllowed(item.title))
                  .toList();
              return ListView.builder(
                itemCount: chapters.length,
                itemBuilder: (context, index) {
                  final item = chapters[index];
                  return ListTile(
                    selected: item.id == player.chapter?.id,
                    leading: Text('${index + 1}'),
                    title: Text(item.title, maxLines: 2),
                    onTap: () => Navigator.pop(context, item),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
    final work = player.book;
    if (chapter != null &&
        mounted &&
        work != null &&
        widget.services.books.bookAllowed(work) &&
        widget.services.contentPolicy.textAllowed(chapter.title) &&
        player.chapters.contains(chapter)) {
      player.choose(chapter);
    }
  }

  void _skip(Duration offset) {
    final state = player.snapshot;
    if (player.loading || state.duration <= Duration.zero) return;
    final target = (state.position.inMilliseconds + offset.inMilliseconds)
        .clamp(0, state.duration.inMilliseconds);
    unawaited(player.seek(Duration(milliseconds: target)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!widget.services.books.bookAllowed(player.book ?? widget.book)) {
      return Scaffold(
        appBar: AppBar(title: const Text('听书')),
        body: const Center(child: Text('当前内容策略限制访问此作品')),
      );
    }
    final chapter = player.chapter;
    final state = player.snapshot;
    final active = player.active && !player.loading && player.error == null;
    final duration = state.duration.inMilliseconds;
    return Scaffold(
      appBar: AppBar(title: Text(player.book?.title ?? widget.book.title)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              Icon(
                Icons.headphones_outlined,
                size: 88,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                chapter?.title ?? '播放已停止',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
              if (player.loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Column(
                    children: [
                      LinearProgressIndicator(),
                      SizedBox(height: 12),
                      Text('正在准备音频章节…'),
                    ],
                  ),
                ),
              if (player.error != null)
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(player.error!, textAlign: TextAlign.center),
                ),
              Slider(
                value: state.position.inMilliseconds
                    .clamp(0, duration)
                    .toDouble(),
                max: duration > 0 ? duration.toDouble() : 1,
                onChanged: !active || duration <= 0
                    ? null
                    : (value) =>
                          player.seek(Duration(milliseconds: value.round())),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_time(state.position)),
                  Text(_time(state.duration)),
                ],
              ),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  IconButton(
                    tooltip: '上一章',
                    icon: const Icon(Icons.skip_previous),
                    onPressed: !player.loading && player.index > 0
                        ? () => player.choose(player.chapters[player.index - 1])
                        : null,
                  ),
                  IconButton.filled(
                    tooltip: state.playing ? '暂停' : '播放',
                    icon: Icon(state.playing ? Icons.pause : Icons.play_arrow),
                    onPressed: active ? player.toggle : null,
                  ),
                  IconButton(
                    tooltip: '后退 15 秒',
                    icon: const Icon(Icons.fast_rewind),
                    onPressed: active
                        ? () => _skip(const Duration(seconds: -15))
                        : null,
                  ),
                  IconButton(
                    tooltip: '前进 30 秒',
                    icon: const Icon(Icons.forward_30),
                    onPressed: active
                        ? () => _skip(const Duration(seconds: 30))
                        : null,
                  ),
                  IconButton(
                    tooltip: '下一章',
                    icon: const Icon(Icons.skip_next),
                    onPressed:
                        !player.loading &&
                            player.index >= 0 &&
                            player.index + 1 < player.chapters.length
                        ? () => player.choose(player.chapters[player.index + 1])
                        : null,
                  ),
                  DropdownButton<double>(
                    value: player.rate,
                    items: [
                      for (final rate in [.75, 1.0, 1.25, 1.5, 2.0])
                        DropdownMenuItem(
                          value: rate,
                          child: Text(
                            '${rate.toStringAsFixed(rate == 1 || rate == 2 ? 0 : 2)}×',
                          ),
                        ),
                    ],
                    onChanged: !active
                        ? null
                        : (value) {
                            if (value != null) unawaited(player.setRate(value));
                          },
                  ),
                ],
              ),
              TextButton.icon(
                onPressed: player.loading || !player.active
                    ? null
                    : _chooseChapter,
                icon: const Icon(Icons.format_list_numbered),
                label: Text('章节 ${player.index + 1}/${player.chapters.length}'),
              ),
              SwitchListTile(
                title: const Text('自动播放下一章'),
                value: player.autoNext,
                onChanged: player.setAutoNext,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.bedtime_outlined),
                  const SizedBox(width: 8),
                  DropdownButton<int>(
                    value: player.sleepUntil == null ? 0 : null,
                    hint: const Text('定时关闭已设置'),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('不定时')),
                      DropdownMenuItem(value: 15, child: Text('15 分钟后')),
                      DropdownMenuItem(value: 30, child: Text('30 分钟后')),
                      DropdownMenuItem(value: 60, child: Text('60 分钟后')),
                    ],
                    onChanged: (minutes) => player.setSleep(
                      minutes == null || minutes == 0
                          ? null
                          : Duration(minutes: minutes),
                    ),
                  ),
                ],
              ),
              if (!player.loading && player.error != null && player.active)
                Center(
                  child: OutlinedButton(
                    onPressed: chapter == null
                        ? null
                        : () => player.choose(chapter),
                    child: const Text('重试'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

final class AudiobookMiniPlayer extends StatelessWidget {
  const AudiobookMiniPlayer({super.key, required this.services});
  final AppServices services;

  void _expand(BuildContext context, AudiobookController player) {
    final book = player.book;
    final chapter = player.chapter;
    if (book == null || chapter == null) return;
    Navigator.of(context, rootNavigator: true).push(
      BookPageRoute<void>(
        builder: (_) => AudiobookPlayerPage(
          services: services,
          book: book,
          chapters: player.chapters,
          initial: chapter,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: services.audiobookPlayer,
    builder: (context, _) {
      final player = services.audiobookPlayer;
      if (!player.active) return const SizedBox.shrink();
      if (player.book == null || !services.books.bookAllowed(player.book!)) {
        return ListTile(
          title: const Text('当前内容策略限制播放'),
          trailing: IconButton(
            tooltip: '停止听书',
            onPressed: player.stop,
            icon: const Icon(Icons.close),
          ),
        );
      }
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: SafeArea(
          top: false,
          bottom: false,
          child: Row(
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Icon(Icons.headphones_outlined),
              ),
              Expanded(
                child: InkWell(
                  onTap: () => _expand(context, player),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          player.book?.title ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          player.error ??
                              (player.loading
                                  ? '正在准备音频…'
                                  : player.playing
                                  ? '${player.chapter?.title} · 后台播放中'
                                  : '${player.chapter?.title} · 已暂停'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: '展开听书播放器',
                onPressed: () => _expand(context, player),
                icon: const Icon(Icons.keyboard_arrow_up),
              ),
              IconButton(
                tooltip: player.playing ? '暂停听书' : '播放听书',
                onPressed: player.loading || player.error != null
                    ? null
                    : player.toggle,
                icon: Icon(player.playing ? Icons.pause : Icons.play_arrow),
              ),
              IconButton(
                tooltip: '停止听书',
                onPressed: player.stop,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      );
    },
  );
}
