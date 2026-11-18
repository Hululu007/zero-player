import 'package:flutter/material.dart';

/// Reports only generic reasons and directory positions, never source titles,
/// body snippets or matched tokens. Sensitive review is a separate action.
Future<void> showBlockedChaptersDialog(
  BuildContext context, {
  required List<({int position, String reason, VoidCallback review})> chapters,
  required VoidCallback replacements,
}) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text('过滤跳过 ${chapters.length} 章'),
    content: SizedBox(
      width: 480,
      height: MediaQuery.sizeOf(context).height * .45,
      child: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('正常章节继续下载。替换或复核后可续传，已成功的章节会自动跳过。点击章节可验证复核。'),
            ),
          ),
          SliverList.builder(
            itemCount: chapters.length,
            itemBuilder: (context, index) {
              final chapter = chapters[index];
              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('目录第 ${chapter.position} 章'),
                subtitle: Text(chapter.reason),
                onTap: chapter.review,
                trailing: const Icon(Icons.chevron_right),
              );
            },
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: replacements, child: const Text('设置文本替换')),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  ),
);
