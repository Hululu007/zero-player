import 'package:flutter/material.dart';

import '../data/book_reading_cleanup.dart';
import '../data/books_repository.dart';
import '../domain/book.dart';

Future<void> editReadingCleanup(
  BuildContext context,
  BooksRepository books,
  Book book, {
  String selected = '',
  ReadingCleanupRule? editing,
  String body = '',
}) async {
  await books.readingCleanup.load();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _CleanupEditor(
      books: books,
      book: book,
      selected: selected,
      editing: editing,
      body: body,
    ),
  );
}

class _CleanupEditor extends StatefulWidget {
  const _CleanupEditor({
    required this.books,
    required this.book,
    required this.selected,
    required this.body,
    this.editing,
  });
  final BooksRepository books;
  final Book book;
  final String selected, body;
  final ReadingCleanupRule? editing;
  @override
  State<_CleanupEditor> createState() => _CleanupEditorState();
}

class _CleanupEditorState extends State<_CleanupEditor> {
  late final _text = TextEditingController(
    text: widget.editing?.text ?? widget.selected,
  );
  late final _replacement = TextEditingController(
    text: widget.editing?.replacement ?? '',
  );
  late bool _global = widget.editing != null && widget.editing!.bookId == null;
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (!widget.books.bookAllowed(widget.book)) {
        throw const FormatException('当前作品受内容策略限制');
      }
      if (!widget.books.policy.textAllowed(_replacement.text)) {
        throw const FormatException('替换文字触发当前内容策略');
      }
      final next = ReadingCleanupRule(
        text: _text.text,
        replacement: _replacement.text,
        bookId: _global ? null : widget.book.id,
        enabled: widget.editing?.enabled ?? true,
      );
      final rules = widget.books.readingCleanup.rules.toList();
      final index = widget.editing == null
          ? -1
          : rules.indexOf(widget.editing!);
      if (index < 0) {
        rules.add(next);
      } else {
        rules[index] = next;
      }
      await widget.books.readingCleanup.save(rules);
      if (mounted) Navigator.pop(context);
    } on Exception catch (error) {
      if (mounted) {
        setState(
          () =>
              _error = error is FormatException ? error.message : '规则保存失败，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _replacement.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.books.policy,
      widget.books.sourceRiskChanges,
    ]),
    builder: (context, _) {
      final allowed =
          widget.books.bookAllowed(widget.book) &&
          widget.books.policy.textAllowed(_text.text);
      return AlertDialog(
        title: const Text('隐藏或替换选中文字'),
        scrollable: true,
        content: SizedBox(
          width: 460,
          child: !allowed
              ? const Text('内容策略已变更，请关闭后重新阅读')
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: _text,
                      maxLength: 2000,
                      minLines: 1,
                      maxLines: 5,
                      decoration: const InputDecoration(labelText: '匹配文字'),
                      onChanged: (_) => setState(() {}),
                    ),
                    TextField(
                      controller: _replacement,
                      maxLength: 2000,
                      maxLines: 4,
                      minLines: 1,
                      decoration: const InputDecoration(
                        labelText: '替换为（留空即隐藏）',
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('应用到所有小说'),
                      value: _global,
                      onChanged: (v) => setState(() => _global = v),
                    ),
                    const Text('按原样匹配，区分大小写；只改变阅读显示，保留原文。可在阅读样式中编辑、停用或删除规则。'),
                    if (_text.text.isNotEmpty && widget.body.isNotEmpty)
                      Text(
                        '当前章节匹配 ${RegExp(RegExp.escape(_text.text)).allMatches(widget.body).length} 处',
                      ),
                    if (_error != null)
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: !allowed || _saving ? null : _save,
            child: Text(_saving ? '保存中…' : '保存规则'),
          ),
        ],
      );
    },
  );
}

Future<void> showReadingCleanupRules(
  BuildContext context,
  BooksRepository books,
  Book book,
) async {
  await books.readingCleanup.load();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: .8,
      child: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([
            books.readingCleanup,
            books.policy,
            books.sourceRiskChanges,
          ]),
          builder: (context, _) {
            final rules = books.readingCleanup.rules;
            return Column(
              children: [
                ListTile(
                  title: const Text('阅读净化规则'),
                  subtitle: Text('${rules.length}/100 条 · 保留缓存与离线原文'),
                  trailing: IconButton(
                    tooltip: '添加净化规则',
                    icon: const Icon(Icons.add),
                    onPressed: () => editReadingCleanup(context, books, book),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: rules.length,
                    itemBuilder: (context, index) =>
                        _cleanupRuleTile(context, books, book, rules, index),
                  ),
                ),
                if (rules.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('长按正文选中文字，在选文菜单中选择「隐藏或替换」。'),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

Widget _cleanupRuleTile(
  BuildContext context,
  BooksRepository books,
  Book book,
  List<ReadingCleanupRule> rules,
  int index,
) {
  final rule = rules[index];
  final visible =
      (rule.bookId == null || rule.bookId == book.id) &&
      books.bookAllowed(book) &&
      books.policy.textAllowed('${rule.text}\n${rule.replacement}');
  Future<void> save(List<ReadingCleanupRule> next) async {
    try {
      await books.readingCleanup.save(next);
    } on Exception {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('保存失败，请重试')));
      }
    }
  }

  return ListTile(
    title: Text(
      visible ? rule.text : '内容受当前策略限制',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
    subtitle: Text(
      '${rule.bookId == null
          ? '所有小说'
          : rule.bookId == book.id
          ? '本书'
          : '其他作品'} · ${rule.replacement.isEmpty ? '隐藏' : '替换'}',
    ),
    onTap: !visible
        ? null
        : () => editReadingCleanup(context, books, book, editing: rule),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Switch(
          value: rule.enabled,
          onChanged: (value) {
            final next = rules.toList();
            next[index] = rule.withEnabled(value);
            save(next);
          },
        ),
        IconButton(
          tooltip: '删除净化规则',
          icon: const Icon(Icons.delete_outline),
          onPressed: () => save(rules.toList()..removeAt(index)),
        ),
      ],
    ),
  );
}
