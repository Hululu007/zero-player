import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:fwfh_svg/fwfh_svg.dart';
import '../domain/reading_mark.dart';
import 'reader_curl.dart';
import 'reading_mark_span.dart';
import 'reader_style.dart';
import 'vertical_epub_flow.dart';

/// Upright CJK columns flowing right to left, with intact mixed-content pages.
class VerticalBookText extends StatefulWidget {
  const VerticalBookText({
    super.key,
    required this.text,
    this.html,
    required this.style,
    required this.onBoundary,
    this.initialPage = 0,
    this.onPageChanged,
    this.onProgress,
    this.sourceOffset,
    this.initialFraction = 0,
    this.onTapUrl,
    this.mode = ReaderTurnMode.slide,
    this.palette,
    this.animate = true,
    this.marks = const [],
    this.selectionMenu,
    this.onSelectionChanged,
  });
  final String text;
  final String? html;
  final TextStyle style;
  final ValueChanged<int> onBoundary;
  final int initialPage;
  final ValueChanged<int>? onPageChanged;
  final int? sourceOffset;
  final double initialFraction;
  final void Function(int page, int sourceOffset, double fraction)? onProgress;
  final bool Function(String)? onTapUrl;
  final ReaderTurnMode mode;
  final ReaderPalette? palette;
  final bool animate;
  final List<ReadingMark> marks;
  final Widget Function(BuildContext, SelectableRegionState)? selectionMenu;
  final ValueChanged<String>? onSelectionChanged;
  @override
  State<VerticalBookText> createState() => VerticalBookTextState();
}

class VerticalBookTextState extends State<VerticalBookText> {
  late final _pages = PageController(
    initialPage: widget.initialPage,
    keepPage: false,
  );
  late int _index = widget.initialPage;
  List<VerticalPage>? _layout;
  Size? _size;
  final _curl = GlobalKey<ReaderCurlState>();
  final _spans = ReadingMarkSpans();

  ReadingRange? get selectedRange => _spans.selectedRange();

  @override
  void initState() {
    super.initState();
    _spans.marks.value = widget.marks;
  }

  double _edgeDrag = 0;
  int? _stableOffset;
  bool _restoring = true;
  bool _useRequestedPosition = true;

  bool _canTurn(int direction) {
    final next = _index + direction;
    return next >= 0 && next < (_layout?.length ?? 1);
  }

  void turn(int direction) {
    if (_restoring) return;
    if (!_canTurn(direction)) {
      widget.onBoundary(direction);
      return;
    }
    if (_curl.currentState case final curl?) {
      curl.turn(-direction);
    } else if (_pages.hasClients && widget.animate) {
      _pages.animateToPage(
        _index + direction,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    } else if (_pages.hasClients) {
      _pages.jumpToPage(_index + direction);
    }
  }

  void _report(int page, {int? preserve}) {
    _index = page;
    final layout = _layout!;
    _stableOffset = preserve ?? layout[page].offset;
    widget.onPageChanged?.call(page);
    widget.onProgress?.call(
      page,
      _stableOffset!,
      layout.length < 2 ? 0 : page / (layout.length - 1),
    );
  }

  @override
  void didUpdateWidget(covariant VerticalBookText oldWidget) {
    super.didUpdateWidget(oldWidget);
    _spans.marks.value = widget.marks;
    if (oldWidget.text != widget.text ||
        oldWidget.html != widget.html ||
        oldWidget.style != widget.style) {
      _layout = null;
    }
    if (_layout == null ||
        oldWidget.mode != widget.mode ||
        oldWidget.sourceOffset != widget.sourceOffset ||
        oldWidget.initialFraction != widget.initialFraction) {
      _restoring = true;
      _useRequestedPosition =
          widget.sourceOffset != null ||
          oldWidget.initialFraction != widget.initialFraction;
    }
  }

  @override
  void dispose() {
    _spans.dispose();
    _pages.dispose();
    super.dispose();
  }

  void _restore(List<VerticalPage> layout) {
    final anchor = _useRequestedPosition ? widget.sourceOffset : _stableOffset;
    final int page;
    if (anchor != null) {
      page = layout
          .lastIndexWhere((page) => page.offset <= anchor)
          .clamp(0, layout.length - 1);
    } else if (widget.initialFraction > 0) {
      page = (widget.initialFraction * (layout.length - 1)).round();
    } else {
      page = _index.clamp(0, layout.length - 1);
    }
    _index = page;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _layout != layout || !_restoring) return;
      if (_pages.hasClients) _pages.jumpToPage(page);
      _restoring = false;
      _useRequestedPosition = false;
      _report(page, preserve: anchor);
    });
  }

  bool _scrollNotification(ScrollNotification notification) {
    if (notification.depth != 0 || _restoring) return false;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _edgeDrag = 0;
    } else if (notification is OverscrollNotification &&
        notification.dragDetails != null) {
      _edgeDrag += notification.overscroll;
    } else if (notification is ScrollEndNotification && _edgeDrag.abs() >= 42) {
      final direction = _edgeDrag > 0 ? 1 : -1;
      _edgeDrag = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_canTurn(direction)) widget.onBoundary(direction);
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final layout = _view();
    final onSelectionChanged = widget.onSelectionChanged;
    return onSelectionChanged == null
        ? layout
        : SelectionArea(
            onSelectionChanged: (selection) =>
                onSelectionChanged(selection?.plainText ?? ''),
            contextMenuBuilder: widget.selectionMenu,
            child: layout,
          );
  }

  Widget _view() => LayoutBuilder(
    builder: (context, c) {
      final size = Size(c.maxWidth, c.maxHeight);
      if (_layout == null || _size != size) {
        _size = size;
        _restoring = true;
        _layout = paginateVertical(
          verticalEpubItems(
            widget.html ??
                '<p>${htmlEscape.convert(widget.text).replaceAll('\n', '<br>')}</p>',
            widget.style,
          ),
          size,
        );
      }
      final layout = _layout!;
      if (_restoring) _restore(layout);
      final palette = widget.palette;
      if (widget.mode == ReaderTurnMode.curl && palette != null) {
        return ReaderCurl(
          key: _curl,
          paper: palette.paper,
          background: ColoredBox(color: palette.paper),
          animate: widget.animate,
          page: -_index,
          canTurn: (direction) => _canTurn(-direction),
          onTurn: (direction) => setState(() => _report(_index - direction)),
          onBoundary: (direction) => widget.onBoundary(-direction),
          pageBuilder: (page, interactive) {
            final content = _page(layout[-page]);
            return interactive
                ? content
                : SelectionContainer.disabled(child: content);
          },
        );
      }
      return NotificationListener<ScrollNotification>(
        onNotification: _scrollNotification,
        child: PageView.builder(
          controller: _pages,
          reverse: widget.mode.horizontal,
          scrollDirection: widget.mode.horizontal
              ? Axis.horizontal
              : Axis.vertical,
          pageSnapping: widget.mode != ReaderTurnMode.scroll,
          physics: const ClampingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          itemCount: layout.length,
          onPageChanged: (i) {
            if (!_restoring) _report(i);
          },
          itemBuilder: (_, page) => _page(layout[page]),
        ),
      );
    },
  );

  Widget _page(VerticalPage page) {
    if (page.html != null) {
      return SingleChildScrollView(
        child: HtmlWidget(
          page.html!,
          factoryBuilder: () => _VerticalFactory(),
          textStyle: widget.style,
          onTapUrl: widget.onTapUrl ?? ((_) => true),
          customStylesBuilder: (e) => e.localName == 'pre'
              ? {
                  'white-space': 'pre',
                  'overflow': 'auto',
                  'font-family': 'monospace',
                }
              : null,
        ),
      );
    }
    return Row(
      textDirection: TextDirection.rtl,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final col in page.columns)
          SizedBox(
            width: col.width,
            child: Column(
              children: [for (final item in col.items) _glyph(item)],
            ),
          ),
      ],
    );
  }

  Widget _glyph(VerticalItem item) {
    const punctuation = {
      '，': '︐',
      '。': '︒',
      '、': '︑',
      '：': '︓',
      '；': '︔',
      '（': '︵',
      '）': '︶',
      '「': '﹁',
      '」': '﹂',
      '『': '﹃',
      '』': '﹄',
    };
    final glyph = SizedBox(
      width: double.infinity,
      height: item.extent,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          SizedBox(
            width: (item.style.fontSize ?? 21) * 1.25,
            child: Center(
              child: ReadingMarkSpan(
                _spans,
                item.offset,
                item.offset + item.text.length,
                Text(
                  punctuation[item.text] ?? item.text,
                  style: item.style.copyWith(height: 1),
                  semanticsLabel: punctuation.containsKey(item.text)
                      ? item.text
                      : null,
                ),
                vertical: true,
              ),
            ),
          ),
          if (item.ruby.isNotEmpty)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: SizedBox(
                width: (item.style.fontSize ?? 21) * .45,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SelectionContainer.disabled(
                    child: Text(
                      item.ruby.characters.join('\n'),
                      textAlign: TextAlign.center,
                      style: item.style.copyWith(
                        fontSize: (item.style.fontSize ?? 21) * .45,
                        height: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    final url = item.url;
    return url == null || widget.onTapUrl == null
        ? glyph
        : GestureDetector(
            onTap: () => widget.onTapUrl!(url),
            child: Semantics(link: true, child: glyph),
          );
  }
}

class _VerticalFactory extends WidgetFactory with SvgFactory {}
