part of 'book_shelf_view.dart';

enum _ShelfBatchAction {
  organize,
  follow,
  unfollow,
  retry,
  move,
  remove,
  delete,
}

extension _BookShelfBatch on _BookShelfViewState {
  Widget _batchBar(List<BookShelfEntry> entries) => bookBatchBar(
    active: _selecting,
    busy: _batchBusy,
    selected: entries
        .where((entry) => _selection.contains(entry.book.id))
        .length,
    hasEntries: entries.isNotEmpty,
    onToggle: () => _changeSelection(() {
      _selecting = !_selecting;
      _selection.clear();
    }),
    onSelectAll: () => _changeSelection(() {
      _selection.addAll(entries.map((entry) => entry.book.id));
    }),
    onAction: (action) => _batch(
      action,
      entries.where((entry) => _selection.contains(entry.book.id)).toList(),
    ),
    actions: [
      const PopupMenuItem(
        value: _ShelfBatchAction.organize,
        child: Text('归入同一书架列表'),
      ),
      if (entries.any((entry) => entry.book.sourceId != 'local')) ...[
        const PopupMenuItem(
          value: _ShelfBatchAction.follow,
          child: Text('加入追更'),
        ),
        const PopupMenuItem(
          value: _ShelfBatchAction.unfollow,
          child: Text('取消追更'),
        ),
      ],
      if (widget.downloads != null)
        const PopupMenuItem(
          value: _ShelfBatchAction.retry,
          child: Text('重试下载'),
        ),
      PopupMenuItem(
        value: _ShelfBatchAction.move,
        child: Text(widget.private ? '移出私密书架' : '移入私密书架'),
      ),
      const PopupMenuItem(
        value: _ShelfBatchAction.remove,
        child: Text('从书架移除'),
      ),
      const PopupMenuItem(value: _ShelfBatchAction.delete, child: Text('删除作品')),
    ],
  );

  void _toggleBook(Book book) => _changeSelection(() {
    if (!_selection.remove(book.id)) _selection.add(book.id);
  });

  Future<void> _batch(
    _ShelfBatchAction action,
    List<BookShelfEntry> entries,
  ) async {
    if (_batchBusy || entries.isEmpty) return;
    _changeSelection(() => _batchBusy = true);
    try {
      final list = action == _ShelfBatchAction.organize
          ? await _pickBatchList()
          : null;
      if (action == _ShelfBatchAction.organize && list == null) return;
      if (action == _ShelfBatchAction.move &&
          !widget.private &&
          mounted &&
          !await ensureVaultAccess(context, widget.repository.store)) {
        return;
      }
      final destructive =
          action == _ShelfBatchAction.remove ||
          action == _ShelfBatchAction.delete;
      final offline = destructive
          ? await _confirmBatchDelete(entries.length, action)
          : false;
      if (offline == null || !mounted) return;
      var completed = 0;
      for (final entry in entries) {
        if (!mounted) break;
        if (!_bookVisible(entry.book)) {
          continue;
        }
        try {
          if (await _applyBatch(entry, action, list, offline)) {
            completed++;
            _selection.remove(entry.book.id);
          }
        } on Exception {
          // Continue with the other selected books.
        }
      }
      await _reload();
      if (mounted) {
        widget.onFollowChanged();
        _toast('已处理 $completed 项 · 已跳过或失败 ${entries.length - completed} 项');
        if (_selection.isEmpty) _changeSelection(() => _selecting = false);
      }
    } on FormatException catch (error) {
      if (mounted) _toast(error.message);
    } on Exception {
      if (mounted) _toast('批量操作未完成，请重试');
    } finally {
      if (mounted) _changeSelection(() => _batchBusy = false);
    }
  }

  Future<bool> _applyBatch(
    BookShelfEntry entry,
    _ShelfBatchAction action,
    ShelfList? list,
    bool offline,
  ) async {
    final book = entry.book;
    final store = widget.repository.store;
    switch (action) {
      case _ShelfBatchAction.organize:
        await _store.addToList(book, list!.id);
      case _ShelfBatchAction.follow:
      case _ShelfBatchAction.unfollow:
        if (book.sourceId == 'local') return false;
        await store.saveBook(
          book,
          following: action == _ShelfBatchAction.follow,
        );
      case _ShelfBatchAction.retry:
        return retryBookDownload(widget.repository, widget.downloads!, entry);
      case _ShelfBatchAction.move:
        if (widget.pauseDownload case final pause?) await pause(book);
        if (!_bookVisible(book)) return false;
        if (widget.private) {
          await store.moveOutOfVault(book);
        } else {
          await store.moveToVault(book);
        }
      case _ShelfBatchAction.remove:
      case _ShelfBatchAction.delete:
        await _stopDownload(book);
        if (!_bookVisible(book)) return false;
        await _removeRecord(
          book,
          action == _ShelfBatchAction.delete
              ? store.deleteBook
              : store.removeFromShelf,
          clearOffline: offline,
        );
    }
    return true;
  }

  Future<ShelfList?> _pickBatchList() async {
    if (_lists.isEmpty) await _edit(ShelfListKind.group);
    if (!mounted || _lists.isEmpty) return null;
    return showDialog<ShelfList>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('归入书架列表'),
        children: [
          for (final list in _lists)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, list),
              child: Text('${_labels[list.kind]} · ${list.name}'),
            ),
        ],
      ),
    );
  }

  Future<bool?> _confirmBatchDelete(int count, _ShelfBatchAction action) async {
    if (!mounted) return null;
    final delete = action == _ShelfBatchAction.delete;
    var offline = delete;
    return showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(delete ? '删除所选 $count 项？' : '从书架移除所选 $count 项？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(delete ? '将删除书架记录、进度、笔记和书签。' : '将清除阅读进度，保留笔记和书签。'),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('同时删除离线文件与阅读缓存'),
                value: offline,
                onChanged: (value) => update(() => offline = value ?? false),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, offline),
              child: const Text('确认'),
            ),
          ],
        ),
      ),
    );
  }
}
