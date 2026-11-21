import 'package:flutter/material.dart';

class EpubContentsSheet extends StatefulWidget {
  const EpubContentsSheet({
    super.key,
    required this.titles,
    required this.current,
  });

  final List<String> titles;
  final int current;

  @override
  State<EpubContentsSheet> createState() => _EpubContentsSheetState();
}

class _EpubContentsSheetState extends State<EpubContentsSheet> {
  static const _rowHeight = 56.0;
  late final _scroll = ScrollController(
    initialScrollOffset: widget.current * _rowHeight,
  );
  String _query = '';
  bool _reverse = false;

  void _jump(double pixels) {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(pixels.clamp(0.0, _scroll.position.maxScrollExtent));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matches = widget.titles.indexed
        .where((entry) => entry.$2.toLowerCase().contains(_query))
        .toList();
    final visible = _reverse ? matches.reversed.toList() : matches;
    return FractionallySizedBox(
      heightFactor: .74,
      child: SafeArea(
        child: Column(
          children: [
            ListTile(
              title: const Text('章节目录'),
              subtitle: Text('共 ${visible.length} 节'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '目录回顶',
                    icon: const Icon(Icons.vertical_align_top),
                    onPressed: () => _jump(0),
                  ),
                  IconButton(
                    tooltip: '定位当前章节',
                    icon: const Icon(Icons.my_location),
                    onPressed: () {
                      final current = visible.indexWhere(
                        (entry) => entry.$1 == widget.current,
                      );
                      if (current >= 0) _jump(current * _rowHeight);
                    },
                  ),
                  IconButton(
                    tooltip: '倒序',
                    icon: const Icon(Icons.sort),
                    isSelected: _reverse,
                    onPressed: () {
                      _jump(0);
                      setState(() => _reverse = !_reverse);
                    },
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                decoration: const InputDecoration(
                  labelText: '搜索章节',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (value) {
                  _jump(0);
                  setState(() => _query = value.trim().toLowerCase());
                },
              ),
            ),
            Expanded(
              child: visible.isEmpty
                  ? const Center(child: Text('没有匹配的章节'))
                  : ListView.builder(
                      controller: _scroll,
                      itemExtent: _rowHeight,
                      itemCount: visible.length,
                      itemBuilder: (context, position) {
                        final (index, title) = visible[position];
                        return ListTile(
                          selected: index == widget.current,
                          title: Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => Navigator.pop(context, index),
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
