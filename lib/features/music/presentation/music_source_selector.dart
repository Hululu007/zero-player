import 'package:flutter/material.dart';
import '../../../app/app_services.dart';
import '../data/public_music_sources.dart';
import 'lx_sources_dialog.dart';

final class MusicSourceSelector extends StatelessWidget {
  const MusicSourceSelector({
    super.key,
    required this.services,
    required this.value,
    required this.onChanged,
    this.compact = false,
  });
  final AppServices services;
  final String value;
  final ValueChanged<String> onChanged;
  final bool compact;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: services.musicBrowser,
    builder: (context, _) => _selector(context),
  );

  Widget _selector(BuildContext context) => compact
      ? Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: _dropdown(context)),
                    if (value != 'all') _favoriteButton(context),
                    IconButton(
                      tooltip: '音乐渠道与 LX 音源',
                      onPressed: () => showLxSources(context, services),
                      icon: const Icon(Icons.tune),
                    ),
                  ],
                ),
                if (services.musicBrowser.preferenceNotice case final notice?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      notice,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        )
      : Card(
          child: ListTile(
            title: DropdownButton<String>(
              value: value,
              isExpanded: true,
              items: [
                const DropdownMenuItem(
                  value: 'all',
                  child: Text('多源聚合 · 并发搜索', overflow: TextOverflow.ellipsis),
                ),
                for (final id in services.musicBrowser.orderedProviders)
                  DropdownMenuItem(
                    value: id,
                    child: Row(
                      children: [
                        if (services.musicBrowser.favoriteProviders.contains(
                          id,
                        )) ...[
                          Icon(
                            Icons.star,
                            size: 18,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: Text(
                            musicSources[id]!,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value != null) onChanged(value);
              },
            ),
            subtitle: Text(
              services.musicBrowser.preferenceNotice ?? '播放渠道 · 收藏渠道优先搜索',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (value != 'all') _favoriteButton(context),
                IconButton(
                  tooltip: '音乐渠道与 LX 音源',
                  onPressed: () => showLxSources(context, services),
                  icon: const Icon(Icons.tune),
                ),
              ],
            ),
          ),
        );

  Widget _dropdown(BuildContext context) => DropdownButton<String>(
    value: value,
    isExpanded: true,
    underline: const SizedBox.shrink(),
    items: [
      const DropdownMenuItem(
        value: 'all',
        child: Text('多源聚合', overflow: TextOverflow.ellipsis),
      ),
      for (final id in services.musicBrowser.orderedProviders)
        DropdownMenuItem(
          value: id,
          child: Text(musicSources[id]!, overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: (next) {
      if (next != null) onChanged(next);
    },
  );

  Widget _favoriteButton(BuildContext context) {
    final favorite = services.musicBrowser.favoriteProviders.contains(value);
    return IconButton(
      tooltip: favorite ? '取消收藏音乐渠道' : '收藏音乐渠道',
      onPressed: () => services.musicBrowser.setFavorite(value, !favorite),
      icon: Icon(favorite ? Icons.star : Icons.star_outline),
      color: favorite ? Theme.of(context).colorScheme.primary : null,
    );
  }
}
