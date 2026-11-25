import 'package:flutter/material.dart';

import '../data/cloud_resource_catalog.dart';
import '../data/cloud_shared_catalogs.dart';
import '../data/publication_share_provider.dart';

typedef _VisibleRow = ({CloudResourceEntry entry, int depth});

final class CloudResourceCatalogView extends StatefulWidget {
  const CloudResourceCatalogView({
    super.key,
    required this.catalog,
    required this.allowed,
    required this.open,
    required this.parse,
    this.onRetry,
    this.onRefresh,
    this.updates = const {},
    this.refreshing = const {},
    this.errors = const {},
  });

  final Future<CloudResourceCatalog> catalog;
  final bool Function(String) allowed;
  final void Function(Uri, String) open;
  final void Function(Uri, String?) parse;
  final VoidCallback? onRetry;
  final ValueChanged<String>? onRefresh;
  final Map<String, CloudResourceEntry> updates;
  final Set<String> refreshing;
  final Map<String, String> errors;

  @override
  State<CloudResourceCatalogView> createState() =>
      _CloudResourceCatalogViewState();
}

final class _CloudResourceCatalogViewState
    extends State<CloudResourceCatalogView> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _expanded = <CloudResourceEntry, String>{};
  int _category = 0;
  String _query = '';

  @override
  void didUpdateWidget(covariant CloudResourceCatalogView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.catalog != widget.catalog) {
      _expanded.clear();
    } else {
      for (final entry in widget.updates.entries) {
        if (oldWidget.updates[entry.key] != entry.value) {
          // Expanded rows belong to the tree version that supplied them.
          _expanded.removeWhere((_, owner) => owner == entry.key);
        }
      }
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Iterable<_VisibleRow> _visible(
    List<CloudResourceEntry> rows, {
    int depth = 0,
    bool parentMatches = false,
  }) sync* {
    for (final entry in rows) {
      final link = entry.link;
      if (!widget.allowed('${entry.name} ${link?.host ?? ''}')) continue;
      final matches =
          parentMatches ||
          entry.name.toLowerCase().contains(_query) ||
          (link?.toString().toLowerCase().contains(_query) ?? false);
      if (link != null) {
        if (matches) yield (entry: entry, depth: depth);
        continue;
      }
      final expand = _query.isNotEmpty || _expanded.containsKey(entry);
      if (!expand) {
        yield (entry: entry, depth: depth);
        continue;
      }
      final children = _visible(
        entry.rows,
        depth: depth + 1,
        parentMatches: matches,
      ).toList();
      if (_query.isEmpty || matches || children.isNotEmpty) {
        yield (entry: entry, depth: depth);
        yield* children;
      }
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<CloudResourceCatalog>(
    future: widget.catalog,
    builder: (context, snapshot) {
      final catalog = snapshot.data;
      if (snapshot.hasError &&
          snapshot.connectionState == ConnectionState.done) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('无法加载内置资源库'),
              if (widget.onRetry case final retry?)
                TextButton(onPressed: retry, child: const Text('重试')),
            ],
          ),
        );
      }
      if (catalog == null) {
        return const Center(child: CircularProgressIndicator());
      }
      final original =
          catalog.categories[_category.clamp(0, catalog.categories.length - 1)];
      final category = widget.updates[original.name] ?? original;
      final rows = _visible(
        category.rows,
        parentMatches: category.name.toLowerCase().contains(_query),
      ).toList();
      return ListView.builder(
        controller: _controller(context),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        itemCount: rows.length + 1,
        itemBuilder: (context, index) => index == 0
            ? _controls(catalog, category, rows.isEmpty)
            : _tile(rows[index - 1], category.name),
      );
    },
  );

  ScrollController _controller(BuildContext context) =>
      PrimaryScrollController.maybeOf(context) ?? _scroll;

  Widget _controls(
    CloudResourceCatalog catalog,
    CloudResourceEntry category,
    bool empty,
  ) {
    final name = category.name;
    final canRefresh = name == '导航森林' || CloudSharedCatalog.named(name) != null;
    final refreshing = widget.refreshing.contains(name);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            labelText: '在分类中搜索资源',
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    tooltip: '清空搜索',
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _search.clear();
                      setState(() => _query = '');
                    },
                  ),
          ),
          onChanged: (value) =>
              setState(() => _query = value.trim().toLowerCase()),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (var i = 0; i < catalog.categories.length; i++)
              ChoiceChip(
                label: Text(catalog.categories[i].name),
                selected: i == _category,
                onSelected: (_) {
                  if (i == _category) return;
                  final scroll = _controller(context);
                  if (scroll.hasClients) scroll.jumpTo(0);
                  setState(() => _category = i);
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            if (canRefresh && widget.onRefresh != null)
              TextButton.icon(
                onPressed: refreshing ? null : () => widget.onRefresh!(name),
                icon: refreshing
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                label: Text(refreshing ? '正在同步' : '同步更新'),
              ),
            if (category.link case final link?)
              TextButton.icon(
                onPressed: () => widget.open(link, category.name),
                icon: const Icon(Icons.open_in_new),
                label: Text('打开原文 · ${category.name}'),
              ),
            TextButton(
              onPressed: () => widget.open(catalog.source, '资源库'),
              child: const Text('飞书汇总页'),
            ),
          ],
        ),
        if (category.updated case final updated?)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              '${category.rows.length} 条资源 · 上次同步 ${updated.toLocal().toString().substring(0, 16)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (canRefresh &&
            category.rows.isEmpty &&
            !refreshing &&
            widget.errors[name] == null &&
            _query.isEmpty)
          const Text('暂无本地缓存，可同步更新。'),
        if (widget.errors[name] case final error?)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              category.rows.isEmpty
                  ? '更新失败 · $error'
                  : '更新失败，继续显示上次目录 · $error',
            ),
          ),
        if (empty && _query.isNotEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('此分类没有匹配的资源'),
          ),
      ],
    );
  }

  Widget _tile(_VisibleRow row, String category) {
    final (entry: entry, depth: depth) = row;
    final link = entry.link;
    final inset = EdgeInsets.only(left: depth * 16.0, right: 4);
    if (link == null) {
      final open = _query.isNotEmpty || _expanded.containsKey(entry);
      return ListTile(
        contentPadding: inset,
        leading: Icon(open ? Icons.expand_more : Icons.chevron_right),
        title: Text(entry.name),
        onTap: _query.isNotEmpty
            ? null
            : () => setState(() {
                if (_expanded.remove(entry) == null) {
                  _expanded[entry] = category;
                }
              }),
      );
    }
    final provider = PublicationShareProvider.of(link);
    return ListTile(
      contentPadding: inset,
      title: Text(entry.name),
      subtitle: Text('${link.host}${entry.code == null ? '' : ' · 含提取码'}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (provider.previewsFiles)
            IconButton(
              tooltip: '解析分享',
              icon: Icon(
                provider.listsFiles
                    ? Icons.cloud_download_outlined
                    : Icons.folder_open_outlined,
              ),
              onPressed: () => widget.parse(link, entry.code),
            ),
          IconButton(
            tooltip: '打开原始链接',
            icon: const Icon(Icons.open_in_new),
            onPressed: () => widget.open(link, entry.name),
          ),
        ],
      ),
      onTap: provider.previewsFiles
          ? () => widget.parse(link, entry.code)
          : () => widget.open(link, entry.name),
    );
  }
}
