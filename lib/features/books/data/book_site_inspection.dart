import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../../../core/network/document_encoding.dart';
import '../../../core/network/header_policy.dart';
import '../../../core/network/media_http_client.dart';
import '../../../core/network/request_scheduler.dart';
import '../domain/book.dart';
import 'book_html.dart';
import 'book_site_sale_clues.dart';
import 'book_site_script_clues.dart';

/// A page sample is evidence for review, never a statement that a site is safe.
enum BookSiteFinding {
  sampled,
  gamblingClue,
  adultClue,
  gamblingAndAdultClues,
  sameSiteRedirect,
  externalRedirect,
  httpError,
  timeout,
  networkError,
  unsupported,
  sourceChanged,
}

enum BookSiteRedirect { none, sameSite, external }

final class BookSiteInspection {
  const BookSiteInspection(
    this.finding, {
    this.gamblingRisk = false,
    this.adultRisk = false,
    this.truncated = false,
    this.statusCode,
    this.redirect = BookSiteRedirect.none,
    this.scriptReview = const BookPageScriptReview(),
    this.saleReview = const BookPageSaleReview(),
  });

  final BookSiteFinding finding;

  /// These require independently supported business and solicitation, age,
  /// or site-purpose clues. One isolated keyword cannot trigger a block.
  final bool gamblingRisk, adultRisk, truncated;
  final int? statusCode;
  final BookSiteRedirect redirect;
  final BookPageScriptReview scriptReview;
  final BookPageSaleReview saleReview;

  BookSiteInspection withSaleReview(BookPageSaleReview review) =>
      BookSiteInspection(
        finding,
        gamblingRisk: gamblingRisk,
        adultRisk: adultRisk,
        truncated: truncated,
        statusCode: statusCode,
        redirect: redirect,
        scriptReview: scriptReview,
        saleReview: review,
      );

  String get label {
    final signal = gamblingRisk && adultRisk
        ? '博彩及成人强线索'
        : gamblingRisk
        ? '博彩强线索'
        : adultRisk
        ? '成人强线索'
        : switch (finding) {
            BookSiteFinding.sampled => truncated ? '首页静态样本已截断' : '已抽样首页静态内容',
            BookSiteFinding.gamblingClue => '疑似博彩文字线索，待复核',
            BookSiteFinding.adultClue => '疑似成人文字线索，待复核',
            BookSiteFinding.gamblingAndAdultClues => '疑似博彩及成人文字线索，待复核',
            BookSiteFinding.sameSiteRedirect => '页面跳转，未跟随',
            BookSiteFinding.externalRedirect => '跨站跳转，未跟随，待复核',
            BookSiteFinding.httpError => 'HTTP ${statusCode ?? 0}，未确认',
            BookSiteFinding.timeout => '连接超时，未确认',
            BookSiteFinding.networkError => '连接失败，未确认',
            BookSiteFinding.unsupported => '非可检查网页或编码不支持，未确认',
            BookSiteFinding.sourceChanged => '来源或检查记录需重新确认，待重新抽查',
          };
    final parts = [signal];
    if (saleReview.suspected) {
      parts.add('疑似域名出售静态结构（可见性未确认），待复核');
    }
    if (saleReview.coverage == BookPageSaleCoverage.partial) {
      parts.add('域名出售静态结构检查不完整');
    }
    if (finding == BookSiteFinding.gamblingAndAdultClues) {
      if (gamblingRisk && !adultRisk) {
        parts.add('疑似成人文字线索，待复核');
      } else if (adultRisk && !gamblingRisk) {
        parts.add('疑似博彩文字线索，待复核');
      }
    }
    if (finding != BookSiteFinding.sameSiteRedirect &&
        finding != BookSiteFinding.externalRedirect) {
      switch (redirect) {
        case BookSiteRedirect.none:
          break;
        case BookSiteRedirect.sameSite:
          parts.add('页面跳转，未跟随');
        case BookSiteRedirect.external:
          parts.add('跨站跳转，未跟随，待复核');
      }
    }
    if (truncated && finding != BookSiteFinding.sampled) {
      parts.add('首页静态检查覆盖不完整');
    }
    if (scriptReview.clues.contains(BookPageScriptClue.crossOriginRedirect)) {
      parts.add('本次内联脚本含跨源跳转写法，待复核');
    }
    if (scriptReview.clues.contains(
      BookPageScriptClue.decodedDynamicEvaluation,
    )) {
      parts.add('本次内联脚本含解码后动态求值写法，待复核');
    }
    parts.add(switch (scriptReview.coverage) {
      BookPageScriptCoverage.notChecked => '页面脚本未检查',
      BookPageScriptCoverage.sampled => '仅静态检查首页内联脚本',
      BookPageScriptCoverage.partial => '页面脚本仅部分覆盖',
    });
    return parts.join(' · ');
  }
}

/// Only the root of a previously validated source host is requested: source
/// rules, URL paths, query tokens, cookies and source headers are not used.
final class BookSiteInspector {
  const BookSiteInspector(
    this.http, {
    this.requestTimeout = const Duration(seconds: 8),
  });
  final MediaHttpClient http;
  static const maxBytes = 128 * 1024;
  final Duration requestTimeout;

  Future<BookSiteInspection> inspect(
    BookSource source,
    CancellationToken cancellation,
  ) async {
    final target = bookSiteInspectionTarget(source);
    return _inspectTarget(target, cancellation);
  }

  /// Loopback HTTP fixtures exercise the real bounded transport in tests. The
  /// application entry point above always constructs a public HTTPS root.
  @visibleForTesting
  Future<BookSiteInspection> inspectTargetForTesting(
    Uri target,
    CancellationToken cancellation,
  ) => _inspectTarget(target, cancellation);

  Future<BookSiteInspection> _inspectTarget(
    Uri target,
    CancellationToken cancellation,
  ) async {
    final token = CancellationToken();
    final unlink = cancellation.listen(token.cancel);
    final timer = Timer(requestTimeout, token.cancel);
    try {
      token.check();
      final payload = await http.open(
        target,
        policy: HeaderPolicy({target: const {}}),
        cancellation: token,
        priority: RequestPriority.background,
        // Even same-host redirects are reported instead of being followed.
        mapRedirect: (redirect) => throw _Redirect(redirect),
      );
      return await _inspectPayload(payload, target, token);
    } on _Redirect catch (redirect) {
      cancellation.check();
      final sameSite =
          HeaderPolicy.origin(target) == HeaderPolicy.origin(redirect.target);
      return BookSiteInspection(
        sameSite
            ? BookSiteFinding.sameSiteRedirect
            : BookSiteFinding.externalRedirect,
        redirect: sameSite
            ? BookSiteRedirect.sameSite
            : BookSiteRedirect.external,
      );
    } on RequestCancelled {
      cancellation.check();
      return const BookSiteInspection(BookSiteFinding.timeout);
    } on TimeoutException {
      cancellation.check();
      return const BookSiteInspection(BookSiteFinding.timeout);
    } on FormatException {
      cancellation.check();
      if (token.isCancelled) {
        return const BookSiteInspection(BookSiteFinding.timeout);
      }
      return const BookSiteInspection(BookSiteFinding.unsupported);
    } on Exception {
      cancellation.check();
      if (token.isCancelled) {
        return const BookSiteInspection(BookSiteFinding.timeout);
      }
      return const BookSiteInspection(BookSiteFinding.networkError);
    } finally {
      timer.cancel();
      unlink();
    }
  }

  Future<BookSiteInspection> _inspectPayload(
    HttpPayload payload,
    Uri target,
    CancellationToken token,
  ) async {
    final response = payload.response;
    if (response.statusCode != 200) {
      await payload.body.take(0).drain<void>();
      return BookSiteInspection(
        BookSiteFinding.httpError,
        statusCode: response.statusCode,
      );
    }
    final type = response.headers.value(HttpHeaders.contentTypeHeader) ?? '';
    final encoding =
        response.headers
            .value(HttpHeaders.contentEncodingHeader)
            ?.trim()
            .toLowerCase() ??
        '';
    if ((!type.toLowerCase().contains('text/html') &&
            !type.toLowerCase().contains('application/xhtml+xml')) ||
        (encoding.isNotEmpty && encoding != 'identity')) {
      await payload.body.take(0).drain<void>();
      return const BookSiteInspection(BookSiteFinding.unsupported);
    }
    final bytes = BytesBuilder(copy: false);
    var truncated = false;
    await for (final chunk in payload.body) {
      final remaining = maxBytes - bytes.length;
      if (chunk.length >= remaining) {
        bytes.add(chunk.take(remaining).toList());
        truncated = true;
        break;
      }
      bytes.add(chunk);
    }
    token.check();
    final data = bytes.takeBytes();
    if (data.isEmpty) {
      return const BookSiteInspection(BookSiteFinding.unsupported);
    }
    String text;
    try {
      text = decodeDocumentText(data, contentType: type);
    } on FormatException {
      // An otherwise valid multibyte character can straddle the sample end.
      if (!truncated || data.length < 4) rethrow;
      text = decodeDocumentText(
        data.sublist(0, data.length - 4),
        contentType: type,
      );
    }
    return inspectBookSiteHtml(target, text, truncated: truncated);
  }
}

Uri bookSiteInspectionTarget(BookSource source) =>
    publicBookUri(Uri(scheme: 'https', host: source.endpoint.host, path: '/'));

final class _Redirect implements Exception {
  const _Redirect(this.target);
  final Uri target;
}

final _gamblingBusiness = RegExp(
  r'(?:在线|在線|线上|線上|网络|網絡)(?:赌场|賭場|博彩)|'
  r'(?:澳门|澳門)(?:赌场|賭場)|真人(?:百家乐|百家樂|博彩)|'
  r'博彩(?:开户|開戶|平台|网站|網站)|投注(?:平台|网站|網站)|'
  r'(?:体育|體育)(?:投注|博彩)',
  caseSensitive: false,
);
final _gamblingPromotion = RegExp(
  r'立即下注|立即投注|(?:注册|註冊)(?:领取|領取|赠送|贈送|送彩金)|'
  r'(?:开户|開戶)(?:送彩金|送|领取|領取)|'
  r'首存(?:优惠|優惠|奖励|獎勵|赠送|贈送)|充值(?:返水|送|赠|贈)',
  caseSensitive: false,
);
final _gamblingContextBoundary = RegExp(r'[。！？!?；;，,\n\r]');
final _gamblingWarning = RegExp(
  r'远离|遠離|抵制|拒绝|拒絕|切勿|请勿|請勿|勿点|勿點|'
  r'严禁|嚴禁|禁止(?!未成年人|未满|未滿)|'
  r'(?:不要|不可|不能|不应|不應|避免)(?:访问|訪問|参与|參與|'
  r'点击|點擊|轻信|輕信|注册|註冊|进入|進入|下注|投注|(?=\s*$))|'
  r'防诈骗|防詐騙|防骗|防騙|反赌|反賭|警惕|谨防|謹防|'
  r'打击|打擊|取缔|取締|揭露|曝光',
);
final _gamblingWarningAfter = RegExp(
  r'^[\s"\x27“”‘’《》]*(?:等)?(?:均|皆)?'
  r'(?:是|为|為|属于|屬於|涉嫌)?'
  r'(?:诈骗|詐騙|骗局|騙局|陷阱|违法|違法|非法|'
  r'危害|风险|風險|应当远离|應當遠離|切勿参与|切勿參與)',
);
final _adultBusiness = RegExp(
  r'成人(?:视频|視頻|(?:黄色|黃色)?(?:连载|連載)?(?:小说|小說)|漫画|漫畫)|'
  r'色情(?:小说|小說|视频|視頻|漫画|漫畫)|情色(?:小说|小說)|'
  r'(?:18禁|十八禁)(?:情欲|情慾|色情|情色)(?:类|類)?(?:小说|小說)|'
  r'肉文|肉漫|无码视频',
  caseSensitive: false,
);
final _adultSiteTitle = RegExp(r'高辣文(?:小说|小說)(?:网|網|站)');
final _adultSiteDescription = RegExp(
  r'(?:成人(?:黄色|黃色)?(?:连载|連載)?(?:小说|小說)|'
  r'色情(?:小说|小說)|成人(?:漫画|漫畫)|色情(?:漫画|漫畫))'
  r'(?:网站|網站|阅读网|閱讀網|站|网|網|平台)|'
  r'(?:专属|專屬|专门提供|專門提供|主要提供|主打)'
  r'[^，。；;\n]{0,20}(?:成人(?:小说|小說|漫画|漫畫)|'
  r'色情(?:小说|小說|漫画|漫畫)|肉文|肉漫)',
);
final _adultSiteWarning = RegExp(
  r'抵制|远离|遠離|打击|打擊|不提供|不收录|不收錄|拒绝|拒絕|'
  r'禁止(?:传播|傳播|提供|访问|訪問)|危害|举报|舉報',
);
// A category, recommendation or advertisement does not describe the whole
// host. In particular, an age notice for one section is not a site-wide gate.
final _adultLocalScope = RegExp(
  r'专区|專區|分类|分類|频道|頻道|栏目|欄目|专题|專題|'
  r'书单|書單|推荐|推薦|排行|导航|導航|友链|友鏈|'
  r'链接|鏈接|广告|廣告',
);
final _adultClauseBoundary = RegExp(r'[，,。！？!?；;\r\n|]');
final _advertisementText = RegExp(
  r'^\s*(?:广告|廣告|赞助|贊助|(?:ad|advertisement|sponsored)\b)',
  caseSensitive: false,
);
final _exclusiveAdultDescription = RegExp(
  r'^\s*(?:(?:本站|本网站|本網站|本平台)\s*)?'
  r'(?:专属|專屬|专营|專營|仅提供|僅提供|只提供|专门提供|專門提供)'
  r'[^，。；;\n]{0,20}'
  r'(?:成人(?:黄色|黃色)?(?:小说|小說|漫画|漫畫)|'
  r'色情(?:小说|小說|漫画|漫畫)|肉文|肉漫|'
  r'(?:18禁|十八禁)(?:情欲|情慾|色情|情色)(?:类|類)?(?:小说|小說))',
);
final _wholeSiteAdultGate = RegExp(
  r'(?:本站|本网站|本網站|本平台|全站)'
  r'[^。！？!?；;\n]{0,20}(?:仅限|僅限|只限|必须|必須|请确认|請確認)'
  r'[^。！？!?；;\n]{0,20}'
  r'(?:(?:年满|年滿|满|滿)\s*(?:[1１][8８]|十八)\s*(?:岁|歲)?|成年人)',
);
final _adultScopeSubject = RegExp(r'成人|色情|情色|肉文|肉漫|18禁|十八禁');
final _advertisingMarker = RegExp(
  r'(?:^|[\s_-])(?:ads?|advert(?:isement)?|sponsor(?:ed)?|banner|promo(?:tion)?)(?:$|[\s_-])|广告|廣告',
  caseSensitive: false,
);

bool _advertisingElement(dom.Element element) {
  final tag = element.localName?.toLowerCase();
  if (tag == 'aside' || element.attributes['role'] == 'complementary') {
    return true;
  }
  return _advertisingMarker.hasMatch(
    '${element.attributes['id'] ?? ''} ${element.attributes['class'] ?? ''}',
  );
}

bool _unscopedAdultClause(String text) =>
    !_adultLocalScope.hasMatch(text) && !_adultSiteWarning.hasMatch(text);

bool _hasScopedAdultEntry(String text) => text
    .split(_adultClauseBoundary)
    .any(
      (part) =>
          _adultLocalScope.hasMatch(part) &&
          (_adultScopeSubject.hasMatch(part) ||
              _wholeSiteAdultGate.hasMatch(part)),
    );

final _adultGateControlCharacters = RegExp(
  r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\u202a-\u202e\u2066-\u2069]',
);

final class _AdultGateBudgetExceeded implements Exception {
  const _AdultGateBudgetExceeded();
}

String _cleanAdultGateText(String text) => text
    .replaceAll('\r', '')
    .replaceAll(_adultGateControlCharacters, '')
    .split('\n')
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty)
    .join('\n\n');

/// Bound repeated text extraction even for deeply nested entry containers.
final class _AdultGateBudget {
  int _remainingText = BookSiteInspector.maxBytes * 4;
  int _remainingNodes = BookSiteInspector.maxBytes * 4;

  String read(dom.Element element, {bool prefixOnly = false}) {
    if (_remainingText <= 0) throw const _AdultGateBudgetExceeded();
    final limit = prefixOnly ? _remainingText.clamp(0, 2048) : _remainingText;
    final output = StringBuffer();
    final pending = <({dom.Node node, bool closing})>[
      (node: element, closing: false),
    ];
    var truncated = false;
    void append(String value) {
      final available = limit - output.length;
      if (value.length > available) {
        output.write(value.substring(0, available));
        truncated = true;
      } else {
        output.write(value);
      }
    }

    while (pending.isNotEmpty && !truncated) {
      if (--_remainingNodes < 0) throw const _AdultGateBudgetExceeded();
      final item = pending.removeLast();
      final node = item.node;
      if (node is dom.Text) {
        append(node.data);
        continue;
      }
      final block =
          node is dom.Element &&
          const {
            'p',
            'div',
            'section',
            'article',
            'li',
            'blockquote',
            'br',
            'h1',
            'h2',
            'h3',
            'pre',
          }.contains(node.localName);
      if (item.closing) {
        if (block && output.isNotEmpty) append('\n');
        continue;
      }
      if (block && output.isNotEmpty) append('\n');
      pending.add((node: node, closing: true));
      for (final child in node.nodes.reversed) {
        pending.add((node: child, closing: false));
      }
    }
    final text = output.toString();
    _remainingText -= text.length;
    if (truncated || text.length >= limit) {
      if (prefixOnly) {
        final boundary = _adultClauseBoundary.firstMatch(text);
        if (boundary != null) {
          return _cleanAdultGateText(text.substring(0, boundary.start));
        }
      }
      throw const _AdultGateBudgetExceeded();
    }
    return _cleanAdultGateText(text);
  }
}

bool _gateHasLocalLabel(
  dom.Element gate,
  Map<dom.Element, bool> labels,
  _AdultGateBudget budget,
) {
  final parent = gate.parent;
  if (parent == null ||
      !const {
        'div',
        'section',
        'article',
        'li',
        'form',
      }.contains(parent.localName)) {
    return false;
  }
  return labels.putIfAbsent(parent, () {
    final label = budget
        .read(parent, prefixOnly: true)
        .split(_adultClauseBoundary)
        .first;
    return _advertisementText.hasMatch(label) ||
        (_adultScopeSubject.hasMatch(label) &&
            _adultLocalScope.hasMatch(label));
  });
}

/// Combine the site-wide gate and adult business only inside one entry form,
/// dialog or leaf text block. An unrelated category elsewhere on the page is
/// not part of the evidence, and explicit advertising is excluded.
({bool found, bool complete}) _hasWholeSiteAdultEntryGate(
  dom.Document document,
) {
  final elements = document.querySelectorAll('*');
  final selfAd = <dom.Element, bool>{};
  final subtreeAd = <dom.Element, bool>{};
  final blockDescendant = <dom.Element, bool>{};
  const blockTags = {
    'div',
    'p',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'section',
    'article',
    'nav',
    'header',
    'footer',
    'form',
    'ul',
    'ol',
    'li',
    'table',
    'aside',
  };
  // Each edge is visited once, rather than re-querying nested subtrees.
  for (final element in elements.reversed) {
    final ad = selfAd[element] = _advertisingElement(element);
    var adBelow = ad;
    var blockBelow = false;
    for (final child in element.children) {
      adBelow = adBelow || subtreeAd[child] == true;
      blockBelow =
          blockBelow ||
          blockTags.contains(child.localName) ||
          blockDescendant[child] == true;
    }
    subtreeAd[element] = adBelow;
    blockDescendant[element] = blockBelow;
  }
  final adAncestor = <dom.Element, bool>{};
  for (final element in elements) {
    adAncestor[element] =
        selfAd[element] == true || adAncestor[element.parent] == true;
  }

  final budget = _AdultGateBudget();
  final labels = <dom.Element, bool>{};
  final containerTexts = <dom.Element, String>{};
  String containerText(dom.Element element) =>
      containerTexts.putIfAbsent(element, () => budget.read(element));
  bool isContainer(dom.Element element) =>
      element.localName == 'form' || element.attributes['role'] == 'dialog';
  final scopedAncestor = <dom.Element, bool>{};
  bool blockedByScope(dom.Element gate) {
    final pending = <dom.Element>[];
    dom.Element? node = gate;
    var blocked = false;
    while (node != null) {
      final known = scopedAncestor[node];
      if (known != null) {
        blocked = known;
        break;
      }
      pending.add(node);
      if (isContainer(node) && _hasScopedAdultEntry(containerText(node))) {
        blocked = true;
        break;
      }
      node = node.parent;
    }
    for (final element in pending) {
      scopedAncestor[element] = blocked;
    }
    return blocked;
  }

  try {
    for (final gate in elements) {
      final container = isContainer(gate);
      if (!container &&
          !const {'p', 'h1', 'h2', 'h3', 'div'}.contains(gate.localName)) {
        continue;
      }
      if (!container &&
          gate.localName == 'div' &&
          blockDescendant[gate] == true) {
        continue;
      }
      if (adAncestor[gate] == true || subtreeAd[gate] == true) continue;
      final text = container ? containerText(gate) : budget.read(gate);
      if (!_adultBusiness.hasMatch(text) ||
          !_wholeSiteAdultGate.hasMatch(text)) {
        continue;
      }
      if (blockedByScope(gate) ||
          _advertisementText.hasMatch(text) ||
          (!container && _gateHasLocalLabel(gate, labels, budget))) {
        continue;
      }
      if (_adultSiteWarning.hasMatch(text)) continue;
      final clauses = text.split(_adultClauseBoundary);
      if (clauses.any(
            (part) =>
                _unscopedAdultClause(part) && _adultBusiness.hasMatch(part),
          ) &&
          clauses.any(
            (part) =>
                _unscopedAdultClause(part) &&
                _wholeSiteAdultGate.hasMatch(part),
          ) &&
          _hasAdultBusinessOutsideWarning(text)) {
        return (found: true, complete: true);
      }
    }
  } on _AdultGateBudgetExceeded {
    return (found: false, complete: false);
  }
  return (found: false, complete: true);
}

/// A warning applies only to a nearby signal in the same clause. A later
/// occurrence, or an advertisement in another block, remains independent.
bool _hasGamblingSignalOutsideWarning(String text, RegExp signal) {
  const contextLength = 32;
  for (final match in signal.allMatches(text)) {
    final start = (match.start - contextLength).clamp(0, text.length);
    final end = (match.end + contextLength).clamp(0, text.length);
    final before = text
        .substring(start, match.start)
        .split(_gamblingContextBoundary)
        .last;
    final after = text
        .substring(match.end, end)
        .split(_gamblingContextBoundary)
        .first;
    final warning = _gamblingWarning.allMatches(before).lastOrNull;
    if (warning != null) {
      final intervening = before.substring(warning.end);
      if (!_gamblingBusiness.hasMatch(intervening) &&
          !_gamblingPromotion.hasMatch(intervening)) {
        continue;
      }
    }
    if (_gamblingWarningAfter.hasMatch(after)) continue;
    return true;
  }
  return false;
}

bool _hasAdultBusinessOutsideWarning(String text) {
  const contextLength = 32;
  for (final match in _adultBusiness.allMatches(text)) {
    final start = (match.start - contextLength).clamp(0, text.length);
    final before = text
        .substring(start, match.start)
        .split(_gamblingContextBoundary)
        .last;
    final warning = _adultSiteWarning.allMatches(before).lastOrNull;
    if (warning == null ||
        _adultBusiness.hasMatch(before.substring(warning.end))) {
      return true;
    }
  }
  return false;
}

/// Parse inert HTML only. Do not render, execute scripts or fetch subresources.
BookSiteInspection inspectBookSiteHtml(
  Uri target,
  String input, {
  bool truncated = false,
}) {
  final document = html.parse(input);
  BookPageSaleReview saleReview;
  try {
    saleReview = inspectBookPageSale(
      document,
      target,
      input,
      truncated: truncated,
    );
  } catch (_) {
    // A malformed sample cannot clear earlier observations.
    saleReview = const BookPageSaleReview();
  }
  BookPageScriptReview scriptReview;
  try {
    scriptReview = inspectBookPageScripts(
      document,
      target,
      truncated: truncated,
    );
  } catch (_) {
    // A malformed sample must not discard the independent adult/betting scan.
    // No exception detail or page text is retained.
    scriptReview = const BookPageScriptReview(
      coverage: BookPageScriptCoverage.partial,
    );
  }
  var refresh = false;
  var externalRefresh = false;
  for (final meta in document.querySelectorAll('meta[http-equiv]')) {
    if (meta.attributes['http-equiv']?.toLowerCase().trim() != 'refresh') {
      continue;
    }
    refresh = true;
    final match = RegExp(
      r'''url\s*=\s*['"]?\s*([^'"\s;]+)''',
      caseSensitive: false,
    ).firstMatch(meta.attributes['content'] ?? '');
    final redirect = match == null ? null : Uri.tryParse(match[1]!);
    if (redirect == null) {
      externalRefresh = true;
      continue;
    }
    final resolved = target.resolveUri(redirect);
    if (HeaderPolicy.origin(target) != HeaderPolicy.origin(resolved)) {
      externalRefresh = true;
    }
  }
  for (final node in document.querySelectorAll(
    'script, style, iframe, object, embed, template, svg, [hidden]',
  )) {
    node.remove();
  }
  // Description is the site's own summary. Keywords are deliberately omitted:
  // a list of search terms is weaker evidence of the site's actual business.
  final descriptions = document
      .querySelectorAll('meta[name]')
      .where(
        (meta) =>
            meta.attributes['name']?.trim().toLowerCase() == 'description',
      )
      .map((meta) => meta.attributes['content'] ?? '')
      .take(2);
  final text = [
    plainBookText(document, limit: BookSiteInspector.maxBytes),
    ...descriptions,
  ].join('\n');
  final gambling = _gamblingBusiness.hasMatch(text);
  final adult = _adultBusiness.hasMatch(text);
  final bettingRisk =
      gambling &&
      _hasGamblingSignalOutsideWarning(text, _gamblingBusiness) &&
      _hasGamblingSignalOutsideWarning(text, _gamblingPromotion);
  final title = document.querySelector('title')?.text ?? '';
  final titleNamesAdultSite =
      !_adultSiteWarning.hasMatch(title) &&
      title
          .split(_adultClauseBoundary)
          .any(
            (part) =>
                _unscopedAdultClause(part) &&
                (_adultBusiness.hasMatch(part) ||
                    _adultSiteTitle.hasMatch(part)),
          );
  final sitePurpose = descriptions.any(
    (description) =>
        !_adultSiteWarning.hasMatch(description) &&
        description
            .split(_adultClauseBoundary)
            .any(
              (part) =>
                  _unscopedAdultClause(part) &&
                  (titleNamesAdultSite &&
                          _adultSiteDescription.hasMatch(part) ||
                      _exclusiveAdultDescription.hasMatch(part)),
            ),
  );
  final adultBusiness = adult && _hasAdultBusinessOutsideWarning(text);
  final gate = adultBusiness && !sitePurpose
      ? _hasWholeSiteAdultEntryGate(document)
      : (found: false, complete: true);
  final adultRisk = adultBusiness && (sitePurpose || gate.found);
  final finding = gambling && adult
      ? BookSiteFinding.gamblingAndAdultClues
      : gambling
      ? BookSiteFinding.gamblingClue
      : adult
      ? BookSiteFinding.adultClue
      : refresh
      ? (externalRefresh
            ? BookSiteFinding.externalRedirect
            : BookSiteFinding.sameSiteRedirect)
      : BookSiteFinding.sampled;
  return BookSiteInspection(
    finding,
    gamblingRisk: bettingRisk,
    adultRisk: adultRisk,
    truncated: truncated || !gate.complete,
    scriptReview: scriptReview,
    saleReview: saleReview,
    redirect: !refresh
        ? BookSiteRedirect.none
        : externalRefresh
        ? BookSiteRedirect.external
        : BookSiteRedirect.sameSite,
  );
}
