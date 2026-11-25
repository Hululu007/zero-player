import 'package:flutter/material.dart';

import '../data/publication_panda_directory.dart';

Future<PublicationPandaEntry?> showPublicationPandaDirectory(
  BuildContext context, {
  required Set<String> enabled,
  required bool Function(PublicationPandaEntry) allowed,
}) => showDialog<PublicationPandaEntry>(
  context: context,
  builder: (context) => _PandaDialog(enabled: enabled, allowed: allowed),
);

class _PandaDialog extends StatefulWidget {
  const _PandaDialog({required this.enabled, required this.allowed});
  final Set<String> enabled;
  final bool Function(PublicationPandaEntry) allowed;

  @override
  State<_PandaDialog> createState() => _PandaDialogState();
}

class _PandaDialogState extends State<_PandaDialog> {
  late final _directory = loadPublicationPandaDirectory();
  String _group = '', _query = '';

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('熊猫书源'),
    scrollable: false,
    content: SizedBox(
      width: 560,
      height: MediaQuery.sizeOf(context).height * 0.53,
      child: FutureBuilder(
        future: _directory,
        builder: (context, snapshot) {
          if (snapshot.hasError) return const Center(child: Text('无法加载书源目录'));
          final directory = snapshot.data;
          if (directory == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return _content(directory);
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );

  Widget _content(PublicationPandaDirectory directory) {
    final results = [
      for (final group in directory.groups)
        if (_group.isEmpty || _group == group.id)
          for (final entry in group.entries)
            if (widget.allowed(entry) &&
                '${entry.name} ${entry.host}'.toLowerCase().contains(_query))
              (entry: entry, group: group.name),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          decoration: const InputDecoration(
            labelText: '搜索站名或域名',
            prefixIcon: Icon(Icons.search),
            isDense: true,
          ),
          onChanged: (value) =>
              setState(() => _query = value.trim().toLowerCase()),
        ),
        Row(
          children: [
            Expanded(
              child: DropdownButton<String>(
                isExpanded: true,
                value: _group,
                items: [
                  const DropdownMenuItem(value: '', child: Text('所有分类')),
                  for (final group in directory.groups)
                    DropdownMenuItem(
                      value: group.id,
                      child: Text(group.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (group) => setState(() => _group = group ?? ''),
              ),
            ),
            const SizedBox(width: 12),
            Text('${results.length} 个条目'),
          ],
        ),
        Text(
          '核查于 ${directory.reviewed}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const Divider(),
        Expanded(
          child: results.isEmpty
              ? const Center(child: Text('没有符合条件的站点'))
              : ListView.builder(
                  itemCount: results.length,
                  itemBuilder: (context, index) =>
                      _row(results[index].entry, results[index].group),
                ),
        ),
      ],
    );
  }

  Widget _row(PublicationPandaEntry entry, String group) {
    final inApp =
        entry.sourceId != null && widget.enabled.contains(entry.sourceId);
    final canOpen = inApp || entry.website != null;
    final status = entry.sourceId != null && !inApp
        ? '应用内书源已停用'
        : entry.status.label;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (entry.host.isNotEmpty) entry.host,
          if (_group.isEmpty) group,
          status,
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: canOpen
          ? Tooltip(
              message: inApp ? '在应用搜索' : '打开原站',
              child: Icon(inApp ? Icons.search : Icons.open_in_new),
            )
          : null,
      onTap: canOpen
          ? () {
              if (widget.allowed(entry)) Navigator.pop(context, entry);
            }
          : null,
    );
  }
}
