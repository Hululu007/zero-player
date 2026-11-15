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
  });

  final BookSiteFinding finding;

  /// These require both a business-specific and a separate solicitation or
  /// age-gate signal. A single word must never trigger an automatic block.
  final bool gamblingRisk, adultRisk, truncated;
  final int? statusCode;
  final BookSiteRedirect redirect;

  String get label {
    final signal = gamblingRisk && adultRisk
        ? '博彩及成人强线索'
        : gamblingRisk
        ? '博彩强线索'
        : adultRisk
        ? '成人强线索'
        : switch (finding) {
            BookSiteFinding.sampled =>
              truncated ? '页面抽样未见明显线索（已截断）' : '页面抽样未见明显线索',
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
    if (finding == BookSiteFinding.sameSiteRedirect ||
        finding == BookSiteFinding.externalRedirect) {
      return signal;
    }
    return switch (redirect) {
      BookSiteRedirect.none => signal,
      BookSiteRedirect.sameSite => '$signal · 页面跳转，未跟随',
      BookSiteRedirect.external => '$signal · 跨站跳转，未跟随，待复核',
    };
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
  r'在线赌场|网络赌场|澳门赌场|真人百家乐|博彩开户|投注平台|体育投注|真人博彩|博彩平台',
  caseSensitive: false,
);
final _gamblingPromotion = RegExp(
  r'立即下注|立即投注|注册(?:领取|赠送|送彩金)|开户(?:送彩金|送|领取)|首存(?:优惠|奖励|赠送)|充值(?:返水|送|赠)',
  caseSensitive: false,
);
final _adultBusiness = RegExp(
  r'成人视频|色情小说|成人小说|情色小说|色情视频|无码视频',
  caseSensitive: false,
);
final _adultGate = RegExp(
  r'年满\s*18\s*岁|满\s*18\s*岁|未满\s*18\s*岁|未成年人禁止|未成年人请勿|成人专用|成人专区',
);

/// Parse inert HTML only. Do not render, execute scripts or fetch subresources.
BookSiteInspection inspectBookSiteHtml(
  Uri target,
  String input, {
  bool truncated = false,
}) {
  final document = html.parse(input);
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
    'script, style, iframe, object, embed, template, svg',
  )) {
    node.remove();
  }
  final text = plainBookText(document, limit: BookSiteInspector.maxBytes);
  final gambling = _gamblingBusiness.hasMatch(text);
  final adult = _adultBusiness.hasMatch(text);
  final bettingRisk = gambling && _gamblingPromotion.hasMatch(text);
  final adultRisk = adult && _adultGate.hasMatch(text);
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
    redirect: !refresh
        ? BookSiteRedirect.none
        : externalRefresh
        ? BookSiteRedirect.external
        : BookSiteRedirect.sameSite,
  );
}
