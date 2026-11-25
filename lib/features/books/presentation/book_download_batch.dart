part of 'book_download_management_page.dart';

enum _DownloadBatchAction { retry, pause, settings, move, remove, delete }

extension _BookDownloadBatch on _BookDownloadManagementPageState {
  Widget _batchBar(List<_DownloadItem> visible) => bookBatchBar(
    active: _selecting,
    busy: _batchBusy,
    selected: visible
        .where((item) => _selection.contains(item.entry.book.id))
        .length,
    hasEntries: visible.isNotEmpty,
    onToggle: () => _changeSelection(() {
      _selecting = !_selecting;
      _selection.clear();
    }),
    onSelectAll: () => _changeSelection(() {
      _selection.addAll(visible.map((item) => item.entry.book.id));
    }),
    onAction: (action) => _batch(
      action,
      visible.where((item) => _selection.contains(item.entry.book.id)).toList(),
    ),
    actions: [
      const PopupMenuItem(
        value: _DownloadBatchAction.retry,
        child: Text('继续下载或重试'),
      ),
      const PopupMenuItem(
        value: _DownloadBatchAction.pause,
        child: Text('暂停下载'),
      ),
      const PopupMenuItem(
        value: _DownloadBatchAction.settings,
        child: Text('修改重试次数'),
      ),
      PopupMenuItem(
        value: _DownloadBatchAction.move,
        child: Text(widget.private ? '移出私密书架' : '移入私密书架'),
      ),
      const PopupMenuItem(
        value: _DownloadBatchAction.remove,
        child: Text('移除下载计划'),
      ),
      const PopupMenuItem(
        value: _DownloadBatchAction.delete,
        child: Text('删除离线内容'),
      ),
    ],
  );

  void _toggleBook(Book book) => _changeSelection(() {
    if (!_selection.remove(book.id)) _selection.add(book.id);
  });

  Future<void> _batch(
    _DownloadBatchAction action,
    List<_DownloadItem> items,
  ) async {
    if (_batchBusy || items.isEmpty) return;
    _changeSelection(() => _batchBusy = true);
    final books = widget.services.books;
    try {
      final retryCount = action == _DownloadBatchAction.settings
          ? await _chooseRetryCount()
          : null;
      if (!mounted ||
          action == _DownloadBatchAction.settings && retryCount == null) {
        return;
      }
      if (action == _DownloadBatchAction.move && !widget.private) {
        if (!await ensureVaultAccess(context, books.store)) return;
        if (!mounted) return;
      }
      final accepted = switch (action) {
        _DownloadBatchAction.remove => await _confirm(
          '移除所选 ${items.length} 项下载计划？',
          '保留已下载的章节。',
        ),
        _DownloadBatchAction.delete => await _confirm(
          '删除所选 ${items.length} 项离线内容？',
          '保留书架记录和阅读进度，下载计划同时移除。',
        ),
        _ => true,
      };
      if (!accepted || !mounted) return;
      var completed = 0;
      for (final item in items) {
        if (!mounted) break;
        final book = item.entry.book;
        if (!_bookVisible(book) || !_busyIds.add(book.id)) continue;
        try {
          if (await _applyBatch(item, action, retryCount)) {
            completed++;
            _selection.remove(book.id);
          }
        } on Exception {
          // Continue with the other selected downloads.
        } finally {
          _busyIds.remove(book.id);
        }
      }
      if (mounted) {
        await _reload();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已处理 $completed 项 · 已跳过或失败 ${items.length - completed} 项',
            ),
          ),
        );
        if (_selection.isEmpty) _changeSelection(() => _selecting = false);
      }
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('批量操作未完成，请重试')));
      }
    } finally {
      if (mounted) _changeSelection(() => _batchBusy = false);
    }
  }

  Future<bool> _applyBatch(
    _DownloadItem item,
    _DownloadBatchAction action,
    int? retryCount,
  ) async {
    final book = item.entry.book;
    final books = widget.services.books;
    final store = books.store;
    switch (action) {
      case _DownloadBatchAction.retry:
        return retryBookDownload(books, _manager, item.entry);
      case _DownloadBatchAction.pause:
        if (_manager.active(book) == null) return false;
        await _manager.pause(book);
      case _DownloadBatchAction.settings:
        if (_manager.active(book) != null) return false;
        final key = 'books_download:${book.id}';
        return store.db.atomic(() async {
          final current = BookDownloadPlan.fromJson(
            await store.readBookValue(book, key),
          );
          if (current == null ||
              !_bookVisible(book) ||
              _manager.active(book) != null) {
            return false;
          }
          await store.writeBookValue(book, key, {
            ...current.toJson(),
            'retryCount': retryCount!,
          });
          return true;
        }, tables: {'app_meta'});
      case _DownloadBatchAction.move:
        await _manager.pause(book);
        if (!_bookVisible(book)) return false;
        if (widget.private) {
          await store.moveOutOfVault(book);
        } else {
          await store.moveToVault(book);
        }
      case _DownloadBatchAction.remove:
        await _manager.removePlan(book);
      case _DownloadBatchAction.delete:
        await _clearDownload(book);
    }
    return true;
  }

  Future<int?> _chooseRetryCount() => showDialog<int>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('单章自动重试次数'),
      children: [
        for (var count = 0; count <= BookDownloadPlan.maxRetryCount; count++)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, count),
            child: Text(count == 0 ? '关闭' : '$count 次'),
          ),
      ],
    ),
  );
}
