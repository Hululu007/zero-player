import 'package:flutter/material.dart';

import '../application/publication_discovery.dart';
import 'publication_dialogs.dart';

typedef PublicationChannelGroups = Map<String, Set<String>>;
typedef PublicationSearchScope = ({
  String? channel,
  String? group,
  bool favorites,
});

const allPublicationChannels = (channel: null, group: null, favorites: false);
const publicationChannelGroupsPreference = 'publication.channelGroups';

Future<PublicationSearchScope?> pickPublicationChannels(
  BuildContext context,
  List<PublicationSourceStatus> channels,
  PublicationChannelGroups groups,
  PublicationSearchScope current,
  Future<void> Function(PublicationSourceStatus, bool) setFavorite,
) => showDialog<PublicationSearchScope>(
  context: context,
  builder: (context) => _ChannelPicker(channels, groups, current, setFavorite),
);

class _ChannelPicker extends StatefulWidget {
  const _ChannelPicker(
    this.channels,
    this.groups,
    this.current,
    this.setFavorite,
  );

  final List<PublicationSourceStatus> channels;
  final PublicationChannelGroups groups;
  final PublicationSearchScope current;
  final Future<void> Function(PublicationSourceStatus, bool) setFavorite;

  @override
  State<_ChannelPicker> createState() => _ChannelPickerState();
}

class _ChannelPickerState extends State<_ChannelPicker> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _favorites = <String, bool>{};
  bool _saving = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _input.text.trim().toLowerCase();
    final current = widget.current;
    final groups =
        widget.groups.entries
            .where((group) => group.key.toLowerCase().contains(query))
            .toList()
          ..sort((a, b) => _groupRank(a).compareTo(_groupRank(b)));
    final channels =
        widget.channels.where((item) => _matches(item, query)).toList()
          ..sort((a, b) => _rank(a).compareTo(_rank(b)));
    void select(PublicationSearchScope scope) => Navigator.pop(context, scope);
    return AlertDialog(
      title: const Text('选择检索渠道'),
      content: SizedBox(
        width: 440,
        height: 440,
        child: Column(
          children: [
            TextField(
              controller: _input,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: '搜索渠道、分组或域名',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  tooltip: '定位到当前',
                  icon: const Icon(Icons.my_location),
                  onPressed: () {
                    setState(_input.clear);
                    if (_scroll.hasClients) _scroll.jumpTo(0);
                  },
                ),
              ),
            ),
            Expanded(
              child: ListView(
                controller: _scroll,
                children: [
                  for (final item in channels)
                    if (item.source.id == current.channel)
                      _channel(item, select, true),
                  if ('全部渠道'.contains(query))
                    ListTile(
                      title: const Text('全部渠道'),
                      selected: current == allPublicationChannels,
                      onTap: () => select(allPublicationChannels),
                    ),
                  if ('收藏渠道'.contains(query))
                    ListTile(
                      leading: const Icon(Icons.star_outline),
                      title: const Text('收藏渠道'),
                      selected: current.favorites,
                      onTap: () =>
                          select((channel: null, group: null, favorites: true)),
                    ),
                  for (final group in groups)
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(group.key),
                      subtitle: Text(
                        '${widget.channels.where((item) => group.value.contains(item.source.id)).length} 个已启用渠道',
                      ),
                      selected: current.group == group.key,
                      onTap: () => select((
                        channel: null,
                        group: group.key,
                        favorites: false,
                      )),
                    ),
                  for (final item in channels)
                    if (item.source.id != current.channel)
                      _channel(item, select, false),
                  if (channels.isEmpty &&
                      groups.isEmpty &&
                      !'全部渠道'.contains(query) &&
                      !'收藏渠道'.contains(query))
                    const ListTile(title: Text('没有匹配的渠道或分组')),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  int _groupRank(MapEntry<String, Set<String>> group) =>
      group.key == widget.current.group ||
          group.value.contains(widget.current.channel)
      ? 0
      : 1;

  int _rank(PublicationSourceStatus item) => _favorite(item)
      ? 0
      : widget.groups.values.any(
          (ids) =>
              ids.contains(widget.current.channel) &&
              ids.contains(item.source.id),
        )
      ? 1
      : 2;

  bool _matches(PublicationSourceStatus item, String query) =>
      '${item.source.name} ${item.source.endpoint.host} ${item.source.website?.host ?? ''}'
          .toLowerCase()
          .contains(query);

  bool _favorite(PublicationSourceStatus item) =>
      _favorites[item.source.id] ?? item.favorite;

  Future<void> _toggleFavorite(PublicationSourceStatus item) async {
    final favorite = !_favorite(item);
    setState(() => _saving = true);
    try {
      await widget.setFavorite(item, favorite);
      if (mounted) setState(() => _favorites[item.source.id] = favorite);
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法保存渠道收藏')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _channel(
    PublicationSourceStatus item,
    ValueChanged<PublicationSearchScope> select,
    bool current,
  ) => ListTile(
    title: Text(item.source.name),
    subtitle: current ? const Text('当前渠道') : null,
    selected: current,
    trailing: IconButton(
      tooltip: _favorite(item)
          ? '取消收藏 ${item.source.name}'
          : '收藏 ${item.source.name}',
      onPressed: _saving ? null : () => _toggleFavorite(item),
      icon: Icon(_favorite(item) ? Icons.star : Icons.star_outline),
    ),
    onTap: () =>
        select((channel: item.source.id, group: null, favorites: false)),
  );
}

Future<PublicationChannelGroups?> managePublicationChannelGroups(
  BuildContext context,
  PublicationChannelGroups groups,
  List<PublicationSourceStatus> channels,
) => showDialog<PublicationChannelGroups>(
  context: context,
  builder: (context) => _ChannelGroupsDialog(groups, channels),
);

class _ChannelGroupsDialog extends StatefulWidget {
  const _ChannelGroupsDialog(this.groups, this.channels);
  final PublicationChannelGroups groups;
  final List<PublicationSourceStatus> channels;

  @override
  State<_ChannelGroupsDialog> createState() => _ChannelGroupsDialogState();
}

class _ChannelGroupsDialogState extends State<_ChannelGroupsDialog> {
  late final _groups = {
    for (final group in widget.groups.entries) group.key: {...group.value},
  };
  String? _selected;
  String _query = '';

  Future<void> _name({String? previous}) async {
    final name = (await publicationPrompt(
      context,
      previous == null ? '新建渠道分组' : '重命名渠道分组',
      limit: 40,
    ))?.trim();
    if (!mounted || name == null || name.isEmpty || name == previous) return;
    if (_groups.containsKey(name)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已有同名分组')));
      return;
    }
    setState(() {
      _groups[name] = _groups.remove(previous) ?? {};
      _selected = name;
    });
  }

  @override
  Widget build(BuildContext context) {
    final name = _selected;
    final selected = _groups[name];
    return AlertDialog(
      title: const Text('管理渠道分组'),
      content: SizedBox(
        width: 460,
        height: 420,
        child: Column(
          children: [
            Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (_groups.isNotEmpty)
                  DropdownButton<String>(
                    hint: const Text('选择分组'),
                    value: name,
                    isExpanded: true,
                    items: [
                      for (final group in _groups.keys)
                        DropdownMenuItem(
                          value: group,
                          child: Text(group, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (value) => setState(() => _selected = value),
                  ),
                TextButton(onPressed: () => _name(), child: const Text('新建分组')),
                if (name != null) ...[
                  TextButton(
                    onPressed: () => _name(previous: name),
                    child: const Text('重命名'),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      _groups.remove(name);
                      _selected = null;
                    }),
                    child: const Text('删除分组'),
                  ),
                ],
              ],
            ),
            if (selected != null) ...[
              TextField(
                decoration: const InputDecoration(labelText: '筛选渠道'),
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final item in widget.channels)
                      if (item.source.name.toLowerCase().contains(_query))
                        CheckboxListTile(
                          title: Text(item.source.name),
                          value: selected.contains(item.source.id),
                          onChanged: (checked) => setState(() {
                            if (checked == true) {
                              selected.add(item.source.id);
                            } else {
                              selected.remove(item.source.id);
                            }
                          }),
                        ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _groups),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
