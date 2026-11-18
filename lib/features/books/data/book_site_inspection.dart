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
    this.textIncomplete = false,
    this.visibilityIncomplete = false,
    this.statusCode,
    this.redirect = BookSiteRedirect.none,
    this.scriptReview = const BookPageScriptReview(),
    this.saleReview = const BookPageSaleReview(),
  });

  final BookSiteFinding finding;

  /// These require independently supported business and solicitation, age,
  /// or site-purpose clues. One isolated keyword cannot trigger a block.
  final bool gamblingRisk, adultRisk, truncated, textIncomplete;
  final bool visibilityIncomplete;
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
        textIncomplete: textIncomplete,
        visibilityIncomplete: visibilityIncomplete,
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
            BookSiteFinding.sampled =>
              truncated || textIncomplete || visibilityIncomplete
                  ? '首页静态检查覆盖不完整'
                  : '已抽样首页静态内容',
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
    if (textIncomplete) parts.add('成人及博彩文字提取不完整，待复核');
    if (visibilityIncomplete) parts.add('页面样式可见性未确认，待复核');
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
  r'打击|打擊|取缔|取締|揭露|曝光|研究|调查|調查|分析|统计|統計|'
  r'报告|報告|识别|識別|案例',
);
final _gamblingWarningAfter = RegExp(
  r'^[\s"\x27“”‘’《》]*(?:等)?(?:均|皆)?'
  r'(?:是|为|為|属于|屬於|涉嫌)?'
  r'(?:诈骗|詐騙|骗局|騙局|陷阱|违法|違法|非法|'
  r'危害|风险|風險|应当远离|應當遠離|切勿参与|切勿參與|'
  r'案例|研究|报告|報告|统计|統計)',
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
  r'^\s*(?:(?:本站|本网站|本網站|本平台)(?:是|为|為)?\s*|'
  r'(?=免费|免費|在线|在線|线上|線上|专业|專業|优质|優質))'
  r'(?:(?:免费|免費|在线|在線|线上|線上|专业|專業|优质|優質|'
  r'最新|专属|專屬|的)\s*){0,12}'
  r'(?:成人(?:黄色|黃色)?(?:连载|連載)?(?:小说|小說)|'
  r'色情(?:小说|小說)|成人(?:漫画|漫畫)|色情(?:漫画|漫畫))'
  r'(?:网站|網站|阅读网|閱讀網|站|网|網|平台)\s*$|'
  r'(?:专属|專屬|专门提供|專門提供|主要提供|主打)'
  r'[^，。；;\n]{0,20}(?:成人(?:小说|小說|漫画|漫畫)|'
  r'色情(?:小说|小說|漫画|漫畫)|肉文|肉漫)',
);
final _adultSiteNameClause = RegExp(
  r'^\s*(?:成人(?:黄色|黃色)?(?:连载|連載)?(?:小说|小說|漫画|漫畫)|'
  r'色情(?:小说|小說|漫画|漫畫))(?:网站|網站|阅读网|閱讀網|站|网|網|平台)\s*$',
);
final _adultReadingClause = RegExp(
  r'^\s*(?:(?:本站|本网站|本網站|本平台)\s*)?(?:提供|支持)'
  r'(?:(?:免费|免費|在线|在線|线上|線上)\s*){0,2}'
  r'(?:阅读|閱讀|连载|連載)(?:服务|服務)?\s*$',
);
final _adultSiteWarning = RegExp(
  r'抵制|反对|反對|远离|遠離|打击|打擊|不提供|不收录|不收錄|拒绝|拒絕|'
  r'禁止(?:传播|傳播|提供|访问|訪問)|危害|举报|舉報',
);
final _adultAwareness = RegExp(
  r'警惕|谨防|謹防|识别|識別|辨别|辨別|识破|識破|'
  r'统计|統計|报告|報告|研究|调查|調查|讲解|講解|介绍|介紹',
);
final _adultReferenceTail = RegExp(
  r'^\s*(?:网站|網站|网|網|站|平台)?\s*(?:的)?\s*'
  r'(?:域名|统计|統計|数据|數據|研究|报告|報告|资讯|資訊|'
  r'介绍|介紹|名单|名單|法律|危害|'
  r'(?:传播|傳播)(?:治理|研究|统计|統計|危害|打击|打擊|防治|监管|監管))',
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
final _longFormMarker = RegExp(
  r'(?:^|[\s_-])(?:chapter|novel|book|read)[_-]?(?:content|text)(?:$|[\s_-])',
  caseSensitive: false,
);

bool _longFormElement(dom.Element element) {
  if (const {
    'article',
    'blockquote',
    'pre',
    'code',
  }.contains(element.localName)) {
    return true;
  }
  return _longFormMarker.hasMatch(element.attributes['id'] ?? '') ||
      _longFormMarker.hasMatch(element.attributes['class'] ?? '');
}

bool _advertisingElement(dom.Element element) {
  final tag = element.localName?.toLowerCase();
  if (tag == 'aside' || element.attributes['role'] == 'complementary') {
    return true;
  }
  return _advertisingMarker.hasMatch(
    '${element.attributes['id'] ?? ''} ${element.attributes['class'] ?? ''}',
  );
}

final class _SiteVisibility {
  const _SiteVisibility({
    this.displayHidden = false,
    this.visibilityHidden = false,
    this.unknown = false,
  });

  final bool displayHidden, visibilityHidden, unknown;
  bool get visible => !displayHidden && !visibilityHidden && !unknown;
}

const _visibleSiteDisplays = {
  'block',
  'inline',
  'inline-block',
  'flex',
  'inline-flex',
  'grid',
  'inline-grid',
  'contents',
  'table',
  'table-row',
  'table-cell',
  'list-item',
  'flow-root',
};

/// Only simple literal inline declarations are interpreted. Contradictory or
/// dynamic declarations are unknown; no stylesheet is loaded or executed.
Map<dom.Element, _SiteVisibility> _siteVisibility(dom.Document document) {
  final states = <dom.Element, _SiteVisibility>{};
  final important = RegExp(r'\s*!\s*important\s*$', caseSensitive: false);
  final visibilityName = RegExp(
    r'\b(?:display|visibility)\b',
    caseSensitive: false,
  );
  for (final element in document.querySelectorAll('*')) {
    final parent = states[element.parent] ?? const _SiteVisibility();
    var displayHidden = parent.displayHidden;
    var visibilityHidden = parent.visibilityHidden;
    var unknown = parent.unknown;
    if (element.attributes['aria-hidden']?.trim().toLowerCase() == 'true') {
      // ARIA alone is not proof of CSS visibility or invisibility.
      unknown = true;
    }
    final displays = <String>[],
        visibilities = <String>[],
        opacities = <String>[];
    final style = element.attributes['style'] ?? '';
    if (style.contains('\\') ||
        ((style.contains('/*') || style.contains('*/')) &&
            visibilityName.hasMatch(style))) {
      unknown = true;
    }
    for (final declaration in style.split(';')) {
      final colon = declaration.indexOf(':');
      if (colon < 0) continue;
      final name = declaration.substring(0, colon).trim().toLowerCase();
      final value = declaration
          .substring(colon + 1)
          .trim()
          .replaceFirst(important, '')
          .trim()
          .toLowerCase();
      if (name == 'display') {
        displays.add(value);
      } else if (name == 'visibility') {
        visibilities.add(value);
      } else if (name == 'opacity') {
        opacities.add(value);
      } else if (!const {'font-weight', 'font-style'}.contains(name)) {
        // Without evaluating layout, even otherwise valid declarations can
        // conceal text (clipping, sizing, transforms, color, and variables).
        unknown = true;
      }
    }
    if (displays.length > 1 ||
        visibilities.length > 1 ||
        opacities.length > 1) {
      unknown = true;
    }
    if (displays.length == 1) {
      final value = displays.single;
      if (value == 'none') {
        displayHidden = true;
      } else if (!_visibleSiteDisplays.contains(value)) {
        unknown = true;
      }
    }
    if (visibilities.length == 1) {
      final value = visibilities.single;
      if (value == 'hidden' || value == 'collapse') {
        visibilityHidden = true;
      } else if (value == 'visible' || value == 'initial') {
        visibilityHidden = false;
      } else if (value != 'inherit' && value != 'unset') {
        unknown = true;
      }
    }
    if (opacities.length == 1) {
      final value = opacities.single;
      final percent = value.endsWith('%');
      final numeric = double.tryParse(
        percent ? value.substring(0, value.length - 1) : value,
      );
      if (numeric == 0) {
        // Descendants cannot undo an ancestor's zero group opacity.
        displayHidden = true;
      } else if (numeric != (percent ? 100 : 1)) {
        unknown = true;
      }
    }
    states[element] = _SiteVisibility(
      displayHidden: displayHidden,
      visibilityHidden: visibilityHidden,
      unknown: unknown,
    );
  }
  return states;
}

bool _hasUnverifiedSiteStyles(dom.Document document) {
  for (final style in document.querySelectorAll('style')) {
    if (style.text.trim().isNotEmpty) return true;
  }
  for (final link in document.querySelectorAll('link[rel]')) {
    if ((link.attributes['rel'] ?? '')
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .contains('stylesheet')) {
      return true;
    }
  }
  return false;
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
  _AdultGateBudget(this.visibility, this.longForm);

  final Map<dom.Element, _SiteVisibility> visibility;
  final Map<dom.Element, bool> longForm;
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
        if (visibility[node.parent]?.visible == false ||
            longForm[node.parent] == true) {
          continue;
        }
        append(node.data);
        continue;
      }
      if (node is dom.Element &&
          (visibility[node]?.displayHidden == true || longForm[node] == true)) {
        continue;
      }
      final visible =
          node is! dom.Element || visibility[node]?.visible != false;
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
        if (visible && block && output.isNotEmpty) append('\n');
        continue;
      }
      if (visible && block && output.isNotEmpty) append('\n');
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
  Map<dom.Element, _SiteVisibility> visibility,
) {
  final elements = document.querySelectorAll('*');
  final (subtreeAd, blockDescendant, adAncestor, longFormAncestor) =
      _adultGateAncestry(elements, visibility);
  final budget = _AdultGateBudget(visibility, longFormAncestor);
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
      if (visibility[gate]?.visible == false ||
          adAncestor[gate] == true ||
          subtreeAd[gate] == true ||
          longFormAncestor[gate] == true) {
        continue;
      }
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

(
  Map<dom.Element, bool>,
  Map<dom.Element, bool>,
  Map<dom.Element, bool>,
  Map<dom.Element, bool>,
)
_adultGateAncestry(
  List<dom.Element> elements,
  Map<dom.Element, _SiteVisibility> visibility,
) {
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
    var adBelow = ad && visibility[element]?.visible != false;
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
  final longFormAncestor = <dom.Element, bool>{};
  for (final element in elements) {
    adAncestor[element] =
        selfAd[element] == true || adAncestor[element.parent] == true;
    longFormAncestor[element] =
        _longFormElement(element) || longFormAncestor[element.parent] == true;
  }

  return (subtreeAd, blockDescendant, adAncestor, longFormAncestor);
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

bool _exactSiteSignal(RegExp signal, String text) {
  final value = text.trim();
  final match = signal.firstMatch(value);
  return match != null && match.start == 0 && match.end == value.length;
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
    final awareness = _adultAwareness.allMatches(before).lastOrNull;
    final end = [
      warning?.end ?? 0,
      awareness?.end ?? 0,
    ].reduce((a, b) => a > b ? a : b);
    if (end == 0 || _adultBusiness.hasMatch(before.substring(end))) {
      return true;
    }
  }
  return false;
}

bool _adultPurposeOutsideAwareness(String text, RegExp purpose) {
  for (final match in purpose.allMatches(text)) {
    final start = (match.start - 32).clamp(0, text.length);
    if (!_adultAwareness.hasMatch(text.substring(start, match.end)) &&
        !_adultReferenceTail.hasMatch(text.substring(match.end))) {
      return true;
    }
  }
  return false;
}

bool _adultSiteNameAndReading(String description) {
  final clauses = description.split(_adultClauseBoundary);
  for (var i = 0; i + 1 < clauses.length; i++) {
    if (_adultSiteNameClause.hasMatch(clauses[i]) &&
        _adultReadingClause.hasMatch(clauses[i + 1])) {
      return true;
    }
  }
  return false;
}

const _maxSiteTextNodes = 16384;

final class _SiteTextFrame {
  _SiteTextFrame(this.node, this.depth, this.longForm);

  final dom.Node node;
  final int depth;
  final bool longForm;
  bool entered = false;
  int nextChild = 0;
}

final class _SiteTextSample {
  const _SiteTextSample({
    required this.text,
    required this.shallowText,
    required this.deepGamblingRisk,
    required this.complete,
    required this.visibilityComplete,
  });

  final String text, shallowText;
  final bool deepGamblingRisk, complete, visibilityComplete;
}

/// Traverse the inert DOM without the reader's depth limit or recursion.
/// Previously visible text retains its existing matching semantics. Newly
/// visible deep text needs both betting signals in one non-article text node;
/// it cannot combine with a shallow or unrelated node to create a strong hit.
_SiteTextSample _sampleSiteText(
  dom.Document document,
  Map<dom.Element, _SiteVisibility> visibility,
) {
  final buffers = _SiteTextBuffers();
  final stack = <_SiteTextFrame>[_SiteTextFrame(document, 0, false)];
  var visited = 0;
  var visibilityComplete = true, deepGamblingRisk = false;
  while (stack.isNotEmpty && buffers.withinBudget) {
    final frame = stack.last;
    final node = frame.node;
    final includeShallow = frame.depth <= 80;
    final state = node is dom.Element
        ? visibility[node]
        : node is dom.Text
        ? visibility[node.parent]
        : null;
    final block =
        node is dom.Element &&
        state?.visible != false &&
        _siteTextBlocks.contains(node.localName);
    if (!frame.entered) {
      if (++visited > _maxSiteTextNodes) {
        buffers.withinBudget = false;
        break;
      }
      frame.entered = true;
      if (node is dom.Element && state?.displayHidden == true) {
        stack.removeLast();
        continue;
      }
      if (node is dom.Text) {
        if (state?.visible == false) {
          if (state!.unknown &&
              !state.visibilityHidden &&
              node.data.trim().isNotEmpty) {
            visibilityComplete = false;
            // Unknown visibility remains an advisory clue, never a basis for
            // automatic isolation or a definitive visible-page statement.
            buffers.append(node.data, false);
          }
          stack.removeLast();
          continue;
        }
        final accepted = buffers.append(
          node.data,
          includeShallow && !frame.longForm,
        );
        if (!includeShallow &&
            !frame.longForm &&
            !deepGamblingRisk &&
            _gamblingBusiness.hasMatch(accepted) &&
            _gamblingPromotion.hasMatch(accepted)) {
          for (final line in _cleanAdultGateText(accepted).split('\n')) {
            if (_hasGamblingSignalOutsideWarning(line, _gamblingBusiness) &&
                _hasGamblingSignalOutsideWarning(line, _gamblingPromotion)) {
              deepGamblingRisk = true;
              break;
            }
          }
        }
        stack.removeLast();
        continue;
      }
      if (block) buffers.blockBreak(includeShallow);
    }
    if (frame.nextChild < node.nodes.length) {
      final child = node.nodes[frame.nextChild++];
      stack.add(
        _SiteTextFrame(
          child,
          frame.depth + 1,
          frame.longForm || (child is dom.Element && _longFormElement(child)),
        ),
      );
    } else {
      if (block) buffers.blockBreak(includeShallow);
      stack.removeLast();
    }
  }
  return _SiteTextSample(
    text: _cleanAdultGateText(buffers.all.toString()),
    shallowText: _cleanAdultGateText(buffers.shallow.toString()),
    deepGamblingRisk: deepGamblingRisk,
    complete: buffers.withinBudget,
    visibilityComplete: visibilityComplete,
  );
}

const _siteTextBlocks = {
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
};

final class _SiteTextBuffers {
  final all = StringBuffer(), shallow = StringBuffer();
  bool withinBudget = true;
  String append(String value, bool includeShallow) {
    final remaining = BookSiteInspector.maxBytes - all.length;
    final accepted = value.length <= remaining
        ? value
        : value.substring(0, remaining);
    all.write(accepted);
    if (includeShallow) shallow.write(accepted);
    if (accepted.length != value.length) withinBudget = false;
    return accepted;
  }

  void blockBreak(bool includeShallow) {
    if (all.isNotEmpty) {
      final remaining = BookSiteInspector.maxBytes - all.length;
      if (remaining == 0) {
        withinBudget = false;
      } else {
        all.write('\n');
      }
    }
    if (includeShallow && shallow.isNotEmpty) shallow.write('\n');
  }
}

const _maxSiteDomDepth = 512;
const _maxSiteDomNodes = 65536;

/// package:html's selector implementation recursively descends the DOM. This
/// preflight must run before any selector, Element.text or subordinate scan.
bool _siteDomWithinBudget(dom.Document document) {
  final pending = <(dom.Node, int)>[(document, 0)];
  var visited = 0;
  while (pending.isNotEmpty) {
    final (node, depth) = pending.removeLast();
    if (++visited > _maxSiteDomNodes || depth > _maxSiteDomDepth) return false;
    final children = node.nodes;
    if (children.length + pending.length > _maxSiteDomNodes - visited) {
      return false;
    }
    for (var i = children.length - 1; i >= 0; i--) {
      pending.add((children[i], depth + 1));
    }
  }
  return true;
}

/// Keep only weak text clues from the bounded part of an oversized tree. No
/// recursive selector, page script, text or URL is retained or executed.
BookSiteInspection _incompleteSiteDom(
  Uri target,
  dom.Document? document, {
  required bool truncated,
}) {
  var gambling = false, adult = false, visited = 0;
  final pending = <(dom.Node, int)>[if (document != null) (document, 0)];
  while (pending.isNotEmpty && visited++ < _maxSiteTextNodes) {
    final (node, depth) = pending.removeLast();
    if (depth > _maxSiteDomDepth) continue;
    if (node is dom.Text) {
      gambling = gambling || _gamblingBusiness.hasMatch(node.data);
      adult = adult || _adultBusiness.hasMatch(node.data);
      continue;
    }
    if (node is dom.Element &&
        (node.attributes.containsKey('hidden') ||
            const {
              'script',
              'style',
              'iframe',
              'object',
              'embed',
              'template',
              'noscript',
              'svg',
            }.contains(node.localName))) {
      continue;
    }
    final children = node.nodes;
    if (children.length + pending.length > _maxSiteTextNodes - visited) break;
    for (var i = children.length - 1; i >= 0; i--) {
      pending.add((children[i], depth + 1));
    }
  }
  final finding = gambling && adult
      ? BookSiteFinding.gamblingAndAdultClues
      : gambling
      ? BookSiteFinding.gamblingClue
      : adult
      ? BookSiteFinding.adultClue
      : BookSiteFinding.sampled;
  return BookSiteInspection(
    finding,
    truncated: truncated,
    textIncomplete: true,
    visibilityIncomplete: true,
    scriptReview: const BookPageScriptReview(
      coverage: BookPageScriptCoverage.partial,
    ),
    saleReview: BookPageSaleReview(
      coverage: BookPageSaleCoverage.partial,
      originSha256: bookSiteSaleOriginFingerprint(target),
    ),
  );
}

/// Parse inert HTML only. Do not render, execute scripts or fetch subresources.
BookSiteInspection inspectBookSiteHtml(
  Uri target,
  String input, {
  bool truncated = false,
}) {
  final dom.Document document;
  try {
    document = html.parse(input);
  } on StackOverflowError {
    return _incompleteSiteDom(target, null, truncated: truncated);
  }
  if (!_siteDomWithinBudget(document)) {
    return _incompleteSiteDom(target, document, truncated: truncated);
  }
  final stylesheetUnknown = _hasUnverifiedSiteStyles(document);
  final saleReview = _inspectSale(document, target, input, truncated);
  final scriptReview = _inspectScripts(document, target, truncated);
  final (refresh, externalRefresh) = _siteRefresh(document, target);
  for (final node in document.querySelectorAll(
    'script, style, iframe, object, embed, template, noscript, svg, [hidden]',
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
  final visibility = _siteVisibility(document);
  final sample = _sampleSiteText(document, visibility);
  final text = [sample.text, ...descriptions].join('\n');
  final shallowText = [sample.shallowText, ...descriptions].join('\n');
  final gambling = _gamblingBusiness.hasMatch(text);
  final adult = _adultBusiness.hasMatch(text);
  final title = document.querySelector('title')?.text ?? '';
  bool strongBetting(String text) =>
      _hasGamblingSignalOutsideWarning(text, _gamblingBusiness) &&
      _hasGamblingSignalOutsideWarning(text, _gamblingPromotion);
  // A stylesheet may hide ordinary DOM text; metadata remains independent of
  // its rendered visibility. Only an exact title/description pair may combine.
  final bettingRisk = stylesheetUnknown
      ? [title, ...descriptions].any(strongBetting) ||
            (_exactSiteSignal(_gamblingBusiness, title) &&
                descriptions.any(
                  (part) => _exactSiteSignal(_gamblingPromotion, part),
                ))
      : strongBetting(shallowText) || sample.deepGamblingRisk;
  final sitePurpose = _adultSitePurpose(title, descriptions);
  final adultBusiness = adult && _hasAdultBusinessOutsideWarning(text);
  final gate = adultBusiness && !sitePurpose && !stylesheetUnknown
      ? _hasWholeSiteAdultEntryGate(document, visibility)
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
    textIncomplete: !sample.complete,
    visibilityIncomplete: stylesheetUnknown || !sample.visibilityComplete,
    scriptReview: scriptReview,
    saleReview: saleReview,
    redirect: !refresh
        ? BookSiteRedirect.none
        : externalRefresh
        ? BookSiteRedirect.external
        : BookSiteRedirect.sameSite,
  );
}

(bool, bool) _siteRefresh(dom.Document document, Uri target) {
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
  return (refresh, externalRefresh);
}

bool _adultSitePurpose(String title, Iterable<String> descriptions) {
  final titleNamesAdultSite =
      !_adultSiteWarning.hasMatch(title) &&
      title
          .split(_adultClauseBoundary)
          .any(
            (part) =>
                _unscopedAdultClause(part) &&
                (_adultPurposeOutsideAwareness(part, _adultBusiness) ||
                    _adultPurposeOutsideAwareness(part, _adultSiteTitle)),
          );
  return descriptions.any(
    (description) =>
        !_adultSiteWarning.hasMatch(description) &&
        (titleNamesAdultSite && _adultSiteNameAndReading(description) ||
            description
                .split(_adultClauseBoundary)
                .any(
                  (part) =>
                      _unscopedAdultClause(part) &&
                      (titleNamesAdultSite &&
                              _adultPurposeOutsideAwareness(
                                part,
                                _adultSiteDescription,
                              ) ||
                          _adultPurposeOutsideAwareness(
                            part,
                            _exclusiveAdultDescription,
                          )),
                )),
  );
}

BookPageSaleReview _inspectSale(
  dom.Document document,
  Uri target,
  String input,
  bool truncated,
) {
  try {
    return inspectBookPageSale(document, target, input, truncated: truncated);
  } catch (_) {
    // A malformed sample cannot clear earlier observations.
    return const BookPageSaleReview();
  }
}

BookPageScriptReview _inspectScripts(
  dom.Document document,
  Uri target,
  bool truncated,
) {
  try {
    return inspectBookPageScripts(document, target, truncated: truncated);
  } catch (_) {
    // A malformed sample must not discard the independent adult/betting scan.
    // No exception detail or page text is retained.
    return const BookPageScriptReview(coverage: BookPageScriptCoverage.partial);
  }
}
