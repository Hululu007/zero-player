import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/widgets.dart';
import '../../library/data/history_repository.dart';

final class ContinueWatching extends StatelessWidget {
  const ContinueWatching({
    super.key,
    required this.history,
    this.allowed,
    this.allowStale = true,
  });
  final Future<List<WatchEntry>> history;
  final bool Function(WatchEntry)? allowed;
  final bool allowStale;
  @override
  Widget build(BuildContext context) => FutureBuilder<List<WatchEntry>>(
    future: history,
    builder: (context, snapshot) {
      final entries = (snapshot.data ?? <WatchEntry>[])
          .where((entry) => allowed?.call(entry) ?? true)
          .toList();
      if (entries.isEmpty) return const SizedBox.shrink();
      return Visibility(
        visible:
            allowStale ||
            (!snapshot.hasError &&
                snapshot.connectionState == ConnectionState.done),
        maintainState: true,
        maintainAnimation: true,
        maintainSize: true,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('继续观看', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              SizedBox(
                height: 86,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (_, i) {
                    final e = entries[i];
                    return SizedBox(
                      width: 240,
                      child: Card(
                        child: ListTile(
                          title: Text(
                            e.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${e.episode} · ${clockText(e.position)}',
                          ),
                          trailing: const Icon(Icons.play_circle_outline),
                          onTap: () => context.push(
                            e.sourceId == 'local'
                                ? '/local?id=${Uri.encodeQueryComponent(e.remoteId)}'
                                : '/detail/${e.sourceId}/${Uri.encodeComponent(e.remoteId)}',
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
