import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/book_shelf_lists.dart';
import '../domain/book_download_plan.dart';
export '../domain/book_download_plan.dart';

enum BookShelfSpace { public, private }

final class BookDownloadTarget {
  const BookDownloadTarget(this.space, {this.listId, this.listName});
  final BookShelfSpace space;
  final String? listId;
  final String? listName;

  bool get isPrivate => space == BookShelfSpace.private;
}

final class BookDownloadSelection {
  const BookDownloadSelection(this.plan, this.target);
  final BookDownloadPlan plan;
  final BookDownloadTarget target;
}

Future<BookDownloadSelection?> showBookDownloadDialog(
  BuildContext context,
  int total, {
  bool allowAggregateLatest = true,
  List<ShelfList> publicLists = const [],
  List<ShelfList> privateLists = const [],
  BookShelfSpace initialSpace = BookShelfSpace.public,
  Future<List<ShelfList>?> Function()? loadPrivateLists,
}) => showDialog<BookDownloadSelection>(
  context: context,
  builder: (_) => _BookDownloadDialog(
    total: total,
    allowAggregateLatest: allowAggregateLatest,
    publicLists: publicLists,
    privateLists: privateLists,
    initialSpace: initialSpace,
    loadPrivateLists: loadPrivateLists,
  ),
);

final class _BookDownloadDialog extends StatefulWidget {
  const _BookDownloadDialog({
    required this.total,
    required this.allowAggregateLatest,
    required this.publicLists,
    required this.privateLists,
    required this.initialSpace,
    required this.loadPrivateLists,
  });
  final int total;
  final bool allowAggregateLatest;
  final List<ShelfList> publicLists, privateLists;
  final BookShelfSpace initialSpace;
  final Future<List<ShelfList>?> Function()? loadPrivateLists;
  @override
  State<_BookDownloadDialog> createState() => _BookDownloadDialogState();
}

final class _BookDownloadDialogState extends State<_BookDownloadDialog> {
  int _first = 1;
  late int _last = widget.total;
  bool _all = true,
      _fallback = false,
      _aggregateLatest = false,
      _selecting = false;
  late BookShelfSpace _space = widget.initialSpace;
  late List<ShelfList> _privateLists = widget.privateLists;
  String? _listId, _error;
  List<ShelfList> get _available =>
      _space == BookShelfSpace.private ? _privateLists : widget.publicLists;

  Future<void> _switchSpace(Set<BookShelfSpace> values) async {
    final next = values.single;
    if (next == _space || _selecting) return;
    if (next == BookShelfSpace.private && widget.loadPrivateLists != null) {
      setState(() {
        _selecting = true;
        _error = null;
      });
      try {
        final loaded = await widget.loadPrivateLists!();
        if (!mounted || loaded == null) return;
        _privateLists = loaded;
      } on Exception {
        if (mounted) setState(() => _error = '无法读取私密书单，请重试');
        return;
      } finally {
        if (mounted) setState(() => _selecting = false);
      }
    }
    if (mounted) {
      setState(() {
        _space = next;
        _listId = null;
      });
    }
  }

  void _submit() => Navigator.pop(
    context,
    BookDownloadSelection(
      BookDownloadPlan(
        _all ? 1 : _first,
        _all ? widget.total : _last,
        _fallback,
        fullBook: _all,
        aggregateLatest:
            _all && widget.allowAggregateLatest && _aggregateLatest,
      ),
      BookDownloadTarget(
        _space,
        listId: _listId,
        listName: _available
            .where((list) => list.id == _listId)
            .firstOrNull
            ?.name,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('离线下载'),
    scrollable: true,
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _range(),
          if (_all && widget.allowAggregateLatest)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('聚合最新'),
              subtitle: const Text('自动从同名同作者的其他渠道补充后续章节'),
              value: _aggregateLatest,
              onChanged: (value) => setState(() => _aggregateLatest = value),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('失败时尝试其他书源'),
            subtitle: const Text('只下载同名同作者且章节唯一对应的版本'),
            value: _fallback,
            onChanged: (value) => setState(() => _fallback = value),
          ),
          const Divider(),
          _destination(),
          if (_error != null) Text(_error!),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed:
            !_selecting &&
                (_all ||
                    _first >= 1 && _last >= _first && _last <= widget.total)
            ? _submit
            : null,
        child: const Text('开始下载'),
      ),
    ],
  );

  Widget _range() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: true, label: Text('全本')),
          ButtonSegment(value: false, label: Text('指定区间')),
        ],
        selected: {_all},
        onSelectionChanged: (values) => setState(() => _all = values.single),
      ),
      const SizedBox(height: 12),
      if (!_all)
        Row(
          children: [
            Expanded(
              child: _chapterNumber(
                '起始章节',
                _first,
                (value) => setState(() => _first = value),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _chapterNumber(
                '结束章节',
                _last,
                (value) => setState(() => _last = value),
              ),
            ),
          ],
        ),
      Text('共 ${widget.total} 章，自动跳过已下载章节'),
    ],
  );

  Widget _destination() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('保存到', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 6),
      SegmentedButton<BookShelfSpace>(
        segments: const [
          ButtonSegment(
            value: BookShelfSpace.public,
            icon: Icon(Icons.collections_bookmark_outlined),
            label: Text('书架'),
          ),
          ButtonSegment(
            value: BookShelfSpace.private,
            icon: Icon(Icons.lock_outline),
            label: Text('私密书架'),
          ),
        ],
        selected: {_space},
        showSelectedIcon: false,
        onSelectionChanged: _selecting ? null : _switchSpace,
      ),
      const SizedBox(height: 8),
      if (_space == BookShelfSpace.private && _available.isEmpty)
        const Padding(
          padding: EdgeInsets.only(bottom: 6),
          child: Text(
            '私密书架没有书单时，将保存到该空间并保留已有归属。',
            style: TextStyle(fontSize: 12),
          ),
        ),
      InputDecorator(
        decoration: const InputDecoration(labelText: '书单'),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String?>(
            isExpanded: true,
            value: _listId,
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('仅保存到空间（保留已有书单）'),
              ),
              for (final list in _available)
                DropdownMenuItem<String?>(
                  value: list.id,
                  child: Text(
                    '${_kindLabel(list.kind)} · ${list.name}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _selecting
                ? null
                : (value) => setState(() => _listId = value),
          ),
        ),
      ),
    ],
  );

  String _kindLabel(ShelfListKind kind) => switch (kind) {
    ShelfListKind.group => '分组',
    ShelfListKind.collection => '集合',
    ShelfListKind.list => '书单',
  };
}

Widget _chapterNumber(String label, int initial, ValueChanged<int> onChange) =>
    TextFormField(
      initialValue: '$initial',
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(labelText: label),
      onChanged: (value) => onChange(int.tryParse(value) ?? 0),
    );
