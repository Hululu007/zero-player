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
}) {
  var first = 1, last = total;
  var all = true, fallback = false, aggregateLatest = false;
  var space = initialSpace;
  String? listId;
  final lists = <BookShelfSpace, List<ShelfList>>{
    BookShelfSpace.public: publicLists,
    BookShelfSpace.private: privateLists,
  };
  return showDialog<BookDownloadSelection>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) {
        final available = lists[space] ?? const <ShelfList>[];
        if (listId != null && !available.any((item) => item.id == listId)) {
          listId = null;
        }
        return AlertDialog(
          title: const Text('离线下载'),
          scrollable: true,
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('全本')),
                    ButtonSegment(value: false, label: Text('指定区间')),
                  ],
                  selected: {all},
                  onSelectionChanged: (values) =>
                      update(() => all = values.single),
                ),
                const SizedBox(height: 12),
                if (!all)
                  Row(
                    children: [
                      Expanded(
                        child: _chapterNumber(
                          '起始章节',
                          first,
                          (value) => update(() => first = value),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _chapterNumber(
                          '结束章节',
                          last,
                          (value) => update(() => last = value),
                        ),
                      ),
                    ],
                  ),
                Text('共 $total 章，自动跳过已下载章节'),
                if (all && allowAggregateLatest)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('聚合最新'),
                    subtitle: const Text('自动从同名同作者的其他渠道补充后续章节'),
                    value: aggregateLatest,
                    onChanged: (value) => update(() => aggregateLatest = value),
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('失败时尝试其他书源'),
                  subtitle: const Text('只下载同名同作者且章节唯一对应的版本'),
                  value: fallback,
                  onChanged: (value) => update(() => fallback = value),
                ),
                const Divider(),
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
                  selected: {space},
                  showSelectedIcon: false,
                  onSelectionChanged: (values) => update(() {
                    space = values.single;
                    listId = null;
                  }),
                ),
                const SizedBox(height: 8),
                if (space == BookShelfSpace.private && privateLists.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 6),
                    child: Text(
                      '私密书架尚未解锁或还没有书单；开始下载前会先验证。',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                InputDecorator(
                  decoration: const InputDecoration(labelText: '书单'),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String?>(
                      isExpanded: true,
                      value: listId,
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('未分类（仅书架空间）'),
                        ),
                        for (final list in available)
                          DropdownMenuItem<String?>(
                            value: list.id,
                            child: Text(
                              '${list.kind == ShelfListKind.group
                                  ? '分组'
                                  : list.kind == ShelfListKind.collection
                                  ? '集合'
                                  : '书单'} · ${list.name}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) => update(() => listId = value),
                    ),
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
              onPressed: all || (first >= 1 && last >= first && last <= total)
                  ? () => Navigator.pop(
                      context,
                      BookDownloadSelection(
                        BookDownloadPlan(
                          all ? 1 : first,
                          all ? total : last,
                          fallback,
                          fullBook: all,
                          aggregateLatest:
                              all && allowAggregateLatest && aggregateLatest,
                        ),
                        BookDownloadTarget(
                          space,
                          listId: listId,
                          listName: available
                              .where((item) => item.id == listId)
                              .firstOrNull
                              ?.name,
                        ),
                      ),
                    )
                  : null,
              child: const Text('开始下载'),
            ),
          ],
        );
      },
    ),
  );
}

Widget _chapterNumber(String label, int initial, ValueChanged<int> onChange) =>
    TextFormField(
      initialValue: '$initial',
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(labelText: label),
      onChanged: (value) => onChange(int.tryParse(value) ?? 0),
    );
