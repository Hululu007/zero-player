part of 'book_discovery_view.dart';

final class _ChannelPicker extends StatefulWidget {
  const _ChannelPicker({required this.entries, required this.selected});
  final List<BookSourceEntry> entries;
  final String? selected;

  @override
  State<_ChannelPicker> createState() => _ChannelPickerState();
}

final class _ChannelPickerState extends State<_ChannelPicker> {
  String _query = '';
  static const _rowHeight = 72.0;
  late final _scroll = ScrollController(
    initialScrollOffset: _selectedOffset(widget.entries),
  );

  double _selectedOffset(List<BookSourceEntry> entries) {
    final index = entries.indexWhere(
      (entry) => entry.source.id == widget.selected,
    );
    return index < 0 ? 0 : index * _rowHeight;
  }

  void _jump(double offset) {
    if (_scroll.hasClients) {
      _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sources = widget.entries
        .where(
          (entry) =>
              '${entry.source.name} ${entry.source.endpoint.host} ${entry.group}'
                  .toLowerCase()
                  .contains(_query),
        )
        .toList();
    return AlertDialog(
      title: const Text('选择渠道'),
      content: SizedBox(
        width: 480,
        height: MediaQuery.sizeOf(context).height * .49,
        child: Column(
          children: [
            TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '筛选渠道',
              ),
              onChanged: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
            ),
            if (_query.isEmpty)
              ListTile(
                leading: const Icon(Icons.hub_outlined),
                selected: widget.selected == null,
                title: const Text('回到推荐与聚合'),
                onTap: () => Navigator.pop(context, (id: null as String?)),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: '定位当前渠道',
                  onPressed: widget.selected == null
                      ? null
                      : () => _jump(_selectedOffset(sources)),
                  icon: const Icon(Icons.my_location),
                ),
                IconButton(
                  tooltip: '返回顶部',
                  onPressed: () => _jump(0),
                  icon: const Icon(Icons.vertical_align_top),
                ),
              ],
            ),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                itemExtent: _rowHeight,
                itemCount: sources.length,
                itemBuilder: (context, index) {
                  final entry = sources[index];
                  final source = entry.source;
                  return ListTile(
                    selected: widget.selected == source.id,
                    leading: Icon(
                      entry.favorite ? Icons.star : Icons.auto_stories_outlined,
                    ),
                    title: Text(
                      source.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${source.endpoint.host}${source.hasDiscovery ? '' : ' · 需搜索或输入链接'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () =>
                        Navigator.pop(context, (id: source.id as String?)),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
