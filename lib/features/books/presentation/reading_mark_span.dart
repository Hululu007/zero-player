import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../domain/reading_mark.dart';
import 'reading_mark_tools.dart';

final class ReadingMarkSpans {
  final boxes = <ReadingMarkBox>{};
  final marks = ValueNotifier<List<ReadingMark>>(const []);

  ReadingRange? selectedRange() {
    int? start, end;
    for (final box in boxes) {
      final selection = box.selected;
      if (selection == null) continue;
      final origin =
          box.start +
          math.min(selection.startOffset, selection.endOffset).toInt();
      final limit =
          box.start +
          math.max(selection.startOffset, selection.endOffset).toInt();
      if (origin < box.start || limit > box.end || limit <= origin) continue;
      start = start == null ? origin : math.min(start, origin);
      end = end == null ? limit : math.max(end, limit);
    }
    return start == null || end == null ? null : (start: start, end: end);
  }

  void dispose() => marks.dispose();
}

class ReadingMarkSpan extends StatefulWidget {
  const ReadingMarkSpan(
    this.spans,
    this.start,
    this.end,
    this.child, {
    super.key,
    this.vertical = false,
  });

  final ReadingMarkSpans spans;
  final int start, end;
  final Widget child;
  final bool vertical;

  @override
  State<ReadingMarkSpan> createState() => _ReadingMarkSpanState();
}

class _ReadingMarkSpanState extends State<ReadingMarkSpan> {
  final _selection = SelectionListenerNotifier();

  @override
  Widget build(BuildContext context) => SelectionListener(
    selectionNotifier: _selection,
    child: _MarkBox(
      widget.spans,
      widget.start,
      widget.end,
      _selection,
      widget.vertical,
      child: widget.child,
    ),
  );

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }
}

final class _MarkBox extends SingleChildRenderObjectWidget {
  const _MarkBox(
    this.spans,
    this.start,
    this.end,
    this.selection,
    this.vertical, {
    super.child,
  });
  final ReadingMarkSpans spans;
  final int start, end;
  final SelectionListenerNotifier selection;
  final bool vertical;

  @override
  ReadingMarkBox createRenderObject(BuildContext context) =>
      ReadingMarkBox(spans, start, end, selection, vertical);

  @override
  void updateRenderObject(BuildContext context, ReadingMarkBox renderObject) {
    assert(renderObject.spans == spans);
    renderObject
      ..start = start
      ..end = end
      ..vertical = vertical
      ..markNeedsPaint();
  }
}

final class ReadingMarkBox extends RenderProxyBox {
  ReadingMarkBox(
    this.spans,
    this.start,
    this.end,
    this.selection,
    this.vertical,
  );
  final ReadingMarkSpans spans;
  final SelectionListenerNotifier selection;
  int start, end;
  bool vertical;

  SelectedContentRange? get selected =>
      selection.registered &&
          selection.selection.status == SelectionStatus.uncollapsed
      ? selection.selection.range
      : null;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    spans.boxes.add(this);
    spans.marks.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    spans.marks.removeListener(markNeedsPaint);
    spans.boxes.remove(this);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final paragraph = child;
    final marks = spans.marks.value;
    if (paragraph is! RenderParagraph || marks.isEmpty) {
      super.paint(context, offset);
      return;
    }
    void draw(bool behind) {
      for (final mark in marks) {
        if ((mark.style == ReadingMarkStyle.highlight) != behind) continue;
        final from = math.max(start, mark.range.start);
        final to = math.min(end, mark.range.end);
        if (to <= from) continue;
        final boxes = paragraph.getBoxesForSelection(
          TextSelection(baseOffset: from - start, extentOffset: to - start),
        );
        for (final box in boxes) {
          paintReadingMark(
            context.canvas,
            box.toRect().shift(offset),
            mark,
            vertical: vertical,
          );
        }
      }
    }

    draw(true);
    super.paint(context, offset);
    draw(false);
  }
}
