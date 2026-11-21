import 'package:flutter/material.dart';

import '../application/publication_discovery.dart';
import '../data/publication_share.dart';
import '../domain/acquisition_task.dart';
import '../domain/publication.dart';
import '../domain/publication_library.dart';

String publicationSize(int bytes) {
  if (bytes < 1 << 10) return '$bytes B';
  if (bytes < 1 << 20) return '${(bytes / (1 << 10)).toStringAsFixed(1)} KiB';
  return '${(bytes / (1 << 20)).toStringAsFixed(bytes < 10 << 20 ? 1 : 0)} MiB';
}

String publicationSpaceDetails(PublicationSpaceShortfall info) =>
    '上次申请需要 ${publicationSize(info.requiredBytes)} · '
    '可用 ${publicationSize(info.availableBytes)} · '
    '受保护占用 ${publicationSize(info.protectedBytes)}';

String publicationSourceProblemLabel(PublicationProblem problem) =>
    switch (problem) {
      PublicationProblem.missing => '书源入口已失效',
      PublicationProblem.invalid => '书源返回的数据格式无效',
      _ => problem.label,
    };

class PublicationShelfView extends StatelessWidget {
  const PublicationShelfView({
    super.key,
    required this.entries,
    required this.open,
    required this.action,
    required this.onLocal,
    required this.onLegacy,
    required this.onUnlisted,
    required this.exportBackup,
    required this.restoreBackup,
  });
  final List<PublicationHolding> entries;
  final void Function(PublicationHolding) open;
  final void Function(PublicationHolding, String) action;
  final VoidCallback onLocal, onLegacy, onUnlisted, exportBackup, restoreBackup;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: onLocal,
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('本地导入'),
          ),
          OutlinedButton.icon(
            onPressed: onLegacy,
            icon: const Icon(Icons.playlist_add),
            label: const Text('从原书库添加'),
          ),
          PopupMenuButton<String>(
            tooltip: '书库备份',
            onSelected: (value) =>
                (value == 'export' ? exportBackup : restoreBackup)(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'export', child: Text('导出书库备份')),
              PopupMenuItem(value: 'restore', child: Text('导入书库备份')),
            ],
            icon: const Icon(Icons.settings_backup_restore),
          ),
          TextButton.icon(
            onPressed: onUnlisted,
            icon: const Icon(Icons.folder_open_outlined),
            label: const Text('已移除的副本'),
          ),
        ],
      ),
      const SizedBox(height: 14),
      if (entries.isEmpty)
        const Padding(padding: EdgeInsets.all(16), child: Text('书库还没有图书。')),
      for (final entry in entries)
        Card(
          child: ListTile(
            leading: Icon(
              entry.resident ? Icons.book_outlined : Icons.cloud_off_outlined,
            ),
            title: Text(entry.edition.title),
            subtitle: Text(
              [
                if (entry.edition.author.isNotEmpty) entry.edition.author,
                entry.format.label,
                entry.resident ? publicationSize(entry.bytes) : '本地副本缺失',
                if (entry.kept) '保留',
              ].join(' · '),
            ),
            onTap: entry.resident
                ? () => open(entry)
                : () => action(entry, 'recover'),
            trailing: PopupMenuButton<String>(
              tooltip: '图书操作',
              onSelected: (value) => action(entry, value),
              itemBuilder: (_) => [
                if (entry.resident)
                  const PopupMenuItem(value: 'export', child: Text('导出图书文件')),
                if (entry.resident)
                  const PopupMenuItem(value: 'save', child: Text('保存到指定目录')),
                if (entry.resident)
                  const PopupMenuItem(value: 'delete', child: Text('删除本地文件')),
                if (!entry.resident)
                  const PopupMenuItem(
                    value: 'recover',
                    child: Text('重新获取或关联文件'),
                  ),
                PopupMenuItem(
                  value: 'keep',
                  child: Text(entry.kept ? '取消保留' : '保留本地副本'),
                ),
                const PopupMenuItem(value: 'remove', child: Text('从图书书库移除')),
              ],
            ),
          ),
        ),
    ],
  );
}

class PublicationTasksView extends StatelessWidget {
  const PublicationTasksView({
    super.key,
    required this.tasks,
    required this.action,
  });
  final List<AcquisitionTask> tasks;
  final void Function(AcquisitionTask, String) action;

  @override
  Widget build(BuildContext context) {
    if (tasks.isEmpty) return const Center(child: Text('暂无图书下载任务'));
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: tasks.length,
      itemBuilder: (context, index) {
        final task = tasks[index];
        final active =
            task.state == AcquisitionState.resolving ||
            task.state == AcquisitionState.downloading;
        final progress = task.total == null || task.total! < 1
            ? null
            : (task.received / task.total!).clamp(0.0, 1.0);
        final description = switch ((task.problem, task.state)) {
          (PublicationProblem.space, AcquisitionState.waiting) => '等待存储空间',
          (PublicationProblem.space, AcquisitionState.paused) => '空间不足，已暂停',
          _ => task.problem?.label ?? task.state.label,
        };
        return Card(
          child: ExpansionTile(
            key: PageStorageKey(task.id),
            leading: Icon(
              active
                  ? Icons.downloading
                  : task.state == AcquisitionState.complete
                  ? Icons.task_alt
                  : Icons.insert_drive_file_outlined,
            ),
            title: Text(task.edition.title),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${task.candidate.format.label} · $description'),
                if (task.spaceShortfall case final info?)
                  Text(publicationSpaceDetails(info)),
                if (active)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: LinearProgressIndicator(value: progress),
                  ),
              ],
            ),
            children: [
              if (task.received > 0)
                ListTile(
                  title: Text(
                    '${publicationSize(task.received)}${task.total == null ? '' : ' / ${publicationSize(task.total!)}'}',
                  ),
                ),
              for (final failure in task.failures.reversed.take(8))
                ListTile(
                  dense: true,
                  title: Text(
                    '${task.candidates[failure.candidate].link.host} · ${failure.problem.label}',
                  ),
                  subtitle: Text(
                    [
                      _localTime(failure.at),
                      if (failure.retryAt case final retryAt?)
                        '可重试时间 ${_localTime(retryAt)}',
                    ].join('\n'),
                  ),
                ),
              _actions(task, active),
            ],
          ),
        );
      },
    );
  }

  String _localTime(DateTime time) =>
      time.toLocal().toString().split('.').first;

  Widget _actions(AcquisitionTask task, bool active) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
    child: Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        if (active)
          OutlinedButton(
            onPressed: () => action(task, 'pause'),
            child: const Text('暂停'),
          ),
        if (task.state == AcquisitionState.downloaded)
          FilledButton(
            onPressed: () => action(task, 'import'),
            child: const Text('继续导入'),
          ),
        if (task.state == AcquisitionState.downloaded &&
            task.candidate.format == PublicationFormat.zip)
          OutlinedButton(
            onPressed: () => action(task, 'importKeep'),
            child: const Text('导入并保留 ZIP'),
          ),
        if (task.state == AcquisitionState.complete)
          FilledButton(
            onPressed: () => action(task, 'open'),
            child: const Text('打开图书'),
          ),
        if (task.retainedArchive) ...[
          OutlinedButton(
            onPressed: () => action(task, 'readArchive'),
            child: const Text('从原 ZIP 再导入'),
          ),
          TextButton(
            onPressed: () => action(task, 'deleteArchive'),
            child: const Text('删除原 ZIP'),
          ),
        ],
        if (task.state == AcquisitionState.failed ||
            task.state == AcquisitionState.paused ||
            task.state == AcquisitionState.waiting)
          FilledButton(
            onPressed: () => action(task, 'retry'),
            child: Text(
              requiresPublicationFileChoice(task.candidate)
                  ? '选择网盘文件'
                  : (task.state == AcquisitionState.failed ? '重试' : '继续下载'),
            ),
          ),
        if (task.state == AcquisitionState.failed &&
            !requiresPublicationFileChoice(task.candidate) &&
            task.failures.any(
              (failure) => failure.problem == PublicationProblem.shareFile,
            ))
          TextButton(
            onPressed: () => action(task, 'chooseFile'),
            child: const Text('选择网盘文件'),
          ),
        if (task.state == AcquisitionState.failed)
          TextButton(
            onPressed: () => action(task, 'replace'),
            child: const Text('更换分享链接'),
          ),
        TextButton(
          onPressed: () => action(task, 'source'),
          child: const Text('来源链接'),
        ),
        if (task.state != AcquisitionState.importing && !task.retainedArchive)
          TextButton(
            onPressed: () => action(task, 'remove'),
            child: const Text('移除任务'),
          ),
      ],
    ),
  );
}

class PublicationSourcesView extends StatelessWidget {
  const PublicationSourcesView({
    super.key,
    required this.sources,
    required this.action,
    required this.toggle,
    required this.onAdd,
    required this.onQuota,
    required this.onDirectory,
    required this.onClearDirectory,
    required this.usage,
    required this.hasDirectory,
  });
  final List<PublicationSourceStatus> sources;
  final void Function(PublicationSourceStatus, String) action;
  final void Function(PublicationSourceStatus, bool) toggle;
  final VoidCallback onAdd, onQuota, onDirectory, onClearDirectory;
  final ({int used, int reserved, int limit})? usage;
  final bool hasDirectory;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_link),
            label: const Text('导入书源配置'),
          ),
          OutlinedButton.icon(
            onPressed: onQuota,
            icon: const Icon(Icons.storage),
            label: const Text('托管容量'),
          ),
        ],
      ),
      if (usage case final item?) _capacity(item),
      ListTile(
        leading: const Icon(Icons.folder_outlined),
        title: const Text('自动保存目录'),
        subtitle: Text(hasDirectory ? '已设置指定目录' : '应用托管'),
        onTap: onDirectory,
        trailing: hasDirectory
            ? IconButton(
                tooltip: '取消指定目录',
                onPressed: onClearDirectory,
                icon: const Icon(Icons.close),
              )
            : null,
      ),
      for (final item in sources) _sourceCard(item),
    ],
  );

  Widget _capacity(({int used, int reserved, int limit}) item) {
    final over = item.used + item.reserved - item.limit;
    final details = [
      if (item.reserved > 0) '任务待写入 ${publicationSize(item.reserved)}',
      if (over > 0) '超出托管上限 ${publicationSize(over)}',
    ];
    return ListTile(
      leading: const Icon(Icons.sd_storage_outlined),
      title: Text(
        '${publicationSize(item.used)} / ${publicationSize(item.limit)}',
      ),
      subtitle: details.isEmpty ? null : Text(details.join(' · ')),
    );
  }

  Widget _sourceCard(PublicationSourceStatus item) => Card(
    child: Column(
      children: [
        SwitchListTile(
          title: Text(item.source.name),
          value: item.enabled,
          subtitle: Text(
            [
              if (item.source.license.isNotEmpty) item.source.license,
              if (item.problem case final problem?)
                [
                  if (item.paused) '已暂停检索',
                  publicationSourceProblemLabel(problem),
                ].join(' · '),
              if (item.enabled && item.hasSnapshot && item.problem != null)
                '继续使用上次有效目录',
              if (item.synced case final value?)
                '目录更新 ${DateTime.fromMillisecondsSinceEpoch(value).toLocal().toString().split('.').first}',
            ].join('\n'),
          ),
          onChanged: item.source.restricted
              ? null
              : (value) => toggle(item, value),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Wrap(
            spacing: 6,
            children: [
              if (!item.source.restricted)
                TextButton.icon(
                  onPressed: () => action(item, 'favorite'),
                  icon: Icon(item.favorite ? Icons.star : Icons.star_outline),
                  label: Text(item.favorite ? '取消收藏' : '收藏'),
                ),
              TextButton(
                onPressed: () => action(item, 'page'),
                child: const Text('出处'),
              ),
              if (item.enabled)
                TextButton(
                  onPressed: () => action(item, 'check'),
                  child: const Text('检查或更新'),
                ),
              if (item.source.configurable)
                TextButton(
                  onPressed: () => action(item, 'edit'),
                  child: const Text('编辑'),
                ),
              if (item.source.configurable)
                TextButton(
                  onPressed: () => action(item, 'export'),
                  child: const Text('导出规则'),
                ),
              if (item.source.configurable)
                TextButton(
                  onPressed: () => action(item, 'remove'),
                  child: const Text('移除'),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
