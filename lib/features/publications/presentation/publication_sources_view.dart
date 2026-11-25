import 'package:flutter/material.dart';

import '../application/publication_discovery.dart';
import '../data/publication_sources.dart';
import 'publication_management_view.dart';

enum _SourceFilter {
  all('全部'),
  enabled('已启用'),
  disabled('已停用'),
  favorites('已收藏'),
  problems('有异常'),
  unchecked('未检查');

  const _SourceFilter(this.label);
  final String label;

  bool matches(PublicationSourceStatus item) => switch (this) {
    all => true,
    enabled => item.enabled,
    disabled => !item.enabled && !item.source.restricted,
    favorites => item.favorite,
    problems => item.problem != null,
    unchecked => item.checked == null && !item.source.restricted,
  };
}

class PublicationSourcesView extends StatefulWidget {
  const PublicationSourcesView({
    super.key,
    required this.sources,
    required this.manageable,
    required this.action,
    required this.toggle,
    required this.batchToggle,
    required this.batchCheck,
    required this.onAdd,
    required this.onQuota,
    required this.onDirectory,
    required this.onClearDirectory,
    required this.usage,
    required this.hasDirectory,
    this.onAccounts,
    this.onGroups,
    this.onBrowse,
  });

  final List<PublicationSourceStatus> sources;
  final bool Function(PublicationSource) manageable;
  final Future<void> Function(PublicationSourceStatus, String) action;
  final Future<void> Function(PublicationSourceStatus, bool) toggle;
  final Future<void> Function(List<PublicationSource>, bool) batchToggle;
  final Future<void> Function(List<PublicationSource>) batchCheck;
  final VoidCallback onAdd, onQuota, onDirectory, onClearDirectory;
  final VoidCallback? onAccounts;
  final VoidCallback? onGroups;
  final ValueChanged<String>? onBrowse;
  final ({int used, int reserved, int limit})? usage;
  final bool hasDirectory;

  @override
  State<PublicationSourcesView> createState() => _PublicationSourcesViewState();
}

class _PublicationSourcesViewState extends State<PublicationSourcesView>
    with AutomaticKeepAliveClientMixin {
  final _selected = <String>{};
  _SourceFilter _filter = _SourceFilter.all;
  String _query = '';
  bool _selecting = false;
  bool _busy = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(covariant PublicationSourcesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final available = {
      for (final item in widget.sources)
        if (widget.manageable(item.source)) item.source.id,
    };
    _selected.retainAll(available);
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _mark(String id, bool checked) => setState(() {
    if (checked) {
      _selected.add(id);
    } else {
      _selected.remove(id);
    }
  });

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final shown = widget.sources
        .where(
          (item) =>
              _filter.matches(item) &&
              '${item.source.name} ${item.source.endpoint.host} '
                      '${item.source.website?.host ?? ''}'
                  .toLowerCase()
                  .contains(_query),
        )
        .toList();
    final selected = [
      for (final item in widget.sources)
        if (_selected.contains(item.source.id) &&
            widget.manageable(item.source))
          item.source,
    ];
    return CustomScrollView(
      key: const PageStorageKey('publication-sources'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          sliver: SliverToBoxAdapter(child: _toolbar(shown, selected)),
        ),
        if (!_selecting)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverToBoxAdapter(child: _storage()),
          ),
        if (shown.isEmpty)
          const SliverToBoxAdapter(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('没有符合条件的书源'),
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          sliver: SliverList.builder(
            itemCount: shown.length,
            itemBuilder: (_, index) => _sourceCard(shown[index]),
          ),
        ),
      ],
    );
  }

  Widget _toolbar(
    List<PublicationSourceStatus> shown,
    List<PublicationSource> selected,
  ) {
    final visibleIds = shown
        .where((item) => widget.manageable(item.source))
        .map((item) => item.source.id)
        .toSet();
    final all = visibleIds.isNotEmpty && visibleIds.every(_selected.contains);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.onAccounts case final accounts?) ...[
          FilledButton.tonalIcon(
            onPressed: _busy ? null : accounts,
            icon: const Icon(Icons.manage_accounts_outlined),
            label: const Text('网站账号管理'),
          ),
          const SizedBox(height: 8),
        ],
        TextField(
          onChanged: (value) =>
              setState(() => _query = value.trim().toLowerCase()),
          decoration: const InputDecoration(
            labelText: '筛选书源名称或域名',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownButton<_SourceFilter>(
              value: _filter,
              items: [
                for (final filter in _SourceFilter.values)
                  DropdownMenuItem(value: filter, child: Text(filter.label)),
              ],
              onChanged: (filter) {
                if (filter != null) setState(() => _filter = filter);
              },
            ),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _selecting = !_selecting;
                      _selected.clear();
                    }),
              icon: Icon(_selecting ? Icons.close : Icons.checklist),
              label: Text(_selecting ? '退出多选' : '多选'),
            ),
            if (!_selecting)
              if (widget.onGroups case final groups?)
                OutlinedButton.icon(
                  onPressed: _busy ? null : groups,
                  icon: const Icon(Icons.folder_outlined),
                  label: const Text('管理渠道分组'),
                ),
            if (!_selecting)
              OutlinedButton.icon(
                onPressed: _busy ? null : widget.onAdd,
                icon: const Icon(Icons.add_link),
                label: const Text('导入书源配置'),
              ),
          ],
        ),
        if (_selecting) ...[
          const SizedBox(height: 6),
          Text('已选 ${selected.length} 个书源'),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              TextButton(
                onPressed: visibleIds.isEmpty || _busy
                    ? null
                    : () => setState(() {
                        if (all) {
                          _selected.removeAll(visibleIds);
                        } else {
                          _selected.addAll(visibleIds);
                        }
                      }),
                child: Text(all ? '取消全选当前结果' : '全选当前结果'),
              ),
              TextButton(
                onPressed: selected.isEmpty || _busy
                    ? null
                    : () => _run(() => widget.batchToggle(selected, true)),
                child: const Text('批量启用'),
              ),
              TextButton(
                onPressed: selected.isEmpty || _busy
                    ? null
                    : () => _run(() => widget.batchToggle(selected, false)),
                child: const Text('批量停用'),
              ),
              TextButton(
                onPressed: selected.isEmpty || _busy
                    ? null
                    : () => _run(() => widget.batchCheck(selected)),
                child: const Text('批量检查'),
              ),
            ],
          ),
        ],
        if (_busy) const LinearProgressIndicator(minHeight: 2),
      ],
    );
  }

  Widget _sourceCard(PublicationSourceStatus item) {
    final source = item.source;
    final manageable = widget.manageable(source);
    final details = [
      source.endpoint.host,
      if (source.license.isNotEmpty) source.license,
      if (source.restricted) '仅保留出处',
      if (item.problem case final problem?)
        [
          if (item.paused) '已暂停检索',
          publicationSourceProblemLabel(problem),
        ].join(' · '),
      if (item.enabled && item.hasSnapshot && item.problem != null)
        '继续使用上次有效目录',
      if (source.websiteOnly) '在原站搜索',
      if (manageable && !source.websiteOnly)
        item.checked == null
            ? '未检查'
            : [
                if (item.problem == null) '可用',
                '检查于 ${_date(item.checked!)}',
              ].join(' · '),
      if (item.synced case final value?) '目录更新于 ${_date(value)}',
    ];
    final subtitle = Text(details.join('\n'));
    return Card(
      key: ValueKey(source.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_selecting)
            CheckboxListTile(
              value: _selected.contains(source.id),
              onChanged: !manageable || _busy
                  ? null
                  : (value) => _mark(source.id, value == true),
              title: Text(source.name),
              subtitle: Text(
                '${item.enabled ? '已启用' : '已停用'} · ${subtitle.data}',
              ),
            )
          else ...[
            SwitchListTile(
              title: Text(source.name),
              value: item.enabled,
              subtitle: subtitle,
              onChanged: !manageable || _busy
                  ? null
                  : (value) => _run(() => widget.toggle(item, value)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Wrap(
                spacing: 6,
                children: [
                  if (manageable && item.enabled && widget.onBrowse != null)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => widget.onBrowse!(source.id),
                      child: const Text('进入渠道'),
                    ),
                  if (manageable)
                    TextButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _run(() => widget.action(item, 'favorite')),
                      icon: Icon(
                        item.favorite ? Icons.star : Icons.star_outline,
                      ),
                      label: Text(item.favorite ? '取消收藏' : '收藏'),
                    ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() => widget.action(item, 'page')),
                    child: const Text('出处'),
                  ),
                  if (manageable && !source.websiteOnly)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() => widget.action(item, 'check')),
                      child: const Text('检查可用性'),
                    ),
                  if (manageable && source.configurable)
                    for (final (action, label) in const [
                      ('edit', '编辑'),
                      ('export', '导出规则'),
                      ('remove', '移除'),
                    ])
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _run(() => widget.action(item, action)),
                        child: Text(label),
                      ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _date(int value) => DateTime.fromMillisecondsSinceEpoch(
    value,
  ).toLocal().toString().split('.').first;

  Widget _storage() => Card(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.sd_storage_outlined),
          title: const Text('托管容量'),
          subtitle: switch (widget.usage) {
            final item? => Text(
              [
                '${publicationSize(item.used)} / ${publicationSize(item.limit)}',
                if (item.reserved > 0)
                  '任务待写入 ${publicationSize(item.reserved)}',
                if (item.used + item.reserved > item.limit)
                  '超出托管上限 ${publicationSize(item.used + item.reserved - item.limit)}',
              ].join(' · '),
            ),
            null => null,
          },
          onTap: widget.onQuota,
        ),
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: const Text('自动保存目录'),
          subtitle: Text(widget.hasDirectory ? '已设置指定目录' : '应用托管'),
          onTap: widget.onDirectory,
          trailing: widget.hasDirectory
              ? IconButton(
                  tooltip: '取消指定目录',
                  onPressed: widget.onClearDirectory,
                  icon: const Icon(Icons.close),
                )
              : null,
        ),
      ],
    ),
  );
}
