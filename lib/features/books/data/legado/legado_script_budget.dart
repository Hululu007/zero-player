import 'dart:convert';

import 'package:html/dom.dart' as dom;

/// Counts encoded data before materializing the corresponding JSON string.
/// The same budget can be shared by multiple selector results.
final class LegadoScriptBudget {
  LegadoScriptBudget([this.remaining = maxBytes]);

  static const int maxBytes = 8 * 1024 * 1024;
  static const int maxNodes = 65536;
  static const int maxDepth = 256;
  int remaining;
  int _convertedNodes = 0;

  int chargeJson(Object? value) {
    final count = _jsonSize(value, remaining);
    remaining -= count;
    return count;
  }

  /// DOM serialization is recursive and may expand text and attributes.
  /// Reject an oversized or deeply nested tree before calling outerHtml/text.
  void checkNode(dom.Node root) {
    final pending = <(dom.Node, int)>[(root, 0)];
    var nodes = 0;
    var bound = 2; // JSON string quotes.
    void add(int count) {
      bound += count;
      if (bound > remaining) {
        throw const FormatException('Legado 脚本辅助数据超过限制');
      }
    }

    void addText(String text) {
      for (final unit in text.codeUnits) {
        add(switch (unit) {
          < 0x20 => 6,
          0x22 => 6,
          0x26 => 5,
          0x3c || 0x3e => 4,
          0x5c => 2,
          0xa0 => 6,
          >= 0x80 => 3,
          _ => 1,
        });
      }
    }

    while (pending.isNotEmpty) {
      final (node, depth) = pending.removeLast();
      if (++nodes > maxNodes || depth > maxDepth) {
        throw const FormatException('Legado 脚本辅助数据结构超过限制');
      }
      if (node is dom.Text) {
        addText(node.data);
      } else if (node is dom.Comment) {
        add(7);
        addText(node.data ?? '');
      } else if (node is dom.DocumentType) {
        add(32);
        addText(node.name ?? '');
        addText(node.publicId ?? '');
        addText(node.systemId ?? '');
      } else if (node is dom.Element) {
        // Includes tag delimiters, closing tag and possible namespace prefix.
        add(128);
        addText(node.localName ?? '');
        addText(node.localName ?? '');
        for (final entry in node.attributes.entries) {
          add(8);
          addText(entry.key.toString());
          addText(entry.value);
        }
      }
      final children = node.nodes;
      if (children.length + pending.length > maxNodes - nodes) {
        throw const FormatException('Legado 脚本辅助数据结构超过限制');
      }
      for (var i = children.length - 1; i >= 0; i--) {
        pending.add((children[i], depth + 1));
      }
    }
  }

  Object? convert(Object? value, {int depth = 0}) {
    if (++_convertedNodes > maxNodes || depth > maxDepth) {
      throw const FormatException('Legado 脚本辅助数据结构超过限制');
    }
    if (value is dom.Node) {
      checkNode(value);
      final text = switch (value) {
        dom.Document node => node.outerHtml,
        dom.Element node => node.outerHtml,
        _ => value.text,
      };
      chargeJson(text);
      return text;
    }
    if (value is List) {
      if (value.length > maxNodes) {
        throw const FormatException('Legado 脚本辅助数据结构超过限制');
      }
      final delimiters = value.isEmpty ? 2 : value.length + 1;
      if (delimiters > remaining) {
        throw const FormatException('Legado 脚本辅助数据超过限制');
      }
      remaining -= delimiters;
      return [for (final item in value) convert(item, depth: depth + 1)];
    }
    // JSON maps may contain nested lists; reserve their complete encoded size
    // before passing the existing value to the JSON encoder.
    chargeJson(value);
    return value;
  }
}

/// Bound nesting before the SDK's recursive JSON encoder, then count UTF-8 in
/// small chunks so the check itself does not build an unbounded JSON string.
int _jsonSize(Object? value, int limit) {
  final pending = <(Object?, int)>[(value, 0)];
  var nodes = 0;
  while (pending.isNotEmpty) {
    final (item, depth) = pending.removeLast();
    if (++nodes > LegadoScriptBudget.maxNodes ||
        depth > LegadoScriptBudget.maxDepth) {
      throw const FormatException('Legado 脚本辅助数据结构超过限制');
    }
    if (item is List) {
      if (item.length + pending.length > LegadoScriptBudget.maxNodes - nodes) {
        throw const FormatException('Legado 脚本辅助数据结构超过限制');
      }
      for (final child in item) {
        pending.add((child, depth + 1));
      }
    } else if (item is Map) {
      if (item.length * 2 + pending.length >
          LegadoScriptBudget.maxNodes - nodes) {
        throw const FormatException('Legado 脚本辅助数据结构超过限制');
      }
      for (final entry in item.entries) {
        pending.add((entry.key, depth + 1));
        pending.add((entry.value, depth + 1));
      }
    }
  }
  final sink = _BudgetSink(limit);
  final encoder = JsonUtf8Encoder().startChunkedConversion(sink);
  encoder.add(value);
  encoder.close();
  return sink.count;
}

final class _BudgetSink implements Sink<List<int>> {
  _BudgetSink(this.limit);
  final int limit;
  int count = 0;

  @override
  void add(List<int> chunk) {
    count += chunk.length;
    if (count > limit) {
      throw const FormatException('Legado 脚本辅助数据超过限制');
    }
  }

  @override
  void close() {}
}
