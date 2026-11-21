import 'package:flutter/material.dart';

import '../domain/rich_document_access.dart';

Future<RichDocumentNote?> showRichDocumentNotes(
  BuildContext context,
  RichDocumentAccess access,
  int index,
  double fraction,
  String selectedText, {
  required bool pdf,
  required Listenable policy,
}) => showModalBottomSheet<RichDocumentNote>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (context) => ListenableBuilder(
    listenable: policy,
    builder: (_, _) => access.isAllowed()
        ? _Notes(access, index, fraction, selectedText, pdf)
        : const SafeArea(child: ListTile(title: Text('内容策略已变更'))),
  ),
);

class _Notes extends StatefulWidget {
  const _Notes(this.access, this.index, this.fraction, this.excerpt, this.pdf);
  final RichDocumentAccess access;
  final int index;
  final double fraction;
  final String excerpt;
  final bool pdf;
  @override
  State<_Notes> createState() => _NotesState();
}

class _NotesState extends State<_Notes> {
  late Future<List<RichDocumentNote>> _items = widget.access.loadNotes();
  final _text = TextEditingController();
  bool _busy = false;

  Future<void> _change(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) {
        setState(() {
          _items = widget.access.loadNotes();
        });
      }
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法修改书签或笔记')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: FractionallySizedBox(
      heightFactor: .72,
      child: Column(
        children: [
          ListTile(
            title: const Text('书签与笔记'),
            trailing: IconButton(
              tooltip: '关闭',
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          if (widget.excerpt.isNotEmpty)
            ListTile(
              title: Text(
                widget.excerpt,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _text,
              maxLength: 4000,
              maxLines: 2,
              decoration: const InputDecoration(labelText: '笔记'),
            ),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.bookmark_add_outlined),
            label: const Text('记录当前位置'),
            onPressed: _busy
                ? null
                : () => _change(() async {
                    await widget.access.addNote(
                      widget.index,
                      widget.fraction,
                      widget.excerpt,
                      _text.text.trim(),
                    );
                    if (mounted) _text.clear();
                  }),
          ),
          Expanded(
            child: FutureBuilder<List<RichDocumentNote>>(
              future: _items,
              builder: (context, state) {
                if (state.hasError) return const Center(child: Text('无法读取笔记'));
                final items = state.data;
                if (items == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (items.isEmpty) return const Center(child: Text('暂无记录'));
                return ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (_, index) => _noteTile(context, items[index]),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );

  Widget _noteTile(BuildContext context, RichDocumentNote item) {
    if (!widget.access.isAllowed()) {
      return const SizedBox.shrink();
    }
    final location = widget.pdf
        ? '第 ${item.index + 1} 页'
        : '第 ${item.index + 1} 节';
    final body = [
      item.excerpt,
      item.text,
    ].where((text) => text.isNotEmpty).join('\n');
    return ListTile(
      leading: const Icon(Icons.bookmark_outline),
      title: Text(location),
      subtitle: body.isEmpty
          ? null
          : Text(body, maxLines: 3, overflow: TextOverflow.ellipsis),
      onTap: () => Navigator.pop(context, item),
      trailing: IconButton(
        tooltip: '删除此条记录',
        onPressed: _busy
            ? null
            : () => _change(() => widget.access.deleteNote(item.id)),
        icon: const Icon(Icons.delete_outline),
      ),
    );
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }
}
