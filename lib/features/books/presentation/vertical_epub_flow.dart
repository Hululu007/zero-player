import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import '../data/epub_styles.dart';
import 'epub_source.dart';

/// A glyph, paragraph boundary, or an intact illustration/technical block.
class VerticalItem {
  const VerticalItem(
    this.text,
    this.style, {
    this.ruby = '',
    this.html,
    this.offset = 0,
    this.url,
  });
  final String text, ruby;
  final TextStyle style;
  final String? html, url;
  final int offset;
  double get extent => (style.fontSize ?? 21) * 1.25;
}

List<VerticalItem> verticalEpubItems(String source, TextStyle base) {
  final items = <VerticalItem>[];
  void boundary() {
    if (items.isNotEmpty && items.last.text != '\n') {
      items.add(VerticalItem('\n', base));
    }
  }

  void visit(dom.Node node, TextStyle inherited, String? url) {
    if (node is dom.Text) {
      final previous = items.lastOrNull;
      var offset = epubElementStart(node.parent) ?? 0;
      if (node.text.trim().isEmpty && previous != null) {
        offset = math.max(offset, previous.offset + previous.text.length);
      }
      for (final char in node.text.replaceAll(RegExp(r'\s+'), ' ').characters) {
        final start = offset;
        offset += char.length;
        if (char == ' ' && (items.isEmpty || items.last.text == '\n')) continue;
        items.add(VerticalItem(char, inherited, offset: start, url: url));
      }
      return;
    }
    if (node is! dom.Element) return;
    final tag = node.localName;
    if (['rt', 'rp', 'script', 'style'].contains(tag)) return;
    final style = _elementStyle(node, inherited);
    final target = tag == 'a' ? node.attributes['href'] : url;
    if (['img', 'figure', 'pre', 'table'].contains(tag)) {
      boundary();
      items.add(
        VerticalItem(
          '',
          style,
          html: node.outerHtml,
          offset: epubElementStart(node) ?? 0,
        ),
      );
      return;
    }
    if (tag == 'ruby') {
      _rubyItems(node, style, items, target);
      return;
    }
    final block = ['p', 'div', 'section', 'h1', 'h2', 'h3', 'li', 'blockquote'];
    if (block.contains(tag) || tag == 'br') boundary();
    for (final child in node.nodes) {
      visit(child, style, target);
    }
    if (block.contains(tag)) boundary();
  }

  for (final node in html.parseFragment(source).nodes) {
    visit(node, base, null);
  }
  return items;
}

void _rubyItems(
  dom.Element node,
  TextStyle style,
  List<VerticalItem> items,
  String? url,
) {
  // Each rt annotates the preceding base group, including EPUB rb/rt pairs.
  var pending = StringBuffer();
  var offset = epubElementStart(node) ?? 0;
  void flush(String annotation) {
    final bases = pending.toString().characters.toList();
    final notes = annotation.characters.toList();
    for (var i = 0; i < bases.length; i++) {
      final start = (i * notes.length / bases.length).floor();
      final end = ((i + 1) * notes.length / bases.length).floor();
      items.add(
        VerticalItem(
          bases[i],
          style,
          ruby: notes.sublist(start, end).join(),
          offset: offset,
          url: url,
        ),
      );
      offset += bases[i].length;
    }
    pending = StringBuffer();
  }

  for (final child in node.nodes) {
    if (child is dom.Element && child.localName == 'rp') continue;
    if (child is dom.Element && child.localName == 'rt') {
      flush(child.text);
    } else {
      if (pending.isEmpty && child is dom.Element) {
        offset = epubElementStart(child) ?? offset;
      }
      pending.write(child.text);
    }
  }
  flush('');
}

TextStyle _elementStyle(dom.Element node, TextStyle base) {
  final css = safeDeclarations(node.attributes['style'] ?? '');
  final tag = node.localName;
  final bold =
      ['b', 'strong', 'h1', 'h2', 'h3'].contains(tag) ||
      ['bold', '700', '800', '900'].contains(css['font-weight']);
  final italic = ['i', 'em'].contains(tag) || css['font-style'] == 'italic';
  final color = css['color'];
  Color? ink;
  if (color != null && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(color)) {
    ink = Color(0xff000000 | int.parse(color.substring(1), radix: 16));
  }
  final size = css['font-size'] ?? '';
  final number = double.tryParse(size.replaceAll(RegExp('[^0-9.]'), ''));
  final font = number == null
      ? base.fontSize
      : size.endsWith('em')
      ? number * (base.fontSize ?? 21)
      : size.endsWith('%')
      ? number * (base.fontSize ?? 21) / 100
      : number;
  return base.copyWith(
    fontWeight: bold ? FontWeight.bold : null,
    fontStyle: italic ? FontStyle.italic : null,
    fontSize: font?.clamp(10, 48),
    color: ink,
  );
}

typedef VerticalColumn = ({List<VerticalItem> items, double width});
typedef VerticalPage = ({
  List<VerticalColumn> columns,
  String? html,
  int offset,
});

List<VerticalPage> paginateVertical(List<VerticalItem> items, Size size) {
  final pages = <VerticalPage>[];
  var columns = <VerticalColumn>[];
  var column = <VerticalItem>[];
  double usedWidth = 0, usedHeight = 0, width = 0;
  void flushPage() {
    if (columns.isEmpty) return;
    pages.add((
      columns: columns,
      html: null,
      offset: columns.first.items.first.offset,
    ));
    columns = [];
    usedWidth = 0;
  }

  void flushColumn() {
    if (column.isEmpty) return;
    if (usedWidth + width > size.width && columns.isNotEmpty) flushPage();
    columns.add((items: column, width: math.min(width, size.width)));
    usedWidth += width;
    column = [];
    usedHeight = 0;
    width = 0;
  }

  for (final item in items) {
    if (item.html != null) {
      flushColumn();
      flushPage();
      pages.add((columns: [], html: item.html, offset: item.offset));
    } else if (item.text == '\n') {
      flushColumn();
    } else {
      if (usedHeight + item.extent > size.height) flushColumn();
      column.add(item);
      usedHeight += item.extent;
      width = math.max(width, (item.style.fontSize ?? 21) * 1.8);
    }
  }
  flushColumn();
  flushPage();
  return pages.isEmpty ? [(columns: [], html: null, offset: 0)] : pages;
}
