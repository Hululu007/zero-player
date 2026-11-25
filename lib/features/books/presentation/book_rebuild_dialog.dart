import 'package:flutter/material.dart';

import '../data/book_catalog_rebuild.dart';

Future<List<String>?> showChapterRebuildRules(
  BuildContext context,
  List<String> rules,
) => showDialog<List<String>>(
  context: context,
  builder: (_) => _ChapterRebuildRules(rules),
);

final class _ChapterRebuildRules extends StatefulWidget {
  const _ChapterRebuildRules(this.rules);

  final List<String> rules;

  @override
  State<_ChapterRebuildRules> createState() => _ChapterRebuildRulesState();
}

final class _ChapterRebuildRulesState extends State<_ChapterRebuildRules> {
  late final _rules = TextEditingController(text: widget.rules.join('\n'));

  @override
  void dispose() {
    _rules.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('重建离线章节目录'),
    scrollable: true,
    content: SizedBox(
      width: 450,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('按原目录顺序合并完整正文。每行填写一个正则表达式，整行匹配任一规则即开始新章。'),
          const SizedBox(height: 12),
          TextField(
            controller: _rules,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: '分章规则',
              helperText: r'例如 第\d+章.* 或 Chapter\s+\d+.*',
              border: OutlineInputBorder(),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '选择分章方案',
            onSelected: (value) => _rules.text = value,
            itemBuilder: (_) => const [
              PopupMenuItem(value: defaultChapterRule, child: Text('中文章节')),
              PopupMenuItem(
                value: r'(?:Chapter|Part|Book)\s+[0-9IVXLCDM]+(?:\b.*)?',
                child: Text('英文章节'),
              ),
              PopupMenuItem(
                value: r'[0-9０-９]+[.、．]\s*\S.*',
                child: Text('数字编号'),
              ),
            ],
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('使用预设规则'),
            ),
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
        onPressed: () => Navigator.pop(context, [
          for (final line in _rules.text.split('\n'))
            if (line.trim().isNotEmpty) line.trim(),
        ]),
        child: const Text('重建目录'),
      ),
    ],
  );
}
