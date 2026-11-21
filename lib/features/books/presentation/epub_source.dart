import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

const epubStartAttribute = 'data-zero-player-start';
const epubEndAttribute = 'data-zero-player-end';

/// Coordinates refer to normalized text from the sanitized spine document.
final class EpubSource {
  EpubSource(String markup) {
    final fragment = html.parseFragment(markup);
    final buffer = StringBuffer();

    void visit(dom.Node node) {
      if (node is dom.Text) {
        final parent = node.parentNode;
        if (parent == null) return;
        final text = node.text.replaceAll(_space, ' ');
        if (text.trim().isNotEmpty) {
          final span = dom.Element.tag('span')
            ..attributes[epubStartAttribute] = buffer.length.toString()
            ..attributes[epubEndAttribute] = (buffer.length + text.length)
                .toString()
            ..text = node.text;
          parent.insertBefore(span, node);
          node.remove();
        }
        buffer.write(text);
        return;
      }
      if (node is! dom.Element) return;
      final start = buffer.length;
      if (node.localName == 'img' || node.localName == 'br') {
        buffer.write('\uFFFC');
      }
      for (final child in node.nodes.toList()) {
        visit(child);
      }
      node.attributes[epubStartAttribute] = start.toString();
      node.attributes[epubEndAttribute] = buffer.length.toString();
      final id = node.id.isNotEmpty ? node.id : node.attributes['name'];
      if (id != null) destinations.putIfAbsent(id, () => start);
    }

    for (final node in fragment.nodes.toList()) {
      visit(node);
    }
    text = buffer.toString();
    htmlContent = fragment.outerHtml;
  }

  static final _space = RegExp(r'\s+');
  late final String text;
  late final String htmlContent;
  final destinations = <String, int>{};

  int? textStart(dom.Element element, String rendered) {
    final start = epubElementStart(element);
    final end = int.tryParse(element.attributes[epubEndAttribute] ?? '');
    if (start == null || end == null || end <= start || end > text.length) {
      return null;
    }
    final visible = rendered.replaceAll(_space, ' ').trim();
    if (visible.isEmpty) return null;
    final first = text.substring(start, end).indexOf(visible);
    return first == -1
        ? start
        : (start + first - (rendered.length - rendered.trimLeft().length))
              .clamp(start, end);
  }
}

int? epubElementStart(dom.Element? element) =>
    int.tryParse(element?.attributes[epubStartAttribute] ?? '');
