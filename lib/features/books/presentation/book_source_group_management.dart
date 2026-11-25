part of 'book_sources_page.dart';

enum _GroupAction { select, create, rename, remove, members, enable, disable }

typedef _GroupChoice = ({_GroupAction action, BookSourceGroup? group});

extension _BookSourceGroupManagement on _BookSourcesPageState {
  BookSourceGroup? get _group => _groups
      .where(
        (group) =>
            group.id == _groupId &&
            _services.contentPolicy.textAllowed(group.name),
      )
      .firstOrNull;

  Future<void> _manageGroups() async {
    final choice = await showDialog<_GroupChoice>(
      context: context,
      builder: (dialog) => ListenableBuilder(
        listenable: _services.contentPolicy,
        builder: (context, _) {
          final groups = _groups
              .where((group) => _services.contentPolicy.textAllowed(group.name))
              .toList();
          void finish(_GroupAction action, [BookSourceGroup? group]) =>
              Navigator.pop(dialog, (action: action, group: group));
          return AlertDialog(
            title: const Text('渠道分组'),
            content: SizedBox(
              width: 520,
              height: MediaQuery.sizeOf(context).height * .45,
              child: ListView(
                children: [
                  ListTile(
                    title: const Text('全部渠道'),
                    selected: _groupId == null,
                    onTap: () => finish(_GroupAction.select),
                  ),
                  for (final group in groups)
                    ListTile(
                      title: Text(group.name),
                      subtitle: Text(
                        '${_entries.where((entry) => group.sourceIds.contains(entry.source.id)).length} 个渠道',
                      ),
                      selected: _groupId == group.id,
                      onTap: () => finish(_GroupAction.select, group),
                      trailing: PopupMenuButton<_GroupAction>(
                        tooltip: '分组操作',
                        onSelected: (action) => finish(action, group),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: _GroupAction.members,
                            child: Text('编辑成员'),
                          ),
                          PopupMenuItem(
                            value: _GroupAction.enable,
                            child: Text('启用整组'),
                          ),
                          PopupMenuItem(
                            value: _GroupAction.disable,
                            child: Text('停用整组'),
                          ),
                          PopupMenuItem(
                            value: _GroupAction.rename,
                            child: Text('重命名'),
                          ),
                          PopupMenuItem(
                            value: _GroupAction.remove,
                            child: Text('删除分组'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('关闭'),
              ),
              FilledButton(
                onPressed: () => finish(_GroupAction.create),
                child: const Text('新建分组'),
              ),
            ],
          );
        },
      ),
    );
    if (!mounted || choice == null) return;
    await _applyGroupChoice(choice);
  }

  Future<void> _applyGroupChoice(_GroupChoice choice) async {
    final (action: action, group: group) = choice;
    if (group != null && !_services.contentPolicy.textAllowed(group.name)) {
      return;
    }
    switch (action) {
      case _GroupAction.select:
        setStateIfMounted(() => _groupId = group?.id);
      case _GroupAction.create:
      case _GroupAction.rename:
        final name = await _prompt(
          '分组名称',
          initial: group?.name ?? '',
          limit: 60,
        );
        if (!mounted || name == null) return;
        await _run(() async {
          if (!_services.contentPolicy.textAllowed(name)) {
            throw const FormatException('分组名称受当前内容策略限制');
          }
          await _groupStore.save(name, id: group?.id);
        }, protected: true);
      case _GroupAction.remove:
        await _run(() async {
          await _groupStore.remove(group!.id);
          if (_groupId == group.id) setStateIfMounted(() => _groupId = null);
        }, protected: true);
      case _GroupAction.members:
        await _editGroupMembers(group!);
      case _GroupAction.enable:
      case _GroupAction.disable:
        try {
          final current = (await _groupStore.load())
              .where((item) => item.id == group!.id)
              .firstOrNull;
          if (!mounted || current == null) return;
          if (current.sourceIds.isNotEmpty &&
              _services.contentPolicy.textAllowed(current.name)) {
            await _setEnabled(current.sourceIds, action == _GroupAction.enable);
          }
        } on Exception {
          _notice('无法读取渠道分组，请重试');
        }
    }
  }

  Future<void> _editGroupMembers(BookSourceGroup group) async {
    final selected = await showDialog<Set<String>>(
      context: context,
      builder: (_) => _BookGroupMembersDialog(
        group: group,
        repository: _services.books,
        entries: () => _entries,
      ),
    );
    if (!mounted || selected == null) return;
    await _run(() async {
      final visible = (await _services.books.sources(
        widget.kind,
      )).map((entry) => entry.source.id).toSet();
      await _groupStore.updateMembers(
        group.id,
        add: selected.difference(group.sourceIds).intersection(visible),
        remove: group.sourceIds.difference(selected).intersection(visible),
      );
    }, protected: true);
  }

  Future<void> _addToGroup(Set<String> sourceIds) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: _services.contentPolicy,
        builder: (context, _) {
          final groups = _groups.where(
            (group) => _services.contentPolicy.textAllowed(group.name),
          );
          return SimpleDialog(
            title: const Text('添加到分组'),
            children: [
              if (groups.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('请先在渠道分组中新建分组'),
                ),
              for (final group in groups)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, group.id),
                  child: Text(group.name),
                ),
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
            ],
          );
        },
      ),
    );
    if (!mounted || selected == null) return;
    await _run(() async {
      final group = (await _groupStore.load())
          .where((group) => group.id == selected)
          .firstOrNull;
      if (group == null || !_services.contentPolicy.textAllowed(group.name)) {
        throw const FormatException('渠道分组已不可用');
      }
      final entries = await _services.books.sources(widget.kind);
      final eligible = {
        for (final entry in entries)
          if (sourceIds.contains(entry.source.id) &&
              _services.books.sourceEntryAllowed(entry))
            entry.source.id,
      };
      if (eligible.isEmpty) throw const FormatException('所选渠道已不可用');
      await _groupStore.updateMembers(
        group.id,
        add: eligible,
        remove: const {},
      );
      _notice('已将 ${eligible.length} 个渠道添加到 ${group.name}');
    }, protected: true);
  }
}

final class _BookGroupMembersDialog extends StatefulWidget {
  const _BookGroupMembersDialog({
    required this.group,
    required this.repository,
    required this.entries,
  });

  final BookSourceGroup group;
  final BooksRepository repository;
  final List<BookSourceEntry> Function() entries;

  @override
  State<_BookGroupMembersDialog> createState() =>
      _BookGroupMembersDialogState();
}

final class _BookGroupMembersDialogState
    extends State<_BookGroupMembersDialog> {
  late final _selected = Set<String>.of(widget.group.sourceIds);
  String _query = '';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.repository.policy,
      widget.repository.sourceRiskChanges,
    ]),
    builder: (context, _) {
      final allowed = widget.repository.policy.textAllowed(widget.group.name);
      final sources = allowed
          ? widget
                .entries()
                .where(widget.repository.sourceEntryAllowed)
                .map((entry) => entry.source)
                .where(
                  (source) => '${source.name} ${source.endpoint.host}'
                      .toLowerCase()
                      .contains(_query),
                )
                .toList()
          : <BookSource>[];
      return AlertDialog(
        title: Text(allowed ? '编辑 ${widget.group.name} 的成员' : '编辑分组成员'),
        content: SizedBox(
          width: 520,
          height: MediaQuery.sizeOf(context).height * .48,
          child: Column(
            children: [
              TextField(
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
                decoration: const InputDecoration(hintText: '筛选名称或域名'),
              ),
              Wrap(
                children: [
                  TextButton(
                    onPressed: sources.isEmpty
                        ? null
                        : () => setState(
                            () => _selected.addAll(
                              sources.map((item) => item.id),
                            ),
                          ),
                    child: const Text('全选筛选结果'),
                  ),
                  TextButton(
                    onPressed: sources.isEmpty
                        ? null
                        : () => setState(
                            () => _selected.removeAll(
                              sources.map((item) => item.id),
                            ),
                          ),
                    child: const Text('取消筛选结果'),
                  ),
                ],
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: sources.length,
                  itemBuilder: (_, index) {
                    final source = sources[index];
                    return CheckboxListTile(
                      title: Text(source.name),
                      subtitle: Text(source.endpoint.host),
                      value: _selected.contains(source.id),
                      onChanged: (value) => setState(() {
                        if (value == true) {
                          _selected.add(source.id);
                        } else {
                          _selected.remove(source.id);
                        }
                      }),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: allowed ? () => Navigator.pop(context, _selected) : null,
            child: const Text('保存成员'),
          ),
        ],
      );
    },
  );
}
