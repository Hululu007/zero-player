import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:fwfh_svg/fwfh_svg.dart';

import '../domain/reading_mark.dart';
import 'epub_source.dart';
import 'reading_mark_span.dart';
import 'reader_curl.dart';
import 'reader_style.dart';

class EpubHtmlViewport extends StatefulWidget {
  const EpubHtmlViewport({
    super.key,
    required this.source,
    required this.preferences,
    required this.palette,
    required this.sourceOffset,
    this.marks = const [],
    required this.legacyPixels,
    required this.initialFraction,
    required this.onProgress,
    required this.onBoundary,
    required this.onLink,
    required this.onSelectionChanged,
    required this.selectionMenu,
  });

  final EpubSource source;
  final ReaderPreferences preferences;
  final ReaderPalette palette;
  final int? sourceOffset;
  final List<ReadingMark> marks;
  final double? legacyPixels;
  final double initialFraction;
  final void Function(int? sourceOffset, double pixels, double fraction)
  onProgress;
  final ValueChanged<int> onBoundary;
  final bool Function(String) onLink;
  final ValueChanged<String> onSelectionChanged;
  final Widget Function(BuildContext, SelectableRegionState) selectionMenu;

  @override
  State<EpubHtmlViewport> createState() => EpubHtmlViewportState();
}

class EpubHtmlViewportState extends State<EpubHtmlViewport>
    with SingleTickerProviderStateMixin {
  final _scroll = ScrollController(keepScrollOffset: false);
  final _curl = GlobalKey<ReaderCurlState>();
  final _contentKey = GlobalKey();
  final _spans = ReadingMarkSpans();

  ReadingRange? get selectedRange => _spans.selectedRange();
  late final _slide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1,
  );
  int _direction = 1;
  double _drag = 0, _edgeDrag = 0;
  bool _atStart = false, _atEnd = false;
  bool _restoring = true, _scheduled = false, _contentPending = false;
  int? _stableOffset;
  bool _useRequestedPosition = true;
  Size? _size;
  String _selection = '';

  bool get _scrolling => widget.preferences.mode == ReaderTurnMode.scroll;
  bool get _hasLayout =>
      _scroll.hasClients && _scroll.position.hasContentDimensions;
  double get _step => math.max(1, _scroll.position.viewportDimension - 30);

  @override
  void didUpdateWidget(covariant EpubHtmlViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    _spans.marks.value = widget.marks;
    if (oldWidget.preferences != widget.preferences ||
        oldWidget.sourceOffset != widget.sourceOffset ||
        oldWidget.initialFraction != widget.initialFraction) {
      // The parent only changes these fields for an explicit relayout or jump.
      _restoring = true;
      _useRequestedPosition = true;
      _slide.value = 1;
    }
  }

  void _scheduleRestore() {
    if (!_restoring || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || !_restoring || !_hasLayout || _contentPending) return;
      final anchor = _useRequestedPosition
          ? widget.sourceOffset
          : _stableOffset;
      _useRequestedPosition = false;
      final position = _scroll.position;
      final pixels =
          (anchor == null ? null : _pixelsFor(anchor)) ??
          widget.legacyPixels ??
          (position.maxScrollExtent * widget.initialFraction);
      _scroll.jumpTo(pixels.clamp(0.0, position.maxScrollExtent));
      _restoring = false;
      _publish(preserve: anchor);
    });
  }

  void _publish({int? preserve}) {
    if (_restoring || !_hasLayout) return;
    final position = _scroll.position;
    _stableOffset = preserve ?? _sourceAt(position.pixels);
    widget.onProgress(
      _stableOffset,
      position.pixels,
      position.maxScrollExtent == 0
          ? 0
          : position.pixels / position.maxScrollExtent,
    );
  }

  double _top(ReadingMarkBox box) {
    // Code and tables can have their own horizontal viewport. Always measure
    // relative to the chapter viewport.
    final viewport = _contentKey.currentContext?.findRenderObject();
    return box.localToGlobal(Offset.zero, ancestor: viewport).dy +
        _scroll.offset;
  }

  int? _sourceAt(double pixels) {
    ReadingMarkBox? nearest;
    var nearestTop = double.infinity;
    var nearestDistance = double.infinity;
    for (final box in _spans.boxes) {
      if (!box.hasSize || box.size.isEmpty) continue;
      final top = _top(box);
      final distance = pixels < top
          ? top - pixels
          : math.max(0.0, pixels - top - box.size.height);
      if (distance > nearestDistance ||
          (distance == nearestDistance && top >= nearestTop)) {
        continue;
      }
      nearest = box;
      nearestTop = top;
      nearestDistance = distance;
    }
    if (nearest == null) return null;
    final paragraph = nearest.child;
    if (paragraph is! RenderParagraph) return nearest.start;
    // Use a point inside the first visible line, then locate that line's start.
    final y = (pixels - nearestTop + 2).clamp(0.0, nearest.size.height);
    final position = paragraph.getPositionForOffset(Offset(0, y));
    return (nearest.start + position.offset).clamp(nearest.start, nearest.end);
  }

  double? _pixelsFor(int sourceOffset) {
    ReadingMarkBox? nearest;
    var distance = double.infinity;
    for (final box in _spans.boxes) {
      if (!box.hasSize || box.size.isEmpty) continue;
      final gap = sourceOffset < box.start
          ? box.start - sourceOffset
          : math.max(0, sourceOffset - box.end + 1);
      if (gap < distance ||
          (gap == distance &&
              nearest != null &&
              box.end - box.start < nearest.end - nearest.start)) {
        nearest = box;
        distance = gap.toDouble();
      }
    }
    if (nearest == null) return null;
    final top = _top(nearest);
    final paragraph = nearest.child;
    if (paragraph is! RenderParagraph) return top;
    final caret = paragraph.getOffsetForCaret(
      TextPosition(
        offset: (sourceOffset - nearest.start).clamp(
          0,
          nearest.end - nearest.start,
        ),
      ),
      Rect.zero,
    );
    return top + caret.dy;
  }

  bool _canMove(int direction) =>
      _hasLayout &&
      (direction < 0
          ? _scroll.offset > 1
          : _scroll.offset < _scroll.position.maxScrollExtent - 1);

  double _target(int direction) => (_scroll.offset + _step * direction).clamp(
    0.0,
    _scroll.position.maxScrollExtent,
  );

  void turn(int direction) {
    if (!_hasLayout || _restoring) return;
    final curl = _curl.currentState;
    if (_canMove(direction) && curl != null) {
      curl.turn(direction);
      return;
    }
    _commitTurn(direction);
  }

  void _commitTurn(int direction) {
    if (!_canMove(direction)) {
      widget.onBoundary(direction);
      return;
    }
    final target = _target(direction);
    final prefs = widget.preferences;
    if (prefs.animate && !prefs.mode.horizontal) {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scroll.jumpTo(target);
      if (prefs.mode == ReaderTurnMode.slide && prefs.animate) {
        _direction = direction;
        _slide.forward(from: 0);
      }
    }
  }

  void advance(double delta) {
    if (!_hasLayout || _restoring) return;
    if (!_canMove(1)) {
      widget.onBoundary(1);
      return;
    }
    final position = _scroll.position;
    position.jumpTo(
      math.min(position.maxScrollExtent, position.pixels + delta),
    );
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 || _restoring || !_scrolling) return false;
    final metrics = notification.metrics;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _atStart = metrics.pixels <= metrics.minScrollExtent + 1;
      _atEnd = metrics.pixels >= metrics.maxScrollExtent - 1;
      _edgeDrag = 0;
    } else if (notification is OverscrollNotification &&
        notification.dragDetails != null) {
      if ((notification.overscroll < 0 && _atStart) ||
          (notification.overscroll > 0 && _atEnd)) {
        _edgeDrag += notification.overscroll;
      }
    } else if (notification is ScrollEndNotification) {
      final distance = _edgeDrag;
      _edgeDrag = 0;
      if (distance.abs() >= 42) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scrolling) widget.onBoundary(distance > 0 ? 1 : -1);
        });
      }
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _slide;
    _spans.marks.value = widget.marks;
    _scroll.addListener(_publish);
  }

  @override
  void dispose() {
    _slide.dispose();
    _spans.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SelectionArea(
    onSelectionChanged: (selection) {
      _selection = selection?.plainText ?? '';
      widget.onSelectionChanged(_selection);
    },
    contextMenuBuilder: widget.selectionMenu,
    child: ClipRect(child: _viewport()),
  );

  Widget _viewport() => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      if (_size != size) {
        _restoring = true;
        _size = size;
      }
      _scheduleRestore();
      final content = NotificationListener<ScrollMetricsNotification>(
        key: _contentKey,
        onNotification: (_) {
          _scheduleRestore();
          return false;
        },
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: _content(),
        ),
      );
      final prefs = widget.preferences;
      if (_scrolling) return content;
      if (prefs.mode == ReaderTurnMode.curl) {
        return ReaderCurl(
          key: _curl,
          paper: widget.palette.paper,
          background: ReaderPaperSurface(
            palette: widget.palette,
            texture: prefs.texture,
          ),
          animate: prefs.animate,
          page: 0,
          canTurn: (direction) => _selection.isEmpty && _canMove(direction),
          onTurn: _commitTurn,
          onBoundary: (direction) {
            if (_selection.isEmpty) widget.onBoundary(direction);
          },
          pageBuilder: (page, selectable) =>
              selectable ? content : _content(previewOffset: _target(page)),
        );
      }
      final horizontal = prefs.mode.horizontal;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        supportedDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
          PointerDeviceKind.trackpad,
        },
        onHorizontalDragStart: horizontal ? (_) => _drag = 0 : null,
        onHorizontalDragUpdate: horizontal
            ? (details) => _drag += details.primaryDelta ?? 0
            : null,
        onHorizontalDragEnd: horizontal ? _finishDrag : null,
        onVerticalDragStart: horizontal ? null : (_) => _drag = 0,
        onVerticalDragUpdate: horizontal
            ? null
            : (details) => _drag += details.primaryDelta ?? 0,
        onVerticalDragEnd: horizontal ? null : _finishDrag,
        child: !horizontal
            ? content
            : AnimatedBuilder(
                animation: _slide,
                child: content,
                builder: (_, child) => FractionalTranslation(
                  translation: Offset(
                    _direction *
                        (1 - Curves.easeOutCubic.transform(_slide.value)),
                    0,
                  ),
                  child: child,
                ),
              ),
      );
    },
  );

  void _finishDrag(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final delta = velocity.abs() >= 420 ? velocity : _drag;
    if (_selection.isEmpty && (delta.abs() >= 42)) turn(delta < 0 ? 1 : -1);
  }

  Widget _content({double? previewOffset}) {
    final preview = previewOffset != null;
    final prefs = widget.preferences;
    final html = HtmlWidget(
      widget.source.htmlContent,
      factoryBuilder: () => _EpubFactory(
        widget.source,
        preview ? null : _spans,
        preview
            ? null
            : () {
                _contentPending = false;
                _scheduleRestore();
              },
      ),
      onLoadingBuilder: (_, element, _) {
        if (element.localName != 'root') return null;
        if (!preview) _contentPending = true;
        return const SizedBox(
          height: 80,
          child: Center(child: CircularProgressIndicator()),
        );
      },
      onErrorBuilder: (_, element, _) {
        if (element.localName != 'root') return null;
        if (!preview) {
          _contentPending = false;
          _scheduleRestore();
        }
        return const Text('无法显示此节内容');
      },
      rebuildTriggers: [prefs.justify],
      textStyle: prefs.bodyStyle.copyWith(color: widget.palette.ink),
      onTapUrl: widget.onLink,
      customStylesBuilder: (element) => switch (element.localName) {
        'pre' => {
          'white-space': 'pre',
          'overflow': 'auto',
          'font-family': 'monospace',
        },
        'img' => {'vertical-align': 'bottom'},
        'div'
            when element.text.trim().isEmpty &&
                element.querySelector('img') != null =>
          {'vertical-align': 'bottom'},
        'div' when element.parent?.localName == 'body' && prefs.justify => {
          'text-align': 'justify',
        },
        _ => null,
      },
    );
    final padding = EdgeInsets.fromLTRB(prefs.margin, 8, prefs.margin, 22);
    if (preview) {
      return ClipRect(
        child: OverflowBox(
          alignment: Alignment.topCenter,
          maxHeight: double.infinity,
          child: Transform.translate(
            offset: Offset(0, -previewOffset),
            child: Padding(
              padding: padding,
              child: SelectionContainer.disabled(child: html),
            ),
          ),
        ),
      );
    }
    return SingleChildScrollView(
      controller: _scroll,
      physics: _scrolling
          ? const ClampingScrollPhysics(parent: AlwaysScrollableScrollPhysics())
          : const NeverScrollableScrollPhysics(),
      padding: padding,
      child: html,
    );
  }
}

final class _EpubFactory extends WidgetFactory with SvgFactory {
  _EpubFactory(this.source, this.anchors, this.onContent);
  final EpubSource source;
  final ReadingMarkSpans? anchors;
  final VoidCallback? onContent;

  @override
  Widget buildBodyWidget(BuildContext context, Widget child) {
    onContent?.call();
    return super.buildBodyWidget(context, child);
  }

  @override
  Widget? buildImage(BuildTree tree, ImageMetadata data) {
    final child = super.buildImage(tree, data);
    final start = epubElementStart(tree.element);
    if (child == null || anchors == null || start == null) return child;
    return ReadingMarkSpan(anchors!, start, start + 1, child);
  }

  @override
  Widget? buildText(
    BuildTree tree,
    InheritedProperties resolved,
    InlineSpan text,
  ) {
    final child = super.buildText(tree, resolved, text);
    final plain = text.toPlainText(includeSemanticsLabels: false);
    final start = source.textStart(tree.element, plain);
    if (child == null || anchors == null || start == null) return child;
    return ReadingMarkSpan(
      anchors!,
      start,
      math.min(start + plain.length, source.text.length),
      child,
    );
  }
}
