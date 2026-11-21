import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/reading_mark.dart';

const readingMarkColors = [
  Color(0xffda9917),
  Color(0xffd04357),
  Color(0xff398755),
  Color(0xff407cd2),
  Color(0xff9461bf),
];
const _colorLabels = ['金色', '红色', '绿色', '蓝色', '紫色'];

Future<ReadingMark?> editReadingMark(
  BuildContext context,
  ReadingMark initial, {
  required Listenable policy,
  required bool Function() allowed,
}) => showModalBottomSheet<ReadingMark>(
  context: context,
  showDragHandle: true,
  useSafeArea: true,
  builder: (context) {
    var value = initial;
    return ListenableBuilder(
      listenable: policy,
      builder: (context, _) => !allowed()
          ? const SafeArea(child: ListTile(title: Text('内容策略已变更')))
          : StatefulBuilder(
              builder: (context, update) => SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        value.quote,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final style in ReadingMarkStyle.values)
                            ChoiceChip(
                              label: Text(style.label),
                              selected: value.style == style,
                              onSelected: (_) => update(
                                () => value = value.copyWith(style: style),
                              ),
                            ),
                        ],
                      ),
                      Wrap(
                        children: [
                          for (final (index, color)
                              in readingMarkColors.indexed)
                            IconButton(
                              tooltip: _colorLabels[index],
                              onPressed: () => update(
                                () => value = value.copyWith(color: index),
                              ),
                              icon: Icon(
                                value.color == index
                                    ? Icons.check_circle
                                    : Icons.circle,
                                color: color,
                              ),
                            ),
                        ],
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('关联书签'),
                        value: value.bookmark,
                        onChanged: (bookmark) => update(
                          () => value = value.copyWith(bookmark: bookmark),
                        ),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, value),
                        child: const Text('保存标注'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  },
);

Future<ReadingMark?> showReadingMarks(
  BuildContext context, {
  required List<ReadingMark> initial,
  required Future<void> Function(ReadingMark) save,
  required Future<void> Function(ReadingMark) delete,
  required String Function(ReadingMark) location,
  required Listenable policy,
  required bool Function() allowed,
}) => showModalBottomSheet<ReadingMark>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (context) {
    final marks = initial.toList();
    var saving = false;
    return StatefulBuilder(
      builder: (context, update) {
        Future<void> change(ReadingMark mark, {required bool remove}) async {
          if (saving || !allowed()) return;
          update(() => saving = true);
          try {
            await (remove ? delete(mark) : save(mark));
            if (context.mounted) {
              update(() {
                final index = marks.indexWhere(
                  (item) => item.identity == mark.identity,
                );
                if (remove) {
                  marks.removeAt(index);
                } else {
                  marks[index] = mark;
                }
              });
            }
          } on Exception {
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('无法保存标注变更')));
            }
          } finally {
            if (context.mounted) update(() => saving = false);
          }
        }

        return ListenableBuilder(
          listenable: policy,
          builder: (context, _) => FractionallySizedBox(
            heightFactor: .72,
            child: Column(
              children: [
                const ListTile(title: Text('标注与关联书签')),
                Expanded(
                  child: !allowed()
                      ? const Center(child: Text('内容策略已变更'))
                      : marks.isEmpty
                      ? const Center(child: Text('暂无标注'))
                      : ListView.builder(
                          itemCount: marks.length,
                          itemBuilder: (context, index) {
                            final mark = marks[index];
                            return ListTile(
                              leading: Icon(
                                mark.bookmark
                                    ? Icons.bookmark
                                    : Icons.format_underlined,
                                color: readingMarkColors[mark.color],
                              ),
                              title: Text(
                                mark.quote,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(location(mark)),
                              onTap: () => Navigator.pop(context, mark),
                              trailing: PopupMenuButton<String>(
                                tooltip: '标注操作',
                                enabled: !saving,
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                    value: 'edit',
                                    child: Text('修改标注'),
                                  ),
                                  PopupMenuItem(
                                    value: 'bookmark',
                                    child: Text(
                                      mark.bookmark ? '取消关联书签' : '关联书签',
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Text('删除标注'),
                                  ),
                                ],
                                onSelected: (action) async {
                                  if (!allowed()) return;
                                  if (action == 'edit') {
                                    final next = await editReadingMark(
                                      context,
                                      mark,
                                      policy: policy,
                                      allowed: allowed,
                                    );
                                    if (next != null && context.mounted) {
                                      await change(next, remove: false);
                                    }
                                  } else if (action == 'bookmark') {
                                    await change(
                                      mark.copyWith(bookmark: !mark.bookmark),
                                      remove: false,
                                    );
                                  } else {
                                    await change(mark, remove: true);
                                  }
                                },
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  },
);

void paintReadingMark(
  Canvas canvas,
  Rect rect,
  ReadingMark mark, {
  bool vertical = false,
}) {
  if (rect.isEmpty) return;
  final color = readingMarkColors[mark.color];
  final paint = Paint()
    ..color = color
    ..strokeWidth = 1.8;
  if (mark.style == ReadingMarkStyle.highlight) {
    canvas.drawRect(rect, paint..color = color.withValues(alpha: .30));
    return;
  }
  if (mark.style == ReadingMarkStyle.outline) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(.5), const Radius.circular(2)),
      paint..style = PaintingStyle.stroke,
    );
    return;
  }
  final extent = vertical ? rect.height : rect.width;
  Offset point(double distance, double shift) => vertical
      ? Offset(rect.right - 1 + shift, rect.top + distance)
      : Offset(rect.left + distance, rect.bottom - 1 + shift);
  if (mark.style == ReadingMarkStyle.underline) {
    canvas.drawLine(point(0, 0), point(extent, 0), paint);
    return;
  }
  final path = Path()
    ..addPolygon([
      for (var x = 0.0; x < extent; x++)
        point(x, math.sin(x * math.pi / 3) * 1.5),
    ], false);
  canvas.drawPath(path, paint..style = PaintingStyle.stroke);
}
