import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as dom;

/// A bounded static homepage observation, not a site availability verdict.
enum BookPageSaleCoverage { notChecked, complete, partial }

String bookSiteSaleOriginFingerprint(Uri uri) => sha256
    .convert(
      utf8.encode('${uri.scheme.toLowerCase()}://${uri.host}:${uri.port}'),
    )
    .toString();

final class BookPageSaleReview {
  const BookPageSaleReview({
    this.coverage = BookPageSaleCoverage.notChecked,
    this.suspected = false,
    this.originSha256,
  });

  final BookPageSaleCoverage coverage;
  final bool suspected;
  final String? originSha256;

  Map<String, Object?> toJson() => {
    'version': 1,
    'coverage': coverage.name,
    'suspected': suspected,
    if (originSha256 != null) 'originSha256': originSha256,
  };

  static bool validJson(Object? value) {
    if (value is! Map || value['version'] != 1 || value['suspected'] is! bool) {
      return false;
    }
    final coverage = BookPageSaleCoverage.values
        .where((entry) => entry.name == value['coverage'])
        .firstOrNull;
    if (coverage == null) return false;
    final origin = value['originSha256'];
    if (coverage == BookPageSaleCoverage.notChecked) {
      return value['suspected'] == false && origin == null;
    }
    return origin is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(origin);
  }

  static BookPageSaleReview fromJson(Object? value) {
    if (!validJson(value)) return const BookPageSaleReview();
    final map = value as Map;
    return BookPageSaleReview(
      coverage: BookPageSaleCoverage.values.firstWhere(
        (entry) => entry.name == map['coverage'],
      ),
      suspected: map['suspected'] as bool,
      originSha256: map['originSha256'] as String?,
    );
  }
}

const _maxNodes = 2048;
const _maxDepth = 64;
const _maxTextCharacters = 65536;
const _maxAttributeWork = 65536;
final _hiddenStyle = RegExp(
  r'(?:display\s*:\s*none|visibility\s*:\s*(?:hidden|collapse)|'
  r'opacity\s*:\s*0(?:\.0*)?(?:\s*[;!}]|$)|'
  r'(?:font-size|height|width)\s*:\s*0(?:px|em|rem|%)?(?:\s*[;!}]|$)|'
  r'clip(?:-path)?\s*:)',
  caseSensitive: false,
);
final _articleClass = RegExp(
  r'(?:^|[\s_-])(?:article|blog|post|news|comment|tutorial|example)(?:$|[\s_-])',
  caseSensitive: false,
);

final class _SaleEligibilityBudget {
  int remaining = _maxAttributeWork;
  bool exhausted = false;

  bool eligible(dom.Element element) {
    dom.Element? node = element;
    while (node != null) {
      final rawTag = node.localName ?? '';
      final inlineStyle = node.attributes['style'] ?? '';
      final classes = node.attributes['class'] ?? '';
      final id = node.attributes['id'] ?? '';
      final ariaHidden = node.attributes['aria-hidden'] ?? '';
      if (rawTag.length > 1024 ||
          inlineStyle.length > 1024 ||
          classes.length > 1024 ||
          id.length > 1024 ||
          ariaHidden.length > 1024) {
        exhausted = true;
        return false;
      }
      final cost =
          rawTag.length +
          inlineStyle.length +
          classes.length +
          id.length +
          ariaHidden.length;
      if (cost > remaining) {
        exhausted = true;
        return false;
      }
      remaining -= cost;
      final tag = rawTag.toLowerCase();
      if (const {
            'article',
            'aside',
            'blockquote',
            'code',
            'embed',
            'footer',
            'iframe',
            'nav',
            'noscript',
            'object',
            'pre',
            'script',
            'style',
            'svg',
            'template',
          }.contains(tag) ||
          node.attributes.containsKey('hidden') ||
          node.attributes.containsKey('inert') ||
          ariaHidden.trim().toLowerCase() == 'true' ||
          _hiddenStyle.hasMatch(inlineStyle) ||
          _articleClass.hasMatch(classes) ||
          _articleClass.hasMatch(id)) {
        return false;
      }
      node = node.parent;
    }
    return true;
  }
}

/// Read a short heading without using the recursively computed Element.text.
String? _heading(dom.Element root, _SaleEligibilityBudget budget) {
  final stack = <(dom.Node, int)>[(root, 0)];
  final text = StringBuffer();
  var visited = 0, characters = 0;
  while (stack.isNotEmpty) {
    final (node, depth) = stack.removeLast();
    if (++visited > 64 || depth > 16) return null;
    if (node is dom.Text) {
      characters += node.data.length;
      if (characters > 1024) return null;
      text.write(node.data);
    }
    if (node is dom.Element && node != root && !budget.eligible(node)) {
      if (budget.exhausted) return null;
      continue;
    }
    final children = node.nodes;
    if (children.length + stack.length > 64 - visited) return null;
    for (var i = children.length - 1; i >= 0; i--) {
      stack.add((children[i], depth + 1));
    }
  }
  return text.toString().trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
}

/// Only the observed sale landing-page shape is recognized. CSS visibility is
/// unknown: style/script coverage is partial, and a positive is a weak static
/// structure clue, not proof that content was rendered. No text or URL escapes.
BookPageSaleReview inspectBookPageSale(
  dom.Document document,
  Uri target,
  String input, {
  required bool truncated,
}) {
  final origin = bookSiteSaleOriginFingerprint(target);
  var partial =
      truncated || !_saleTargetEligible(target) || !_closedSalePage(input);
  var budgetExhausted = false;
  var visited = 0, textCharacters = 0;
  var saleHeadings = 0, contactHeadings = 0, forms = 0;
  final eligibility = _SaleEligibilityBudget();
  final stack = <(dom.Node, int)>[(document, 0)];
  while (stack.isNotEmpty) {
    final (node, depth) = stack.removeLast();
    if (++visited > _maxNodes || depth > _maxDepth) {
      partial = true;
      budgetExhausted = true;
      break;
    }
    if (node is dom.Text) {
      textCharacters += node.data.length;
      if (textCharacters > _maxTextCharacters) {
        partial = true;
        budgetExhausted = true;
        break;
      }
    }
    if (node is! dom.Element) {
      if (!_pushSaleChildren(node.nodes, depth, stack, visited)) {
        partial = true;
        budgetExhausted = true;
        break;
      }
      continue;
    }
    final element = node;
    final rawTag = element.localName ?? '';
    if (_saleElementTooLarge(element, rawTag)) {
      partial = true;
      budgetExhausted = true;
      break;
    }
    final tag = rawTag.toLowerCase();
    if (_saleElementPartial(element, tag)) partial = true;
    // Inert and embedded subtrees are not traversed or used as clues.
    if (_inertSaleTags.contains(tag)) continue;
    if (!_pushSaleChildren(element.nodes, depth, stack, visited)) {
      partial = true;
      budgetExhausted = true;
      break;
    }
    if (!eligibility.eligible(element)) {
      if (eligibility.exhausted) {
        partial = true;
        budgetExhausted = true;
        break;
      }
      continue;
    }
    String? heading;
    if (tag == 'h1' || tag == 'h3') {
      heading = _heading(element, eligibility);
      if (heading == null) {
        partial = true;
        budgetExhausted = true;
        break;
      }
    }
    if (tag == 'h1' && _saleHeading(heading)) saleHeadings++;
    if (tag == 'h3' && _contactHeading(heading)) contactHeadings++;
    if (tag == 'form') forms++;
  }
  final suspected =
      !budgetExhausted &&
      saleHeadings > 0 &&
      saleHeadings <= 2 &&
      contactHeadings == 1 &&
      forms == 1 &&
      _saleTargetEligible(target);
  return BookPageSaleReview(
    coverage: partial
        ? BookPageSaleCoverage.partial
        : BookPageSaleCoverage.complete,
    suspected: suspected,
    originSha256: origin,
  );
}

const _inertSaleTags = {
  'script',
  'style',
  'iframe',
  'object',
  'embed',
  'template',
  'noscript',
  'svg',
};

bool _saleElementTooLarge(dom.Element element, String rawTag) {
  return rawTag.length > 1024 ||
      element.attributes.length > 128 ||
      (element.attributes['style']?.length ?? 0) > 1024 ||
      (element.attributes['class']?.length ?? 0) > 1024 ||
      (element.attributes['id']?.length ?? 0) > 1024 ||
      (element.attributes['aria-hidden']?.length ?? 0) > 1024 ||
      (rawTag.toLowerCase() == 'link' &&
          (element.attributes['rel']?.length ?? 0) > 1024);
}

bool _saleElementPartial(dom.Element element, String tag) {
  var partial = false;
  if (const {
    'script',
    'style',
    'iframe',
    'object',
    'embed',
    'template',
    'noscript',
    'svg',
    'base',
  }.contains(tag)) {
    partial = true;
  }
  if (tag == 'link' &&
      (element.attributes['rel'] ?? '')
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .contains('stylesheet')) {
    partial = true;
  }
  if (element.attributes.keys.any(
    (key) => key is String && key.toLowerCase().startsWith('on'),
  )) {
    partial = true;
  }
  return partial;
}

bool _saleHeading(String? heading) => const {
  'this domain is for sale',
  'this domain name is for sale',
  '本域名正在出售',
  '此域名正在出售',
}.contains(heading);
bool _contactHeading(String? heading) => const {
  'contact the owner',
  'contact the domain owner',
  '联系域名所有者',
  '联系域名持有人',
}.contains(heading);

bool _saleTargetEligible(Uri target) =>
    target.scheme.toLowerCase() == 'https' &&
    target.port == 443 &&
    target.path == '/' &&
    !target.hasQuery &&
    !target.hasFragment;

bool _closedSalePage(String input) => RegExp(
  r'</body\s*>\s*</html\s*>\s*$',
  caseSensitive: false,
).hasMatch(input);

bool _pushSaleChildren(
  List<dom.Node> children,
  int depth,
  List<(dom.Node, int)> stack,
  int visited,
) {
  if (children.length + stack.length > _maxNodes - visited) return false;
  for (var i = children.length - 1; i >= 0; i--) {
    stack.add((children[i], depth + 1));
  }
  return true;
}
