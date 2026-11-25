import 'package:flutter/material.dart';

import '../application/publication_collections.dart';
import '../data/publication_share.dart';
import '../data/publication_share_provider.dart';
import '../domain/acquisition_task.dart';
import '../domain/publication.dart';
import '../domain/publication_library.dart';

String publicationSize(int bytes) {
  if (bytes < 1 << 10) return '$bytes B';
  if (bytes < 1 << 20) return '${(bytes / (1 << 10)).toStringAsFixed(1)} KiB';
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GiB';
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

enum _ShelfFilter {
  all('全部'),
  recent('最近阅读'),
  finished('已读完'),
  missing('待恢复');

  const _ShelfFilter(this.label);
  final String label;
}

class PublicationShelfView extends StatefulWidget {
  const PublicationShelfView({
    super.key,
    required this.entries,
    this.hiddenCount = 0,
    required this.open,
    required this.action,
    required this.onLocal,
    required this.onLegacy,
    required this.onUnlisted,
    required this.exportBackup,
    required this.restoreBackup,
    required this.groups,
    required this.onGroups,
    required this.onLists,
  });
  final List<PublicationHolding> entries;
  final int hiddenCount;
  final void Function(PublicationHolding) open;
  final void Function(PublicationHolding, String) action;
  final VoidCallback onLocal, onLegacy, onUnlisted, exportBackup, restoreBackup;
  final List<PublicationGroup> groups;
  final VoidCallback onGroups, onLists;

  @override
  State<PublicationShelfView> createState() => _PublicationShelfViewState();
}

class _PublicationShelfViewState extends State<PublicationShelfView>
    with AutomaticKeepAliveClientMixin {
  _ShelfFilter _filter = _ShelfFilter.all;
  String _query = '';
  String? _group;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final group = widget.groups.any((item) => item.id == _group) || _group == ''
        ? _group
        : null;
    final entries = widget.entries
        .where(
          (entry) =>
              (group == null || (entry.groupId ?? '') == group) &&
              entry.edition.matches(_query) &&
              switch (_filter) {
                _ShelfFilter.all => true,
                _ShelfFilter.recent => entry.lastRead > 0,
                _ShelfFilter.finished => entry.finished,
                _ShelfFilter.missing => !entry.resident,
              },
        )
        .toList();
    if (_filter == _ShelfFilter.recent) {
      entries.sort((a, b) => b.lastRead.compareTo(a.lastRead));
    }
    return ListView.builder(
      key: const PageStorageKey('publication-shelf'),
      padding: const EdgeInsets.all(16),
      itemCount: 1 + (entries.isEmpty ? 1 : entries.length),
      itemBuilder: (context, index) {
        if (index == 0) return _controls(group);
        if (entries.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              widget.entries.isEmpty
                  ? (widget.hiddenCount == 0 ? '书库还没有图书' : _hiddenMessage)
                  : '没有符合条件的图书',
            ),
          );
        }
        return _shelfCard(entries[index - 1]);
      },
    );
  }

  String get _hiddenMessage => '当前内容策略隐藏了 ${widget.hiddenCount} 本图书';

  Widget _controls(String? group) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (widget.hiddenCount > 0 && widget.entries.isNotEmpty)
        Text(_hiddenMessage),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: widget.onLocal,
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('本地导入'),
          ),
          OutlinedButton.icon(
            onPressed: widget.onLegacy,
            icon: const Icon(Icons.playlist_add),
            label: const Text('从原书库添加'),
          ),
          PopupMenuButton<String>(
            tooltip: '书库备份',
            onSelected: (value) => (value == 'export'
                ? widget.exportBackup
                : widget.restoreBackup)(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'export', child: Text('导出书库备份')),
              PopupMenuItem(value: 'restore', child: Text('导入书库备份')),
            ],
            icon: const Icon(Icons.settings_backup_restore),
          ),
          TextButton.icon(
            onPressed: widget.onUnlisted,
            icon: const Icon(Icons.folder_open_outlined),
            label: const Text('已移除的副本'),
          ),
          TextButton.icon(
            onPressed: widget.onGroups,
            icon: const Icon(Icons.folder_outlined),
            label: const Text('管理分组'),
          ),
          TextButton.icon(
            onPressed: widget.onLists,
            icon: const Icon(Icons.list_alt_outlined),
            label: const Text('我的书单'),
          ),
        ],
      ),
      const SizedBox(height: 14),
      TextField(
        decoration: const InputDecoration(
          labelText: '筛选书库',
          prefixIcon: Icon(Icons.search),
          border: OutlineInputBorder(),
        ),
        onChanged: (query) => setState(() => _query = query.trim()),
      ),
      Wrap(
        spacing: 16,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: DropdownButton<String>(
              isExpanded: true,
              value: group,
              hint: const Text('全部分组'),
              items: [
                const DropdownMenuItem(child: Text('全部分组')),
                const DropdownMenuItem(value: '', child: Text('未分组')),
                for (final option in widget.groups)
                  DropdownMenuItem(
                    value: option.id,
                    child: Text(option.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (id) => setState(() => _group = id),
            ),
          ),
          DropdownButton<_ShelfFilter>(
            value: _filter,
            items: [
              for (final option in _ShelfFilter.values)
                DropdownMenuItem(value: option, child: Text(option.label)),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _filter = value);
            },
          ),
        ],
      ),
    ],
  );

  Widget _shelfCard(PublicationHolding entry) => Card(
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
          if (entry.finished) '已读完',
          if (widget.groups
                  .where((group) => group.id == entry.groupId)
                  .firstOrNull
              case final group?)
            group.name,
          if (entry.kept) '保留',
        ].join(' · '),
      ),
      onTap: entry.resident
          ? () => widget.open(entry)
          : () => widget.action(entry, 'recover'),
      trailing: PopupMenuButton<String>(
        tooltip: '图书操作',
        onSelected: (value) => widget.action(entry, value),
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'group', child: Text('移动到分组')),
          PopupMenuItem(
            value: 'finished',
            child: Text(entry.finished ? '取消已读完' : '标记已读完'),
          ),
          if (entry.resident)
            const PopupMenuItem(value: 'export', child: Text('导出图书文件')),
          if (entry.resident)
            const PopupMenuItem(value: 'save', child: Text('保存到指定目录')),
          if (entry.resident)
            const PopupMenuItem(value: 'delete', child: Text('删除本地文件')),
          if (!entry.resident)
            const PopupMenuItem(value: 'recover', child: Text('重新获取或关联文件')),
          PopupMenuItem(
            value: 'keep',
            child: Text(entry.kept ? '取消保留' : '保留本地副本'),
          ),
          const PopupMenuItem(value: 'remove', child: Text('从书库移除')),
        ],
      ),
    ),
  );
}

enum _TaskFilter {
  all('全部'),
  active('待处理'),
  complete('已入库');

  const _TaskFilter(this.label);
  final String label;

  bool matches(AcquisitionTask task) => switch (this) {
    all => true,
    active => task.state != AcquisitionState.complete,
    complete => task.state == AcquisitionState.complete,
  };
}

class PublicationTasksView extends StatefulWidget {
  const PublicationTasksView({
    super.key,
    required this.tasks,
    this.hiddenCount = 0,
    required this.action,
    this.websiteAvailable,
    this.browserDownloadAvailable,
  });
  final List<AcquisitionTask> tasks;
  final int hiddenCount;
  final void Function(AcquisitionTask, String) action;
  final bool Function(AcquisitionTask)? websiteAvailable;
  final bool Function(AcquisitionTask)? browserDownloadAvailable;

  @override
  State<PublicationTasksView> createState() => _PublicationTasksViewState();
}

class _PublicationTasksViewState extends State<PublicationTasksView>
    with AutomaticKeepAliveClientMixin {
  _TaskFilter _filter = _TaskFilter.all;
  String _query = '';

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final tasks = widget.tasks
        .where((task) => _filter.matches(task) && task.edition.matches(_query))
        .toList();
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: 1 + (tasks.isEmpty ? 1 : tasks.length),
      itemBuilder: (context, index) {
        if (index == 0) return _filters();
        if (tasks.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              widget.tasks.isEmpty
                  ? (widget.hiddenCount == 0 ? '暂无图书下载任务' : _hiddenMessage)
                  : '没有符合条件的任务',
            ),
          );
        }
        final task = tasks[index - 1];
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
            leading: Icon(switch (task.state) {
              AcquisitionState.waiting => Icons.schedule,
              AcquisitionState.resolving => Icons.link,
              AcquisitionState.downloading => Icons.downloading,
              AcquisitionState.paused => Icons.pause_circle_outline,
              AcquisitionState.failed => Icons.error_outline,
              AcquisitionState.downloaded => Icons.file_download_done,
              AcquisitionState.importing => Icons.library_add_outlined,
              AcquisitionState.complete => Icons.task_alt,
            }),
            title: Text(task.edition.title),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${task.candidate.format.label} · $description'),
                if (task.spaceShortfall case final info?)
                  Text(publicationSpaceDetails(info)),
                if (active || task.state == AcquisitionState.importing)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: LinearProgressIndicator(
                      value: active ? progress : null,
                      semanticsLabel: description,
                    ),
                  ),
                _primaryAction(task, active),
              ],
            ),
            children: [
              if (task.received > 0)
                ListTile(
                  title: Text(
                    '${publicationSize(task.received)}${task.total == null ? '' : ' / ${publicationSize(task.total!)}'}',
                  ),
                ),
              for (final failure in task.failures.reversed)
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
              _actions(task),
            ],
          ),
        );
      },
    );
  }

  String get _hiddenMessage => '当前内容策略隐藏了 ${widget.hiddenCount} 个下载任务';

  Widget _filters() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (widget.hiddenCount > 0 && widget.tasks.isNotEmpty)
        Text(_hiddenMessage),
      if (widget.tasks.isNotEmpty)
        Text(
          '正在下载 ${widget.tasks.where((task) => task.state == AcquisitionState.resolving || task.state == AcquisitionState.downloading).length}/2'
          ' · 等待下载 ${widget.tasks.where((task) => task.state == AcquisitionState.waiting && task.problem == null).length}',
        ),
      TextField(
        decoration: const InputDecoration(
          labelText: '搜索下载任务',
          prefixIcon: Icon(Icons.search),
          border: OutlineInputBorder(),
        ),
        onChanged: (query) => setState(() => _query = query.trim()),
      ),
      Wrap(
        spacing: 8,
        children: [
          for (final filter in _TaskFilter.values)
            ChoiceChip(
              label: Text(filter.label),
              selected: _filter == filter,
              onSelected: (_) => setState(() => _filter = filter),
            ),
        ],
      ),
    ],
  );

  Widget _primaryAction(AcquisitionTask task, bool active) {
    final (action, label) = switch (task.state) {
      _ when active => ('pause', '暂停'),
      AcquisitionState.downloaded => ('import', '继续导入'),
      AcquisitionState.importing => ('cancelImport', '取消导入'),
      AcquisitionState.complete => ('open', '打开图书'),
      AcquisitionState.failed ||
      AcquisitionState.paused ||
      AcquisitionState.waiting => (
        'retry',
        requiresPublicationFileChoice(task.candidate)
            ? '选择网盘文件'
            : (task.state == AcquisitionState.failed ? '重试' : '继续下载'),
      ),
      _ => ('', ''),
    };
    if (action.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      children: [
        TextButton(
          onPressed: () => widget.action(task, action),
          child: Text(label),
        ),
        if (widget.websiteAvailable?.call(task) == true)
          TextButton(
            onPressed: () => widget.action(task, 'website'),
            child: const Text('网站操作'),
          ),
        if (widget.browserDownloadAvailable?.call(task) == true) ...[
          TextButton(
            onPressed: () => widget.action(task, 'browserDownload'),
            child: const Text('在浏览器下载'),
          ),
          TextButton(
            onPressed: () => widget.action(task, 'importBrowserDownload'),
            child: const Text('导入已下载文件'),
          ),
        ],
        if (task.state == AcquisitionState.failed &&
            const {
              PublicationProblem.guestLimit,
              PublicationProblem.login,
              PublicationProblem.challenge,
            }.contains(task.problem) &&
            PublicationShareProvider.of(task.candidate.link).listsFiles)
          TextButton(
            onPressed: () => widget.action(task, 'browser'),
            child: const Text('打开网盘'),
          ),
      ],
    );
  }

  String _localTime(DateTime time) =>
      time.toLocal().toString().split('.').first;

  Widget _actions(AcquisitionTask task) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
    child: Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        if (task.state == AcquisitionState.waiting && task.problem == null)
          TextButton(
            onPressed: () => widget.action(task, 'pause'),
            child: const Text('暂停等待任务'),
          ),
        if (task.state == AcquisitionState.downloaded &&
            task.candidate.format == PublicationFormat.zip)
          OutlinedButton(
            onPressed: () => widget.action(task, 'importKeep'),
            child: const Text('导入并保留 ZIP'),
          ),
        if (task.retainedArchive) ...[
          OutlinedButton(
            onPressed: () => widget.action(task, 'readArchive'),
            child: const Text('从原 ZIP 再导入'),
          ),
          TextButton(
            onPressed: () => widget.action(task, 'deleteArchive'),
            child: const Text('删除原 ZIP'),
          ),
        ],
        if (task.state == AcquisitionState.failed &&
            !requiresPublicationFileChoice(task.candidate) &&
            task.failures.any(
              (failure) => failure.problem == PublicationProblem.shareFile,
            ))
          TextButton(
            onPressed: () => widget.action(task, 'chooseFile'),
            child: const Text('选择网盘文件'),
          ),
        if (task.state == AcquisitionState.failed)
          TextButton(
            onPressed: () => widget.action(task, 'replace'),
            child: const Text('更换分享链接'),
          ),
        TextButton(
          onPressed: () => widget.action(task, 'source'),
          child: const Text('来源链接'),
        ),
        if (task.state != AcquisitionState.importing && !task.retainedArchive)
          TextButton(
            onPressed: () => widget.action(task, 'remove'),
            child: const Text('移除任务'),
          ),
      ],
    ),
  );
}
