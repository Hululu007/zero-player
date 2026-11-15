import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../../../core/network/document_encoding.dart';
import '../../../core/network/header_policy.dart';
import '../../../core/network/media_http_client.dart';
import '../../../core/network/request_scheduler.dart';
import '../domain/book.dart';
import 'book_html.dart';
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
  });

  final BookSiteFinding finding;

  /// These require independently supported business and solicitation, age,
  /// or site-purpose clues. One isolated keyword cannot trigger a block.
  final bool gamblingRisk, adultRisk, truncated;
  final int? statusCode;
  final BookSiteRedirect redirect;
  final BookPageScriptReview scriptReview;

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
          };
    final parts = [signal];
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
    if (scriptReview.clues.contains(BookPageScriptClue.crossOriginRedirect)) {
      parts.add('内联脚本含跨源跳转写法，待复核');
    }
    if (scriptReview.clues.contains(
      BookPageScriptClue.decodedDynamicEvaluation,
    )) {
      parts.add('内联脚本含解码后动态求值写法，待复核');
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
  r'[^，。；;\n]{0,20}(?:成人(?:小说|小說)|色情(?:小说|小說)|肉文|肉漫)',
);
final _adultSiteWarning = RegExp(
  r'抵制|远离|遠離|打击|打擊|不提供|不收录|不收錄|拒绝|拒絕|'
  r'禁止(?:传播|傳播|提供|访问|訪問)|危害|举报|舉報',
);
final _adultGate = RegExp(
  r'(?:年|未)?(?:满|滿)\s*(?:[1１][8８]|十八)\s*(?:岁|歲)|'
  r'未成年人(?:禁止|请勿|請勿)|成人(?:专用|專用|专区|專區)',
);

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
      (_adultBusiness.hasMatch(title) || _adultSiteTitle.hasMatch(title)) &&
      !_adultSiteWarning.hasMatch(title);
  final sitePurpose =
      titleNamesAdultSite &&
      descriptions.any(
        (description) =>
            _adultSiteDescription.hasMatch(description) &&
            !_adultSiteWarning.hasMatch(description),
      );
  final adultRisk =
      adult &&
      _hasAdultBusinessOutsideWarning(text) &&
      (_adultGate.hasMatch(text) || sitePurpose);
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
    truncated: truncated,
    scriptReview: scriptReview,
    redirect: !refresh
        ? BookSiteRedirect.none
        : externalRefresh
        ? BookSiteRedirect.external
        : BookSiteRedirect.sameSite,
  );
}
