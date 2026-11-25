import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/network/cancellation_token.dart';
import '../application/publication_collections.dart';
import '../application/publication_module.dart';
import '../data/publication_list_import.dart';
import '../domain/publication.dart';
import 'publication_dialogs.dart';

class PublicationBookListsPage extends StatefulWidget {
  const PublicationBookListsPage({
    super.key,
    required this.module,
    required this.onPage,
  });

  final PublicationModule module;
  final void Function(Uri) onPage;

  @override
  State<PublicationBookListsPage> createState() =>
      _PublicationBookListsPageState();
}

class _PublicationBookListsPageState extends State<PublicationBookListsPage> {
  PublicationCollections get _collections => widget.module.collections;
  bool Function(String) get _allowed => widget.module.discovery.allowed;
  CancellationToken? _token;
  List<PublicationBookList> _lists = const [];
  List<PublicationEdition> _books = const [];
  String? _selected, _message;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.module.policy.addListener(_policyChanged);
    unawaited(_run(() async {}));
  }

  void _policyChanged() {
    _token?.cancel();
    setState(() {});
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !_allowed('')) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
      final lists = await _collections.lists();
      final selected = lists.where((item) => item.id == _selected).firstOrNull;
      final books = selected == null
          ? <PublicationEdition>[]
          : await _collections.items(selected);
      if (!mounted) return;
      setState(() {
        _lists = lists;
        _books = books;
        _selected = selected?.id;
      });
    } on RequestCancelled {
      // The route or content policy no longer permits this request.
    } catch (error) {
      if (mounted) {
        _message = switch (error) {
          PublicationFailure(:final problem) => problem.label,
          FormatException(:final message) => message.toString(),
          _ => '书单操作失败，请重试',
        };
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final name = await publicationPrompt(context, '新建书单', limit: 100);
    if (!mounted || name == null) return;
    _selected = await _collections.createList(name);
  }

  Future<void> _import() async {
    final input = await publicationPrompt(
      context,
      '粘贴豆瓣或微信读书的公开书单链接',
      multiline: true,
      limit: 2000,
    );
    if (!mounted || input == null) return;
    final token = _token = CancellationToken();
    final PublicationImportedList imported;
    setState(() {});
    try {
      imported = await importPublicationList(
        widget.module.discovery.http,
        input,
        token,
      );
    } finally {
      _token = null;
    }
    if (!mounted) return;
    final books = imported.books
        .where((book) => _allowed('${book.title} ${book.author}'))
        .toList();
    if (books.isEmpty) {
      throw const FormatException('书单没有可显示的书目');
    }
    final name = await publicationPrompt(
      context,
      '导入 ${books.length} 本${imported.truncated ? '（达到单次导入上限）' : ''}',
      initial: imported.name,
      limit: 100,
    );
    if (!mounted || name == null) return;
    _selected = await _collections.createList(
      name,
      source: imported.source,
      books: books,
    );
  }

  Future<void> _add(PublicationBookList list) async {
    final title = await publicationPrompt(context, '书名');
    if (!mounted || title == null) return;
    final label = publicationLabel(title);
    if (label.isEmpty) return;
    await _collections.add(
      list,
      PublicationEdition(id: publicationId('list:$label'), title: label),
    );
  }

  Future<void> _manage(PublicationBookList list, String action) async {
    switch (action) {
      case 'rename':
        final name = await publicationPrompt(
          context,
          '重命名书单',
          initial: list.name,
          limit: 100,
        );
        if (mounted && name != null) await _collections.renameList(list, name);
      case 'delete':
        if (await confirmPublicationDelete(
          context,
          '删除《${list.name}》？',
          '此操作会移除书单中的书目。',
        )) {
          await _collections.deleteList(list);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _lists
        .where((item) => item.id == _selected && _allowed(item.name))
        .firstOrNull;
    return PopScope<PublicationEdition>(
      canPop: list == null,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && list != null) _showLists();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: list == null ? null : BackButton(onPressed: _showLists),
          title: Text(list?.name ?? '我的书单'),
        ),
        body: !_allowed('')
            ? const Center(child: Text('当前内容策略限制书单访问'))
            : Column(
                children: [
                  if (_busy) const LinearProgressIndicator(minHeight: 2),
                  if (_token case final token?)
                    TextButton(
                      onPressed: token.cancel,
                      child: const Text('取消读取书单'),
                    ),
                  if (_message case final message?)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(message),
                    ),
                  Expanded(child: list == null ? _catalog() : _contents(list)),
                ],
              ),
      ),
    );
  }

  void _showLists() {
    _token?.cancel();
    setState(() {
      _selected = null;
      _books = const [];
      _message = null;
    });
  }

  Widget _catalog() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.tonal(
            onPressed: _busy ? null : () => _run(_create),
            child: const Text('新建书单'),
          ),
          OutlinedButton(
            onPressed: _busy ? null : () => _run(_import),
            child: const Text('导入公开书单'),
          ),
        ],
      ),
      if (_lists.isEmpty) const ListTile(title: Text('还没有书单，可新建或导入公开书单。')),
      for (final list in _lists)
        if (_allowed(list.name))
          ListTile(
            leading: const Icon(Icons.list_alt_outlined),
            title: Text(list.name),
            subtitle: switch (list.source?.host) {
              'www.douban.com' => const Text('豆瓣'),
              'weread.qq.com' => const Text('微信读书'),
              _ => null,
            },
            onTap: _busy ? null : () => _run(() async => _selected = list.id),
            trailing: _menu(list),
          ),
    ],
  );

  Widget _menu(PublicationBookList list) => PopupMenuButton<String>(
    tooltip: '管理书单',
    enabled: !_busy,
    onSelected: (action) => _run(() => _manage(list, action)),
    itemBuilder: (_) => const [
      PopupMenuItem(value: 'rename', child: Text('重命名')),
      PopupMenuItem(value: 'delete', child: Text('删除书单')),
    ],
  );

  Widget _contents(PublicationBookList list) {
    final books = _books
        .where((book) => _allowed('${book.title} ${book.author}'))
        .toList();
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: books.isEmpty ? 2 : books.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton.icon(
                onPressed: _showLists,
                icon: const Icon(Icons.arrow_back),
                label: const Text('全部书单'),
              ),
              FilledButton.tonal(
                onPressed: _busy ? null : () => _run(() => _add(list)),
                child: const Text('添加书目'),
              ),
              if (list.source case final source?)
                TextButton(
                  onPressed: () => widget.onPage(source),
                  child: const Text('查看原书单'),
                ),
              _menu(list),
            ],
          );
        }
        if (books.isEmpty) {
          return ListTile(
            title: Text(_books.isEmpty ? '书单还没有书目' : '当前内容策略隐藏了书目'),
          );
        }
        final book = books[index - 1];
        final details = [
          book.author,
          book.publisher,
          book.isbn,
        ].where((value) => value.isNotEmpty && _allowed(value)).join(' · ');
        return ListTile(
          title: Text(book.title),
          subtitle: details.isEmpty ? null : Text(details),
          onTap: _busy ? null : () => Navigator.pop(context, book),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: '查找可下载版本',
                onPressed: _busy ? null : () => Navigator.pop(context, book),
                icon: const Icon(Icons.search),
              ),
              PopupMenuButton<String>(
                tooltip: '书目操作',
                enabled: !_busy,
                onSelected: (action) {
                  if (action == 'source') {
                    widget.onPage(book.page!);
                  } else {
                    unawaited(
                      _run(() async {
                        if (await confirmPublicationDelete(
                          context,
                          '从书单移除《${book.title}》？',
                          '该书单将删除这条书目。',
                          action: '移除书目',
                        )) {
                          await _collections.remove(list, book);
                        }
                      }),
                    );
                  }
                },
                itemBuilder: (_) => [
                  if (book.page != null)
                    const PopupMenuItem(value: 'source', child: Text('查看出处')),
                  const PopupMenuItem(value: 'remove', child: Text('从书单移除')),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _token?.cancel();
    widget.module.policy.removeListener(_policyChanged);
    super.dispose();
  }
}
