import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/features/books/application/book_site_checks.dart';
import 'package:zero_player/features/books/data/book_site_inspection.dart';
import 'package:zero_player/features/books/domain/book.dart';

import '../../test_support/http_test_server.dart';

void main() {
  final target = Uri.parse('https://book.example/');
  _contentSignalTests(target);
  _redirectInterpretationTests(target);
  _httpResponseTests();
  _cancellationTests();
}

void _contentSignalTests(Uri target) {
  test('only independent strong signals trigger automatic markers', () {
    final single = inspectBookSiteHtml(target, '<p>在线赌场</p>');
    expect(single.finding, BookSiteFinding.gamblingClue);
    expect(single.gamblingRisk, isFalse);
    final gambling = inspectBookSiteHtml(target, '<p>在线赌场 立即下注</p>');
    expect(gambling.gamblingRisk, isTrue);
    final adult = inspectBookSiteHtml(target, '<p>成人小说，请确认年满18岁</p>');
    expect(adult.adultRisk, isTrue);
    expect(inspectBookSiteHtml(target, '<p>成人小说</p>').adultRisk, isFalse);
    expect(inspectBookSiteHtml(target, '<p>年满18岁</p>').adultRisk, isFalse);
    final inert = inspectBookSiteHtml(
      target,
      '<script>在线赌场 立即下注 成人小说 年满18岁</script><p>普通书目</p>',
    );
    expect(inert.finding, BookSiteFinding.sampled);
    expect(inert.gamblingRisk, isFalse);
    expect(inert.adultRisk, isFalse);
  });

  test('adult comics and traditional Chinese require two strong clues', () {
    for (final html in [
      '<p>成人漫画，请确认年满18岁</p>',
      '<p>色情漫畫，未滿１８歲請勿進入</p>',
      '<p>成人小說，成人專區</p>',
    ]) {
      expect(inspectBookSiteHtml(target, html).adultRisk, isTrue, reason: html);
    }
    for (final html in ['<p>成人漫畫</p>', '<p>未滿１８歲</p>']) {
      expect(
        inspectBookSiteHtml(target, html).adultRisk,
        isFalse,
        reason: html,
      );
    }
    final inert = inspectBookSiteHtml(
      target,
      '<script>成人漫畫 未滿１８歲</script><p>普通漫畫</p>',
    );
    expect(inert.adultRisk, isFalse);
  });

  test('common traditional gambling terms still require a promotion', () {
    for (final html in [
      '<p>線上賭場 立即下注</p>',
      '<p>博彩網站 註冊贈送</p>',
      '<p>體育博彩 首存優惠</p>',
    ]) {
      expect(
        inspectBookSiteHtml(target, html).gamblingRisk,
        isTrue,
        reason: html,
      );
    }
    for (final html in ['<p>線上賭場</p>', '<p>立即下注</p>']) {
      expect(
        inspectBookSiteHtml(target, html).gamblingRisk,
        isFalse,
        reason: html,
      );
    }
  });

  test(
    'anti-gambling warnings remain clues rather than automatic isolation',
    () {
      for (final html in [
        '<p>防诈骗警示：远离在线赌场，拒绝立即下注。</p>',
        '<p>遠離線上賭場，請勿立即下注。</p>',
        '<p>在线赌场与立即下注均属于诈骗陷阱。</p>',
        '<p>在线赌场，不要立即下注。</p>',
        '<meta name="description" content="抵制博彩网站，请勿立即投注">',
      ]) {
        final result = inspectBookSiteHtml(target, html);
        expect(result.finding, BookSiteFinding.gamblingClue, reason: html);
        expect(result.gamblingRisk, isFalse, reason: html);
      }
    },
  );

  test(
    'nearby warning does not suppress a separate gambling advertisement',
    () {
      for (final html in [
        '<p>远离在线赌场，拒绝立即下注。</p>'
            '<p>线上赌场 <a>立即下注</a></p>',
        '<p>遠離線上賭場，請勿立即下注。</p>'
            '<p>博彩網站 <span>註冊贈送</span></p>',
        '<p>远离在线赌场，拒绝立即下注。</p>'
            '<div>线上赌场</div><div>首存优惠</div>',
        '<p>远离在线赌场 线上赌场 立即下注</p>',
        '<p>不要错过线上赌场 立即下注</p>',
      ]) {
        expect(
          inspectBookSiteHtml(target, html).gamblingRisk,
          isTrue,
          reason: html,
        );
      }
    },
  );

  test('a warning or one promotional signal cannot form a risk by itself', () {
    for (final html in [
      '<p>在线赌场，拒绝立即下注。</p>',
      '<p>远离在线赌场，立即下注。</p>',
      '<p>请勿立即下注。</p>',
      '<p>博彩網站</p>',
    ]) {
      expect(
        inspectBookSiteHtml(target, html).gamblingRisk,
        isFalse,
        reason: html,
      );
    }
  });

  test('hidden elements cannot automatically classify the homepage', () {
    final hidden = inspectBookSiteHtml(
      target,
      '<div hidden>線上賭場 立即下注</div>'
      '<section hidden="hidden">成人漫畫 未滿１８歲</section>'
      '<p>普通书目</p>',
    );
    expect(hidden.finding, BookSiteFinding.sampled);
    expect(hidden.gamblingRisk, isFalse);
    expect(hidden.adultRisk, isFalse);
  });

  test('site description can provide clues but keywords alone cannot', () {
    final described = inspectBookSiteHtml(
      target,
      '<meta name="DESCRIPTION" content="专属肉文，未满十八岁禁止浏览">'
      '<p>普通首页</p>',
    );
    expect(described.adultRisk, isTrue);
    final keywords = inspectBookSiteHtml(
      target,
      '<meta name="keywords" content="成人漫画 未满十八岁">'
      '<p>普通首页</p>',
    );
    expect(keywords.adultRisk, isFalse);
  });

  test(
    'explicit adult site title and purpose can classify without an age gate',
    () {
      for (final html in [
        '<title>免费成人黄色小说</title>'
            '<meta name="description" content="免费的在线成人黄色小说站">',
        '<title>高辣文小说网</title>'
            '<meta name="description" content="主要提供耽美肉文、言情文">',
        '<meta name="description" content="专属18禁情欲类小说，未满十八岁禁止浏览">',
      ]) {
        expect(
          inspectBookSiteHtml(target, html).adultRisk,
          isTrue,
          reason: html,
        );
      }
      for (final html in [
        '<title>成人小说专题</title>'
            '<meta name="description" content="提供玄幻小说及成人小说分类">',
        '<title>抵制成人小说</title>'
            '<meta name="description" content="本站坚决抵制成人小说网站">',
        '<p>抵制成人小说，未满18岁尤其要注意。</p>',
        '<p>远离色情小说。</p><p>未满18岁应由家长陪同浏览。</p>',
      ]) {
        expect(
          inspectBookSiteHtml(target, html).adultRisk,
          isFalse,
          reason: html,
        );
      }
      expect(
        inspectBookSiteHtml(
          target,
          '<p>抵制色情小说。</p><p>成人小说专区，未满18岁禁止浏览。</p>',
        ).adultRisk,
        isTrue,
      );
    },
  );
}

void _redirectInterpretationTests(Uri target) {
  test('reports meta redirects without loading their target', () {
    expect(
      inspectBookSiteHtml(
        target,
        '<meta http-equiv="refresh" content="0; url=https://other.example/">',
      ).finding,
      BookSiteFinding.externalRedirect,
    );
    expect(
      inspectBookSiteHtml(
        target,
        '<meta http-equiv="refresh" content="0; url=/new">',
      ).finding,
      BookSiteFinding.sameSiteRedirect,
    );
  });

  test(
    'text clues and meta redirects survive together and old checks load',
    () {
      final mixed = inspectBookSiteHtml(
        target,
        '<meta http-equiv="refresh" content="0; url=https://other.example/">'
        '<p>在线赌场</p>',
      );
      expect(mixed.finding, BookSiteFinding.gamblingClue);
      expect(mixed.redirect, BookSiteRedirect.external);
      expect(mixed.label, contains('博彩文字线索'));
      expect(mixed.label, contains('跨站跳转'));
      expect(mixed.gamblingRisk, isFalse);
      final adult = inspectBookSiteHtml(
        target,
        '<meta http-equiv="refresh" content="0; url=/other">'
        '<p>成人小说，请确认年满18岁</p>',
      );
      expect(adult.adultRisk, isTrue);
      expect(adult.redirect, BookSiteRedirect.sameSite);
      expect(adult.label, contains('成人强线索'));
      expect(adult.label, contains('页面跳转'));

      final source = BookSource.fromJson({
        'name': '示例',
        'url': target.toString(),
        'kind': 'text',
        'format': 'feed',
      });
      final current = BookSiteCheck(
        mixed,
        DateTime.now(),
        bookSourceCheckFingerprint(source),
      );
      final restored = BookSiteCheck.fromJson(current.toJson(), source)!;
      expect(restored.inspection.redirect, BookSiteRedirect.external);
      expect(restored.inspection.label, contains('博彩文字线索'));
      expect(restored.inspection.label, contains('跨站跳转'));
      final legacy = current.toJson()
        ..remove('redirect')
        ..['finding'] = BookSiteFinding.externalRedirect.name;
      final old = BookSiteCheck.fromJson(legacy, source)!;
      expect(old.inspection.redirect, BookSiteRedirect.external);
      expect(old.inspection.label, contains('跨站跳转'));
    },
  );
}

void _httpResponseTests() {
  test('transport never follows an HTTP redirect', () async {
    final server = await HttpTestServer.start((request) {
      if (request.uri.path == '/') {
        request.response.statusCode = 302;
        request.response.headers.set(HttpHeaders.locationHeader, '/second');
      }
    });
    final http = MediaHttpClient(allowPrivateNetworks: true);
    addTearDown(http.close);
    addTearDown(server.close);
    final result = await BookSiteInspector(
      http,
    ).inspectTargetForTesting(server.baseUri, CancellationToken());
    expect(result.finding, BookSiteFinding.sameSiteRedirect);
    expect(server.calls, {'/': 1});
  });

  test('large response is sampled at the hard limit', () async {
    final server = await HttpTestServer.start((request) {
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        '<p>${'x' * BookSiteInspector.maxBytes}在线赌场 立即下注</p>',
      );
    });
    final http = MediaHttpClient(allowPrivateNetworks: true);
    addTearDown(http.close);
    addTearDown(server.close);
    final result = await BookSiteInspector(
      http,
    ).inspectTargetForTesting(server.baseUri, CancellationToken());
    expect(result.truncated, isTrue);
    expect(result.finding, BookSiteFinding.sampled);
    expect(result.gamblingRisk, isFalse);
  });

  test(
    'HTTP errors remain unconfirmed rather than permanent failure',
    () async {
      final server = await HttpTestServer.start((request) {
        request.response.statusCode = 403;
      });
      final http = MediaHttpClient(allowPrivateNetworks: true);
      addTearDown(http.close);
      addTearDown(server.close);
      final result = await BookSiteInspector(
        http,
      ).inspectTargetForTesting(server.baseUri, CancellationToken());
      expect(result.finding, BookSiteFinding.httpError);
      expect(result.statusCode, 403);
    },
  );
}

void _cancellationTests() {
  test(
    'timeout and explicit cancellation do not become safety results',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final server = await HttpTestServer.start((request) async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      });
      final http = MediaHttpClient(allowPrivateNetworks: true);
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        http.close();
      });
      addTearDown(server.close);
      final short = BookSiteInspector(
        http,
        requestTimeout: const Duration(milliseconds: 50),
      );
      final timed = short.inspectTargetForTesting(
        server.baseUri,
        CancellationToken(),
      );
      await entered.future;
      expect((await timed).finding, BookSiteFinding.timeout);
      final token = CancellationToken();
      final cancelled = BookSiteInspector(
        http,
      ).inspectTargetForTesting(server.baseUri, token);
      token.cancel();
      await expectLater(cancelled, throwsA(isA<RequestCancelled>()));
    },
  );
}
