import 'dart:async';

import 'package:flutter/material.dart';

import '../data/book_shelf_lists.dart';
import '../data/book_store.dart';
import '../data/books_repository.dart';
import '../domain/book.dart';
import 'book_cover.dart';
import 'book_vault_dialogs.dart';

const _labels = {
  ShelfListKind.group: '分组',
  ShelfListKind.collection: '集合',
  ShelfListKind.list: '书单',
};

enum _ShelfFilter { all, offline, online, updated }

class BookShelfView extends StatefulWidget {
  const BookShelfView({
    super.key,
    required this.repository,
    required this.kind,
    required this.entries,
    required this.onOpen,
    required this.onFollowChanged,
    required this.onRefresh,
    required this.onCheckUpdates,
    required this.checking,
    this.historyMode = false,
    this.private = false,
    this.cancelDownload,
    this.onOpenPrivate,
  });
  final BooksRepository repository;
  final BookKind kind;
  final List<BookShelfEntry> entries;
  final ValueChanged<Book> onOpen;
  final VoidCallback onFollowChanged;
  final Future<void> Function() onRefresh;
  final Future<void> Function(List<BookShelfEntry>) onCheckUpdates;
  final bool checking;
  final bool historyMode;

  /// The private shelf uses encrypted list storage and shows migration actions.
  final bool private;
  final Future<void> Function(Book)? cancelDownload;
  final VoidCallback? onOpenPrivate;

  @override
  State<BookShelfView> createState() => _BookShelfViewState();
}

class _BookShelfViewState extends State<BookShelfView> {
  List<ShelfList> _lists = [];
  String _selected = '';
  bool _following = false;
  bool _filtersOpen = false;
  _ShelfFilter _filter = _ShelfFilter.all;
  String _type = '';
  Set<String> _offlineIds = {};
  int _offlineSequence = 0;
  BookShelfLists get _store => BookShelfLists(
    widget.repository.store,
    widget.kind,
    private: widget.private,
  );

  @override
  void initState() {
    super.initState();
    _reload();
    unawaited(_refreshOffline());
  }

  @override
  void didUpdateWidget(covariant BookShelfView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.entries, oldWidget.entries)) {
      if (_type.isNotEmpty &&
          !widget.entries.any((entry) => _bookType(entry.book) == _type)) {
        _type = '';
      }
      unawaited(_refreshOffline());
    }
  }

  Future<void> _refreshOffline() async {
    final sequence = ++_offlineSequence;
    final ids = <String>{};
    for (final entry in widget.entries) {
      final book = entry.book;
      if (book.sourceId == 'local') {
        ids.add(book.id);
        continue;
      }
      final saved = switch (book.kind) {
        BookKind.text => await widget.repository.store.savedText(book),
        BookKind.comic => await widget.repository.store.savedImages(book),
        BookKind.audio => await widget.repository.savedAudio(book),
      };
      if (saved.isNotEmpty) ids.add(book.id);
    }
    if (mounted && sequence == _offlineSequence) {
      setState(() => _offlineIds = ids);
    }
  }

  String _bookType(Book book) {
    if (book.sourceId == 'local') {
      final path = book.uri.path.toLowerCase();
      if (path.endsWith('.epub')) return 'EPUB';
      if (path.endsWith('.pdf')) return 'PDF';
      return 'TXT';
    }
    return book.category.trim().isEmpty ? '网络作品' : book.category.trim();
  }

  Future<void> _reload() async {
    final lists = await _store.load();
    if (mounted) {
      setState(() {
        _lists = lists;
        if (!lists.any((list) => list.id == _selected)) _selected = '';
      });
    }
  }

  Future<void> _edit(ShelfListKind kind, [ShelfList? list]) async {
    var name = list?.name ?? '';
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${list == null ? '新建' : '重命名'}${_labels[kind]}'),
        content: TextFormField(
          initialValue: name,
          maxLength: 60,
          autofocus: true,
          decoration: const InputDecoration(labelText: '名称'),
          onChanged: (value) => name = value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, name),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (!mounted || result == null) return;
    try {
      await _store.save(result, kind, id: list?.id);
      await _reload();
    } on FormatException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _assign(Book book) async {
    if (_lists.isEmpty) {
      await _edit(ShelfListKind.group);
      if (!mounted || _lists.isEmpty) return;
    }
    final selected = {
      for (final list in _lists)
        if (list.books.contains(book.id)) list.id,
    };
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => ListenableBuilder(
          listenable: Listenable.merge([
            widget.repository.policy,
            widget.repository.sourceRiskChanges,
          ]),
          builder: (context, _) => !widget.repository.bookAllowed(book)
              ? const AlertDialog(content: Text('当前内容策略限制访问此作品'))
              : AlertDialog(
                  title: const Text('归入分组、集合或书单'),
                  content: SizedBox(
                    width: 450,
                    height: 300,
                    child: ListView(
                      children: [
                        for (final list in _lists)
                          CheckboxListTile(
                            title: Text(list.name),
                            subtitle: Text(_labels[list.kind]!),
                            value: selected.contains(list.id),
                            onChanged: (value) => update(() {
                              if (value == true) {
                                if (list.kind == ShelfListKind.group) {
                                  selected.removeAll(
                                    _lists
                                        .where(
                                          (item) =>
                                              item.kind == ShelfListKind.group,
                                        )
                                        .map((item) => item.id),
                                  );
                                }
                                selected.add(list.id);
                              } else {
                                selected.remove(list.id);
                              }
                            }),
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
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('保存'),
                    ),
                  ],
                ),
        ),
      ),
    );
    if (!mounted || confirmed != true || !widget.repository.bookAllowed(book)) {
      return;
    }
    await _store.assign(book, selected);
    await _reload();
  }

  Future<void> _bookAction(BookShelfEntry entry, String action) async {
    if (!widget.repository.bookAllowed(entry.book)) return;
    switch (action) {
      case 'lists':
        await _assign(entry.book);
      case 'history':
        await _clearHistory([entry.book]);
      case 'follow':
        await widget.repository.store.saveBook(
          entry.book,
          following: !entry.following,
        );
        if (mounted) widget.onFollowChanged();
      case 'private':
        await _moveToPrivate(entry.book);
      case 'unprivate':
        await _moveOutOfPrivate(entry.book);
      case 'remove':
        await _confirmRemove(entry.book);
      case 'delete':
        await _confirmDelete(entry.book);
    }
  }

  Future<bool> _confirmRemove(Book book) async {
    var offline = false;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('从书架移除《${book.title}》？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('阅读进度会清除，笔记与书签保留。'),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('同时删除离线文件与阅读缓存'),
                value: offline,
                onChanged: (value) => update(() => offline = value == true),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('移除'),
            ),
          ],
        ),
      ),
    );
    if (accepted != true || !mounted) return false;
    await _removeFromShelf(book, clearOffline: offline);
    return true;
  }

  Future<bool> _confirmDelete(Book book) async {
    var offline = true;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('删除《${book.title}》？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('书架记录、阅读进度、笔记与书签将被删除，此操作不可撤销。'),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('同时删除缓存与离线文件'),
                subtitle: const Text('取消勾选会保留已下载内容，便于以后重新加入'),
                value: offline,
                onChanged: (value) => update(() => offline = value == true),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除'),
            ),
          ],
        ),
      ),
    );
    if (accepted != true || !mounted) return false;
    await _deleteBook(book, clearOffline: offline);
    return true;
  }

  Future<void> _removeFromShelf(Book book, {bool clearOffline = false}) async {
    try {
      await _stopDownload(book);
      await widget.repository.store.removeFromShelf(
        book,
        clearOffline: clearOffline,
      );
      if (clearOffline) await _removeOfflineFiles(book);
      await _store.removeBook(book.id);
      await _reload();
      if (mounted) {
        widget.onFollowChanged();
        _toast('已从书架移除');
      }
    } on FormatException catch (error) {
      if (mounted) _toast(error.message);
    } on Exception {
      if (mounted) _toast('操作未完成，请重试');
    }
  }

  Future<void> _deleteBook(Book book, {bool clearOffline = true}) async {
    try {
      await _stopDownload(book);
      await widget.repository.store.deleteBook(
        book,
        clearOffline: clearOffline,
      );
      if (clearOffline) await _removeOfflineFiles(book);
      await _store.removeBook(book.id);
      await _reload();
      if (mounted) {
        widget.onFollowChanged();
        _toast(clearOffline ? '已删除作品与离线内容' : '已删除作品，离线内容已保留');
      }
    } on FormatException catch (error) {
      if (mounted) _toast(error.message);
    } on Exception {
      if (mounted) _toast('删除未完成，请重试');
    }
  }

  Future<void> _stopDownload(Book book) async {
    if (widget.cancelDownload case final cancel?) await cancel(book);
  }

  Future<void> _removeOfflineFiles(Book book) async {
    if (book.kind == BookKind.audio) {
      await widget.repository.removeSavedAudio(book);
    } else {
      await widget.repository.store.clearOffline(book);
    }
    await widget.repository.store.clearReadingCache(book);
  }

  Future<void> _moveToPrivate(Book book) async {
    final unlocked = await ensureVaultAccess(context, widget.repository.store);
    if (!unlocked || !mounted) return;
    try {
      await widget.repository.store.moveToVault(book);
      await BookShelfLists(
        widget.repository.store,
        widget.kind,
      ).removeBook(book.id);
      await _reload();
      if (mounted) {
        widget.onFollowChanged();
        _toast('已移入私密书架，可在书架入口解锁查看');
      }
    } on FormatException catch (error) {
      if (mounted) _toast(error.message);
    } on Exception {
      if (mounted) _toast('移入私密书架未完成，请重试');
    }
  }

  Future<void> _moveOutOfPrivate(Book book) async {
    try {
      await widget.repository.store.moveOutOfVault(book);
      await _store.removeBook(book.id);
      await _reload();
      if (mounted) {
        widget.onFollowChanged();
        _toast('已移出私密书架');
      }
    } on FormatException catch (error) {
      if (mounted) _toast(error.message);
    } on Exception {
      if (mounted) _toast('移出私密书架未完成，请重试');
    }
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _clearHistory(List<Book> books, {bool confirm = false}) async {
    if (confirm) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('清空历史？'),
          content: const Text('将清除当前历史列表的阅读进度，保留书架、收藏与离线内容。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('清空'),
            ),
          ],
        ),
      );
      if (accepted != true) return;
    }
    try {
      await widget.repository.store.clearHistory(books);
      if (mounted) widget.onFollowChanged();
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('历史删除失败，请重试')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _lists.where((item) => item.id == _selected).firstOrNull;
    final base = widget.entries
        .where(
          (entry) =>
              (!_following || entry.following) &&
              (list == null || list.books.contains(entry.book.id)),
        )
        .toList();
    final entries = base.where((entry) {
      if (_type.isNotEmpty && _bookType(entry.book) != _type) return false;
      return switch (_filter) {
        _ShelfFilter.all => true,
        _ShelfFilter.offline => _offlineIds.contains(entry.book.id),
        _ShelfFilter.online => entry.book.sourceId != 'local',
        _ShelfFilter.updated => entry.newChapters > 0,
      };
    }).toList();
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 620;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.historyMode)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: widget.entries.isEmpty
                      ? null
                      : () => _clearHistory(
                          widget.entries.map((entry) => entry.book).toList(),
                          confirm: true,
                        ),
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: const Text('清空历史'),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
              child: _toolbar(list, compact: compact),
            ),
            if (widget.checking) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: entries.isEmpty
                  ? const Center(child: Text('这里还没有作品'))
                  : ListView.builder(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: entries.length,
                      itemBuilder: (_, index) => _tile(entries[index]),
                    ),
            ),
          ],
        );
      },
    );
  }

  bool get _filtersActive =>
      _following || _filter != _ShelfFilter.all || _type.isNotEmpty;

  Widget _toolbar(ShelfList? list, {required bool compact}) {
    if (!compact) return _wideToolbar(list);
    final rows = <Widget>[
      Row(
        children: [
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: _listPicker(),
            ),
          ),
          Badge(
            smallSize: 8,
            isLabelVisible: _filtersActive,
            child: IconButton(
              tooltip: _filtersOpen ? '收起筛选' : '筛选与追更',
              isSelected: _filtersOpen,
              onPressed: () => setState(() => _filtersOpen = !_filtersOpen),
              icon: const Icon(Icons.tune),
            ),
          ),
          IconButton(
            tooltip: '检查追更',
            onPressed: widget.checking ? null : widget.onRefresh,
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<ShelfListKind>(
            tooltip: '新建书架列表',
            icon: const Icon(Icons.add),
            onSelected: _edit,
            itemBuilder: (_) => [
              for (final type in ShelfListKind.values)
                PopupMenuItem(value: type, child: Text('新建${_labels[type]}')),
            ],
          ),
          if (list != null) _listMenu(list),
        ],
      ),
      if (_filtersOpen)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilterChip(
                label: const Text('追更'),
                selected: _following,
                onSelected: (value) => setState(() => _following = value),
              ),
              _statusFilter(),
              _typeFilter(),
            ],
          ),
        ),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  static const _privateOption = '__private__';

  Widget _listPicker() => DropdownButton<String>(
    isExpanded: true,
    value: _selected,
    items: [
      const DropdownMenuItem(value: '', child: Text('全部书籍')),
      for (final item in _lists)
        DropdownMenuItem(
          value: item.id,
          child: Text(
            '${_labels[item.kind]} · ${item.name}',
            overflow: TextOverflow.ellipsis,
          ),
        ),
      if (!widget.private && widget.onOpenPrivate != null)
        const DropdownMenuItem(
          value: _privateOption,
          child: Row(
            children: [
              Icon(Icons.lock_outline, size: 16),
              SizedBox(width: 6),
              Text('私密书架'),
            ],
          ),
        ),
    ],
    onChanged: (value) {
      if (value == _privateOption) {
        setState(() => _selected = '');
        widget.onOpenPrivate?.call();
        return;
      }
      setState(() => _selected = value ?? '');
    },
  );

  Widget _listMenu(ShelfList list) => PopupMenuButton<bool>(
    tooltip: '管理当前列表',
    onSelected: (rename) async {
      if (rename) {
        await _edit(list.kind, list);
      } else {
        await _store.delete(list.id);
        await _reload();
      }
    },
    itemBuilder: (_) => const [
      PopupMenuItem(value: true, child: Text('重命名')),
      PopupMenuItem(value: false, child: Text('删除列表')),
    ],
  );

  Widget _wideToolbar(ShelfList? list) => Wrap(
    spacing: 6,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 180),
        child: _listPicker(),
      ),
      FilterChip(
        label: const Text('追更'),
        selected: _following,
        onSelected: (value) => setState(() => _following = value),
      ),
      _statusFilter(),
      _typeFilter(),
      IconButton(
        tooltip: '检查追更',
        onPressed: widget.checking ? null : widget.onRefresh,
        icon: const Icon(Icons.refresh),
      ),
      PopupMenuButton<ShelfListKind>(
        tooltip: '新建书架列表',
        icon: const Icon(Icons.add),
        onSelected: _edit,
        itemBuilder: (_) => [
          for (final type in ShelfListKind.values)
            PopupMenuItem(value: type, child: Text('新建${_labels[type]}')),
        ],
      ),
      if (list != null) _listMenu(list),
    ],
  );

  Widget _statusFilter() => DropdownButton<_ShelfFilter>(
    value: _filter,
    items: const [
      DropdownMenuItem(value: _ShelfFilter.all, child: Text('全部状态')),
      DropdownMenuItem(value: _ShelfFilter.offline, child: Text('本地离线')),
      DropdownMenuItem(value: _ShelfFilter.online, child: Text('在线阅读')),
      DropdownMenuItem(value: _ShelfFilter.updated, child: Text('有更新')),
    ],
    onChanged: (value) {
      if (value == null) return;
      setState(() => _filter = value);
      if (value == _ShelfFilter.updated) {
        final list = _lists.where((item) => item.id == _selected).firstOrNull;
        final entries = widget.entries.where(
          (entry) =>
              (!_following || entry.following) &&
              (list == null || list.books.contains(entry.book.id)) &&
              (_type.isEmpty || _bookType(entry.book) == _type),
        );
        unawaited(widget.onCheckUpdates(entries.toList()));
      }
    },
  );

  Widget _typeFilter() => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 150),
    child: DropdownButton<String>(
      isExpanded: true,
      value: _type,
      items: [
        const DropdownMenuItem(value: '', child: Text('全部类型')),
        for (final type
            in widget.entries
                .map((entry) => _bookType(entry.book))
                .toSet()
                .toList()
              ..sort())
          DropdownMenuItem(
            value: type,
            child: Text(type, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (value) => setState(() => _type = value ?? ''),
    ),
  );

  Widget _tile(BookShelfEntry entry) {
    final book = entry.book;
    final last = entry.chapters
        .where((chapter) => chapter.id == entry.last)
        .firstOrNull;
    final latest = entry.chapters.lastOrNull;
    return ListTile(
      leading: SizedBox(
        width: 40,
        height: 54,
        child: BookCover(book: book, repository: widget.repository),
      ),
      title: Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          book.author,
          if (last != null) last.title,
          if (entry.newChapters > 0 && latest != null)
            '更新 ${entry.newChapters} 章 · ${latest.title}'
          else if (entry.following)
            '追更中',
        ].where((value) => value.isNotEmpty).join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => widget.onOpen(book),
      trailing: PopupMenuButton<String>(
        tooltip: '书架操作',
        onSelected: (action) => _bookAction(entry, action),
        itemBuilder: (_) => [
          if (entry.last != null)
            const PopupMenuItem(value: 'history', child: Text('删除阅读历史')),
          const PopupMenuItem(value: 'lists', child: Text('归入分组、集合或书单')),
          if (book.sourceId != 'local')
            PopupMenuItem(
              value: 'follow',
              child: Text(entry.following ? '取消追更' : '加入追更'),
            ),
          const PopupMenuDivider(),
          if (widget.private)
            const PopupMenuItem(value: 'unprivate', child: Text('移出私密书架'))
          else
            const PopupMenuItem(value: 'private', child: Text('移入私密书架')),
          const PopupMenuItem(value: 'remove', child: Text('从书架移除')),
          const PopupMenuItem(value: 'delete', child: Text('删除')),
        ],
      ),
    );
  }
}
