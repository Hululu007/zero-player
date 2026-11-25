import 'package:flutter/material.dart';

import '../../supervision/presentation/sensitive_action.dart';
import '../data/book_chapter_policy.dart';
import '../data/book_detected_replacement.dart';
import '../data/books_repository.dart';

Future<void> editDetectedReplacement(
  BuildContext context,
  BooksRepository books,
) => _verified(context, books, () async {
  await books.chapterPolicy.load();
  if (!context.mounted) return;
  final current = books.chapterPolicy.detectedForReview();
  var text = current?.text ?? '〔已屏蔽〕';
  var paragraph = current?.paragraph ?? false;
  var before = current?.before ?? 0, after = current?.after ?? 0;
  final result = await _guardedDialog<({BookDetectedReplacement? rule})>(
    context,
    books,
    requireConfigured: false,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: const Text('自动替换检测到的内容'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              initialValue: text,
              maxLength: 1000,
              maxLines: 3,
              decoration: const InputDecoration(labelText: '替换为（留空即隐藏）'),
              onChanged: (value) => text = value,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('替换命中段落'),
              subtitle: const Text('关闭时仅替换检测到的文字'),
              value: paragraph,
              onChanged: (value) => update(() => paragraph = value),
            ),
            if (paragraph) ...[
              _paragraphOffset(
                '向前扩展段数',
                before,
                (value) => update(() => before = value),
              ),
              _paragraphOffset(
                '向后扩展段数',
                after,
                (value) => update(() => after = value),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          if (current != null)
            TextButton(
              onPressed: () => Navigator.pop(context, (rule: null)),
              child: const Text('停用自动替换'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, (
              rule: BookDetectedReplacement(
                text,
                paragraph: paragraph,
                before: before,
                after: after,
              ),
            )),
            child: const Text('保存并应用'),
          ),
        ],
      ),
    ),
  );
  if (result != null) await books.chapterPolicy.saveDetected(result.rule);
}, requireConfigured: false);

Widget _paragraphOffset(String label, int count, ValueChanged<int> update) =>
    DropdownButtonFormField<int>(
      initialValue: count,
      decoration: InputDecoration(labelText: label),
      items: [
        for (var value = 0; value <= BookDetectedReplacement.maxOffset; value++)
          DropdownMenuItem(value: value, child: Text('$value 段')),
      ],
      onChanged: (value) => update(value!),
    );

Future<bool> reviewBlockedChapter(
  BuildContext context,
  BooksRepository books,
  ChapterContentBlocked block,
) async {
  var approved = false;
  await _verified(context, books, () async {
    if (!context.mounted) return;
    final accept = await _guardedDialog<bool>(
      context,
      books,
      builder: (context) => AlertDialog(
        title: const Text('本章过滤复核'),
        scrollable: true,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('命中关键词：${block.matches.join('、')}'),
            const SizedBox(height: 12),
            Text(
              block.supervised
                  ? '包含监管关键词，请在监管规则中修改；可设置替换规则后重新读取本章。'
                  : '确认误报后，仅排除本章当前原文与替换结果的成人标记。正文或替换规则改变后需重新验证；书源及其他监管限制继续生效。',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('关闭'),
          ),
          if (!block.supervised)
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认误报，仅排除此章'),
            ),
        ],
      ),
    );
    if (accept == true) {
      await books.chapterPolicy.approve(block);
      approved = true;
    }
  });
  return approved;
}

Future<void> showBookTextReplacements(
  BuildContext context,
  BooksRepository books,
) => _verified(context, books, () async {
  try {
    await books.chapterPolicy.load();
  } on FormatException {
    if (!context.mounted ||
        !await _guardedDialog<bool>(
          context,
          books,
          builder: (context) => AlertDialog(
            title: const Text('章节复核配置损坏'),
            content: const Text('原记录保持不变。是否验证并用空规则替换损坏配置？章节仍受成人和监管过滤。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('重新保存规则'),
              ),
            ],
          ),
        ).then((value) => value ?? false)) {
      return;
    }
    await books.chapterPolicy.saveRules([]);
  }
  final rules = books.chapterPolicy.rulesForReview().toList();
  if (!context.mounted) return;
  final editingSession = books.policy.supervision.createSession(
    SensitiveOperation.supervision,
  );
  try {
    final save = await _guardedDialog<bool>(
      context,
      books,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('小说文本敏感替换'),
          scrollable: true,
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '适用于在线小说与 TXT 的正文阅读、下载校验和文本导出。按顺序匹配字面关键词（忽略英文大小写），替换匹配词或所在段落，原文保留；替换后仍执行内容过滤。段落以换行分隔。EPUB／PDF 保留原有格式与过滤。',
                ),
                TextButton(
                  onPressed: () => editDetectedReplacement(context, books),
                  child: const Text('设置自动替换检测到的内容'),
                ),
                for (final (index, rule) in rules.indexed)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(rule.keyword),
                    subtitle: Text(
                      '${rule.paragraph ? '整段' : '匹配词'} → ${rule.replacement.isEmpty ? '删除' : rule.replacement}',
                    ),
                    trailing: IconButton(
                      tooltip: '删除替换规则',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => update(() => rules.removeAt(index)),
                    ),
                  ),
                TextButton.icon(
                  onPressed: rules.length >= 100
                      ? null
                      : () async {
                          final rule = await editingSession.run(
                            () => _editRule(context, books),
                          );
                          if (rule != null && context.mounted) {
                            update(() => rules.add(rule));
                          }
                        },
                  icon: const Icon(Icons.add),
                  label: const Text('添加替换规则'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (save == true) await books.chapterPolicy.saveRules(rules);
  } finally {
    editingSession.close();
  }
});

Future<BookTextReplacement?> _editRule(
  BuildContext context,
  BooksRepository books,
) async {
  var keyword = '', replacement = '', paragraph = false;
  return _guardedDialog<BookTextReplacement>(
    context,
    books,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: const Text('添加文本替换'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              maxLength: 80,
              decoration: const InputDecoration(labelText: '匹配关键词'),
              onChanged: (value) => update(() => keyword = value),
            ),
            TextField(
              maxLength: 1000,
              maxLines: 3,
              decoration: const InputDecoration(labelText: '替换为（留空表示删除）'),
              onChanged: (value) => replacement = value,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('替换关键词所在段落'),
              value: paragraph,
              onChanged: (value) => update(() => paragraph = value),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: keyword.trim().isEmpty
                ? null
                : () => Navigator.pop(
                    context,
                    BookTextReplacement(
                      keyword,
                      replacement,
                      paragraph: paragraph,
                    ),
                  ),
            child: const Text('添加'),
          ),
        ],
      ),
    ),
  );
}

Future<void> _verified(
  BuildContext context,
  BooksRepository books,
  Future<void> Function() action, {
  bool requireConfigured = true,
}) async {
  try {
    await books.policy.supervision.load();
    if (requireConfigured && !books.policy.supervision.configured) {
      throw const FormatException('请先在监管模式中设置密码');
    }
    if (!context.mounted) return;
    await runSensitive(
      context,
      books.policy.supervision,
      SensitiveOperation.supervision,
      () async {
        if (requireConfigured) books.chapterPolicy.requireReview();
        await action();
      },
      explanation: '验证后可查看命中词并管理本章误报或文本替换；不关闭成人过滤。',
    );
  } on FormatException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}

Future<T?> _guardedDialog<T>(
  BuildContext context,
  BooksRepository books, {
  required WidgetBuilder builder,
  bool requireConfigured = true,
}) async {
  if (requireConfigured) books.chapterPolicy.requireReview();
  final session = books.policy.supervision.createSession(
    SensitiveOperation.supervision,
  );
  try {
    return await showDialog<T>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: Listenable.merge([
          books.policy.supervision,
          books.policy,
          books.policy.settings,
        ]),
        builder: (context, _) => session.valid
            ? builder(context)
            : AlertDialog(
                title: const Text('验证已失效'),
                content: const Text('监管配置已改变，请关闭后重新验证。'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'),
                  ),
                ],
              ),
      ),
    );
  } finally {
    session.close();
  }
}
