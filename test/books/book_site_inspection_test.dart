import 'dart:async';
import 'dart:convert';
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
  test('unparsed styles cannot turn hidden content into strong evidence', () {
    for (final page in [
      '<style>.old-gate{display:none}</style>'
          '<div class="old-gate"><form>成人小说，本站仅限年满18岁访问</form></div>'
          '<p>普通书站</p>',
      '<link rel="stylesheet" href="/style.css">'
          '<form>成人小说，本站仅限年满18岁访问</form>',
      '<div style="opacity:0"><p>在线赌场 立即下注</p></div>',
    ]) {
      final result = inspectBookSiteHtml(target, page);
      expect(result.adultRisk, isFalse, reason: page);
      expect(result.gamblingRisk, isFalse, reason: page);
      if (!page.contains('opacity:0')) {
        expect(result.finding, BookSiteFinding.adultClue);
        expect(result.visibilityIncomplete, isTrue);
      }
    }
    for (final page in [
      '<div style="opacity:var(--alpha)">在线赌场 立即下注</div>',
      '<div aria-hidden="true">在线赌场 立即下注</div>',
      '<div style="display:none;display:block">在线赌场 立即下注</div>',
    ]) {
      final result = inspectBookSiteHtml(target, page);
      expect(result.finding, BookSiteFinding.gamblingClue);
      expect(result.gamblingRisk, isFalse);
      expect(result.visibilityIncomplete, isTrue);
      expect(result.label, contains('样式可见性未确认'));
    }
    final adult = inspectBookSiteHtml(
      target,
      '<style>.old-gate{display:none}</style>'
      '<title>成人小说网</title>'
      '<meta name="description" content="主要提供成人小说">',
    );
    expect(adult.adultRisk, isTrue);
    expect(adult.visibilityIncomplete, isTrue);
    final casino = inspectBookSiteHtml(
      target,
      '<style>body {font-weight:bold}</style>'
      '<title>在线赌场</title>'
      '<meta name="description" content="在线赌场 立即下注">',
    );
    expect(casino.gamblingRisk, isTrue);
    expect(casino.visibilityIncomplete, isTrue);
    final paired = inspectBookSiteHtml(
      target,
      '<title>在线赌场</title>'
      '<meta name="description" content="立即下注">'
      '<style>body{font-weight:bold}</style>',
    );
    expect(paired.gamblingRisk, isTrue);
    for (final page in [
      '<title>在线赌场案例研究</title><meta name="description" content="立即下注">'
          '<style>body{font-weight:bold}</style>',
      '<title>在线赌场</title><meta name="description" content="请勿立即下注">'
          '<style>body{font-weight:bold}</style>',
    ]) {
      expect(
        inspectBookSiteHtml(target, page).gamblingRisk,
        isFalse,
        reason: page,
      );
    }
    for (final description in ['研究在线赌场，立即下注的风险', '远离在线赌场，请勿立即下注']) {
      final warning = inspectBookSiteHtml(
        target,
        '<style>body {font-weight:bold}</style>'
        '<meta name="description" content="$description">',
      );
      expect(warning.gamblingRisk, isFalse, reason: description);
    }
  });

  test('article prose and local adult warnings remain weak clues', () {
    final story = inspectBookSiteHtml(
      target,
      '<article><h1>侦探小说</h1><p>他看见招牌写着“在线赌场，立即下注”，便转身离开。</p></article>',
    );
    expect(story.finding, BookSiteFinding.gamblingClue);
    expect(story.gamblingRisk, isFalse);
    final ad = inspectBookSiteHtml(
      target,
      '<article><p>他看见“在线赌场，立即下注”，便转身离开。</p></article>'
      '<p>博彩網站 註冊贈送</p>',
    );
    expect(ad.gamblingRisk, isTrue);
    const articleGate =
        '<article><p>小说中，他看到招牌写着：成人小说，本站仅限年满18岁访问。</p></article>';
    final adultStory = inspectBookSiteHtml(target, articleGate);
    expect(adultStory.finding, BookSiteFinding.adultClue);
    expect(adultStory.adultRisk, isFalse);
    final adultEntry = inspectBookSiteHtml(
      target,
      '$articleGate<form>成人小说，本站仅限年满18岁访问</form>',
    );
    expect(adultEntry.adultRisk, isTrue);
    final warning = inspectBookSiteHtml(
      target,
      '<form><p>本站仅限年满18岁访问</p><p>反对成人小说传播</p></form>',
    );
    expect(warning.finding, BookSiteFinding.adultClue);
    expect(warning.adultRisk, isFalse);
    final independent = inspectBookSiteHtml(
      target,
      '<form><p>反对成人小说传播</p><p>成人小说</p>'
      '<p>本站仅限年满18岁访问</p></form>',
    );
    expect(independent.adultRisk, isTrue);
    final report = inspectBookSiteHtml(
      target,
      '<title>成人小说传播治理研究</title>'
      '<meta name="description" content="主要提供成人小说传播治理研究资料">',
    );
    expect(report.adultRisk, isFalse);
    final separate = inspectBookSiteHtml(
      target,
      '<title>成人小说传播治理研究</title>'
      '<meta name="description" content="主要提供成人小说传播治理研究资料">'
      '<form>成人小说，本站仅限年满18岁访问</form>',
    );
    expect(separate.adultRisk, isTrue);
  });

  test('deep entry signals do not combine with unrelated text or prose', () {
    String deep(String content) => '${'<div>' * 90}$content${'</div>' * 90}';
    final betting = inspectBookSiteHtml(target, deep('<p>在线赌场 立即下注</p>'));
    expect(betting.gamblingRisk, isTrue);
    expect(betting.textIncomplete, isFalse);
    final adult = inspectBookSiteHtml(
      target,
      deep('<form><p>成人小说</p><p>本站仅限年满18岁访问</p></form>'),
    );
    expect(adult.adultRisk, isTrue);
    for (final page in [
      deep('<p>远离在线赌场，拒绝立即下注。</p>'),
      deep('<p><span>在线赌场</span><span>立即下注</span></p>'),
      '<p>在线赌场</p>${deep('<p>立即下注</p>')}',
      '<article>${deep('<p>在线赌场 立即下注</p>')}</article>',
      '<div class="chapter-content">${deep('<p>在线赌场 立即下注</p>')}</div>',
    ]) {
      expect(
        inspectBookSiteHtml(target, page).gamblingRisk,
        isFalse,
        reason: page,
      );
    }
    final novel = inspectBookSiteHtml(
      target,
      '<article>${deep('<form>成人小说，本站仅限年满18岁访问</form>')}</article>',
    );
    expect(novel.finding, BookSiteFinding.adultClue);
    expect(novel.adultRisk, isFalse);
  });

  test('incomplete text or response retains strong evidence and backs off', () {
    final source = BookSource.fromJson({
      'name': '预算样本',
      'url': target.toString(),
      'kind': 'text',
      'format': 'feed',
    });
    final sample = inspectBookSiteHtml(
      target,
      '<p>在线赌场 立即下注</p>${'<br>' * 16500}<p>未覆盖内容</p>',
    );
    expect(sample.gamblingRisk, isTrue);
    expect(sample.textIncomplete, isTrue);
    expect(sample.truncated, isFalse);
    expect(sample.label, contains('成人及博彩文字提取不完整'));
    final now = DateTime.utc(2026, 11, 16);
    var check = BookSiteCheck.after(sample, now, source, null);
    expect(check.needsRetry, isTrue);
    expect(check.nextDue, now.add(const Duration(minutes: 30)));
    for (var i = 0; i < 10; i++) {
      check = BookSiteCheck.after(sample, now, source, check);
    }
    expect(check.nextDue, now.add(const Duration(hours: 24)));
    final saved = check.toJson();
    final restored = BookSiteCheck.fromJson(saved, source)!;
    expect(restored.inspection.gamblingRisk, isTrue);
    expect(restored.inspection.textIncomplete, isTrue);
    expect(restored.needsRetry, isTrue);
    final old = BookSiteCheck.fromJson(
      {...saved}..remove('textIncomplete'),
      source,
    )!;
    expect(old.inspection.textIncomplete, isTrue);
    final damaged = BookSiteCheck.fromJson({
      ...saved,
      'textIncomplete': 'bad',
    }, source)!;
    expect(damaged.inspection.textIncomplete, isTrue);
    final response = BookSiteCheck.after(
      inspectBookSiteHtml(target, '<p>普通书站</p>', truncated: true),
      now,
      source,
      null,
    );
    expect(response.inspection.textIncomplete, isFalse);
    expect(response.needsRetry, isTrue);
    final lengthLimit = inspectBookSiteHtml(target, '<p>${'书' * 140000}</p>');
    expect(lengthLimit.textIncomplete, isTrue);
  });

  test('warnings and research do not identify a whole adult site', () {
    for (final page in [
      '<title>警惕成人小说网站，未成年人防护</title>'
          '<meta name="description" content="本站讲解如何识别成人小说网站，保护未成年人">',
      '<title>成人小说网站域名统计报告</title>'
          '<meta name="description" content="本报告统计成人小说网站域名注册数量">',
      '<title>成人小说网</title>'
          '<meta name="description" content="本站主要提供成人小说网站的统计数据">',
      '<title>成人小说网站域名统计报告</title>'
          '<meta name="description" content="成人小说网站域名统计报告，提供免费阅读">',
      '<title>成人小说网</title>'
          '<meta name="description" content="成人小说网站，提供免费阅读统计报告">',
    ]) {
      final result = inspectBookSiteHtml(target, page);
      expect(result.finding, BookSiteFinding.adultClue, reason: page);
      expect(result.adultRisk, isFalse, reason: page);
    }
    final separate = inspectBookSiteHtml(
      target,
      '<title>警惕成人小说网站</title>'
      '<meta name="description" content="本站讲解如何识别成人小说网站">'
      '<form><p>成人小说</p><p>本站仅限年满18岁访问</p></form>',
    );
    expect(separate.adultRisk, isTrue);
    final explicit = inspectBookSiteHtml(
      target,
      '<title>成人小说网</title>'
      '<meta name="description" content="本站专属成人小说网站，警惕网络诈骗">',
    );
    expect(explicit.adultRisk, isTrue);
    final named = inspectBookSiteHtml(
      target,
      '<title>成人小说网</title>'
      '<meta name="description" content="成人小说网站，提供免费阅读">',
    );
    expect(named.adultRisk, isTrue);
  });

  test(
    'clearly hidden and inert gates do not hide an independent visible one',
    () {
      for (final wrapper in [
        '<div style="display:none"><form>成人小说，本站仅限年满18岁访问</form></div>',
        '<div style="visibility:hidden"><form>成人小说，本站仅限年满18岁访问</form></div>',
        '<noscript><form>成人小说，本站仅限年满18岁访问</form></noscript>',
      ]) {
        final hidden = inspectBookSiteHtml(target, '<p>普通站点</p>$wrapper');
        expect(hidden.adultRisk, isFalse, reason: wrapper);
        final separate = inspectBookSiteHtml(
          target,
          '$wrapper<form><p>成人小说</p><p>本站仅限年满18岁访问</p></form>',
        );
        expect(separate.adultRisk, isTrue, reason: wrapper);
      }
      final overridden = inspectBookSiteHtml(
        target,
        '<div style="visibility:hidden"><form style="visibility:visible">'
        '成人小说，本站仅限年满18岁访问</form></div>',
      );
      expect(overridden.adultRisk, isTrue);
      final uncertain = inspectBookSiteHtml(
        target,
        '<div style="display:var(--state)">成人小说，本站仅限年满18岁访问</div>'
        '<form>成人小说，本站仅限年满18岁访问</form>',
      );
      expect(uncertain.adultRisk, isTrue);
      expect(uncertain.visibilityIncomplete, isTrue);
    },
  );

  test('only independent strong signals trigger automatic markers', () {
    final single = inspectBookSiteHtml(target, '<p>在线赌场</p>');
    expect(single.finding, BookSiteFinding.gamblingClue);
    expect(single.gamblingRisk, isFalse);
    final gambling = inspectBookSiteHtml(target, '<p>在线赌场 立即下注</p>');
    expect(gambling.gamblingRisk, isTrue);
    final adult = inspectBookSiteHtml(
      target,
      '<title>成人小说网</title>'
      '<meta name="description" content="主要提供成人小说">',
    );
    expect(adult.adultRisk, isTrue);
    expect(inspectBookSiteHtml(target, '<p>成人小说</p>').adultRisk, isFalse);
    expect(inspectBookSiteHtml(target, '<p>年满18岁</p>').adultRisk, isFalse);
    expect(
      inspectBookSiteHtml(target, '<p>成人小说，请确认年满18岁</p>').adultRisk,
      isFalse,
    );
    final inert = inspectBookSiteHtml(
      target,
      '<script>在线赌场 立即下注 成人小说 年满18岁</script><p>普通书目</p>',
    );
    expect(inert.finding, BookSiteFinding.sampled);
    expect(inert.gamblingRisk, isFalse);
    expect(inert.adultRisk, isFalse);
  });

  test('adult comics and traditional Chinese require whole-site evidence', () {
    for (final html in [
      '<title>成人漫画网站</title>'
          '<meta name="description" content="主要提供成人漫画">',
      '<title>色情漫畫網站</title>'
          '<meta name="description" content="主要提供色情漫畫">',
      '<form><p>成人小說</p><p>本站僅限年滿１８歲瀏覽</p></form>',
    ]) {
      expect(inspectBookSiteHtml(target, html).adultRisk, isTrue, reason: html);
    }
    for (final html in [
      '<p>成人漫畫</p>',
      '<p>未滿１８歲</p>',
      '<p>成人漫画，请确认年满18岁</p>',
      '<p>色情漫畫，未滿１８歲請勿進入</p>',
      '<p>成人小說，成人專區</p>',
    ]) {
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
        isFalse,
      );
    },
  );

  test('unrelated category text does not negate a site-wide purpose', () {
    for (final html in [
      '<title>成人小说网</title>'
          '<meta name="description" content="本站专属成人小说网站，分类包括玄幻">',
      '<title>成人漫画网站 | 最新推荐</title>'
          '<meta name="description" content="主要提供成人漫画，分类包括科幻">',
      '<meta name="description" content="本站专属成人小说网站，推荐近期作品">',
    ]) {
      expect(inspectBookSiteHtml(target, html).adultRisk, isTrue, reason: html);
    }
    for (final html in [
      '<title>成人小说专题 | 热门推荐</title>'
          '<meta name="description" content="本站提供普通小说和成人小说分类">',
      '<title>成人小说网</title>'
          '<meta name="description" content="成人小说网站推荐，分类包括玄幻">',
      '<title>抵制，成人小说网</title>'
          '<meta name="description" content="主要提供成人小说">',
    ]) {
      expect(
        inspectBookSiteHtml(target, html).adultRisk,
        isFalse,
        reason: html,
      );
    }
  });

  test(
    'mixed-site sections, notices and advertisements do not mark the host',
    () {
      for (final html in [
        '<title>普通小说网</title>'
            '<meta name="description" content="提供普通小说和成人小说分类">'
            '<p>普通小说</p><a href="/adult">成人小说专区</a>'
            '<p>未成年人禁止进入成人专区</p>',
        '<title>成人小说专题</title>'
            '<meta name="description" content="成人小说网站推荐">'
            '<p>普通小说与成人小说，请确认年满18岁</p>',
        '<title>普通小说</title><meta name="description" content="正版小说">'
            '<aside class="advertisement"><p>广告：成人小说，请确认年满18岁</p>'
            '<form>成人小说 本站仅限年满18岁访问</form></aside>',
        '<title>普通小说</title><meta name="description" content="正版小说">'
            '<div class="ad-banner"><form>成人小说 本站仅限年满18岁访问</form></div>',
        '<form>普通小说与成人小说专区，本站仅限年满18岁访问</form>',
        '<p>抵制色情小说。</p><p>普通小说与成人小说专区，未满18岁禁止浏览。</p>',
      ]) {
        final result = inspectBookSiteHtml(target, html);
        expect(result.finding, BookSiteFinding.adultClue, reason: html);
        expect(result.adultRisk, isFalse, reason: html);
      }
    },
  );

  test('a clear whole-site age-gate form supports an adult-site finding', () {
    for (final html in [
      '<form><h1>成人小说</h1><p>本站仅限年满18岁访问</p>'
          '<button>确认进入本站</button></form>',
      '<form><p>成人小说</p><p>本站仅限年满18岁进入</p>'
          '<p>分类包括玄幻</p></form>',
      '<div role="dialog"><h1>色情漫畫</h1>'
          '<p>本網站僅限年滿１８歲瀏覽</p></div>',
    ]) {
      expect(inspectBookSiteHtml(target, html).adultRisk, isTrue, reason: html);
    }
  });

  test('a local explicit whole-site age gate needs no form', () {
    for (final html in [
      '<p>成人小说，本站仅限年满18岁进入</p>',
      '<div><span>成人小说</span><span>，本站仅限年满18岁进入</span></div>',
      '<p>成人小说，本站仅限年满18岁进入，分类包括玄幻</p>',
      '<h1>成人漫畫，本網站僅限年滿１８歲瀏覽</h1>',
    ]) {
      expect(inspectBookSiteHtml(target, html).adultRisk, isTrue, reason: html);
    }
    for (final html in [
      '<p>成人小说专区，本站仅限年满18岁进入成人专区</p>',
      '<div><h2>成人小说专区</h2>'
          '<p>成人小说，本站仅限年满18岁进入</p></div>',
      '<div>成人小说专区<p>成人小说，本站仅限年满18岁进入</p></div>',
      '<form>成人小说专区<section>'
          '<p>成人小说，本站仅限年满18岁进入</p></section></form>',
      '<div class="ad-banner"><p>成人小说，本站仅限年满18岁进入</p></div>',
      '<div>广告<p>成人小说，本站仅限年满18岁进入</p></div>',
      '<p>本站提示：成人小说，请确认年满18岁</p>',
      '<div><p>成人小说</p><p>本站仅限年满18岁进入</p></div>',
    ]) {
      final result = inspectBookSiteHtml(target, html);
      expect(result.finding, BookSiteFinding.adultClue, reason: html);
      expect(result.adultRisk, isFalse, reason: html);
    }
  });

  test('nested advertising does not cause unbounded ancestor checks', () {
    final input =
        '<p>成人小说</p><div class="ad">'
        '${'<div>' * 1000}'
        '${'<p>成人小说，本站仅限年满18岁进入</p>' * 350}'
        '${'</div>' * 1000}</div>';
    expect(utf8.encode(input).length, lessThan(BookSiteInspector.maxBytes));
    final result = inspectBookSiteHtml(target, input);
    expect(result.finding, BookSiteFinding.adultClue);
    expect(result.adultRisk, isFalse);
    expect(result.truncated, isFalse);
  });

  test('nested entry containers report and persist an exhausted budget', () {
    final input =
        '<p>成人小说 在线赌场 立即下注</p>'
        '${'<div role="dialog">' * 70}'
        '<p>${'普通' * 6000}</p>'
        '${'</div>' * 70}';
    expect(utf8.encode(input).length, lessThan(BookSiteInspector.maxBytes));
    final result = inspectBookSiteHtml(target, input);
    expect(result.finding, BookSiteFinding.gamblingAndAdultClues);
    expect(result.gamblingRisk, isTrue);
    expect(result.adultRisk, isFalse);
    expect(result.truncated, isTrue);
    expect(result.label, contains('首页静态检查覆盖不完整'));
    expect(result.label, contains('疑似成人文字线索，待复核'));

    final source = BookSource.fromJson({
      'name': '示例',
      'url': target.toString(),
      'kind': 'text',
      'format': 'feed',
    });
    final earlier = BookSiteCheck.after(
      inspectBookSiteHtml(
        target,
        "<script>location.href='https://other.example/';</script>",
      ),
      DateTime.fromMillisecondsSinceEpoch(
        DateTime.now()
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
      ),
      source,
      null,
    );
    expect(earlier.pendingScriptClues, isNotEmpty);
    final saved = BookSiteCheck.after(result, DateTime.now(), source, earlier);
    final restored = BookSiteCheck.fromJson(saved.toJson(), source)!;
    expect(restored.inspection.truncated, isTrue);
    expect(restored.inspection.gamblingRisk, isTrue);
    expect(restored.inspection.label, contains('首页静态检查覆盖不完整'));
    expect(restored.inspection.label, contains('疑似成人文字线索，待复核'));
    expect(restored.historicalScriptClues, earlier.pendingScriptClues);

    final explicitSite = inspectBookSiteHtml(
      target,
      '<title>成人小说网</title>'
      '<meta name="description" content="主要提供成人小说">$input',
    );
    expect(explicitSite.adultRisk, isTrue);
    expect(explicitSite.gamblingRisk, isTrue);
  });
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
        '<title>成人小说网</title>'
        '<meta name="description" content="主要提供成人小说">',
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
      expect(restored.needsRetry, isTrue);
      expect(
        restored.nextDue.difference(restored.checkedAt),
        const Duration(minutes: 30),
      );
      final combinedLegacy = current.toJson()..remove('consecutiveFailures');
      final oldCombined = BookSiteCheck.fromJson(combinedLegacy, source)!;
      expect(oldCombined.needsRetry, isTrue);
      expect(oldCombined.inspection.finding, BookSiteFinding.gamblingClue);
      expect(oldCombined.inspection.redirect, BookSiteRedirect.external);
      final strong = BookSiteCheck(
        adult,
        DateTime.now(),
        bookSourceCheckFingerprint(source),
      );
      final restoredStrong = BookSiteCheck.fromJson(strong.toJson(), source)!;
      expect(restoredStrong.needsRetry, isTrue);
      expect(restoredStrong.inspection.adultRisk, isTrue);
      expect(restoredStrong.inspection.redirect, BookSiteRedirect.sameSite);
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
    'real HTTP deep DOM becomes incomplete without losing prior clues',
    () async {
      final page = '${'<div>' * 11000}<p>普通页面</p>${'</div>' * 11000}';
      expect(utf8.encode(page).length, lessThan(BookSiteInspector.maxBytes));
      final server = await HttpTestServer.start((request) {
        request.response.headers.contentType = ContentType.html;
        request.response.write(page);
      });
      final http = MediaHttpClient(allowPrivateNetworks: true);
      addTearDown(http.close);
      addTearDown(server.close);
      final result = await BookSiteInspector(http)
          .inspectTargetForTesting(server.baseUri, CancellationToken())
          .timeout(const Duration(seconds: 15));
      expect(result.truncated, isFalse);
      expect(result.textIncomplete, isTrue);
      expect(result.visibilityIncomplete, isTrue);
      expect(result.scriptReview.coverage.name, 'partial');
      expect(result.saleReview.coverage.name, 'partial');
      expect(result.gamblingRisk, isFalse);
      expect(result.adultRisk, isFalse);
      expect(server.calls, {'/': 1});

      final root = Uri.parse('https://history.example/');
      final source = BookSource.fromJson({
        'name': '历史线索',
        'url': root.toString(),
        'kind': 'text',
        'format': 'feed',
      });
      final before = BookSiteCheck.after(
        inspectBookSiteHtml(
          root,
          '<html><body><h1>This domain is for sale</h1>'
          '<h3>Contact the owner</h3><form></form>'
          "<script>location.href='https://other.example/'</script>"
          '</body></html>',
        ),
        DateTime.utc(2026, 11, 15),
        source,
        null,
      );
      expect(before.pendingScriptClues, isNotEmpty);
      expect(before.pendingSaleClue, isNotNull);
      final after = BookSiteCheck.after(
        result,
        DateTime.utc(2026, 11, 16),
        source,
        before,
      );
      expect(after.needsRetry, isTrue);
      expect(after.historicalScriptClues, before.pendingScriptClues);
      expect(after.historicalSaleClue, before.pendingSaleClue);
      final restored = BookSiteCheck.fromJson(after.toJson(), source)!;
      expect(
        restored.historicalScriptClues.keys,
        before.pendingScriptClues.keys,
      );
      for (final clue in before.pendingScriptClues.keys) {
        expect(
          restored.historicalScriptClues[clue]!.millisecondsSinceEpoch,
          before.pendingScriptClues[clue]!.millisecondsSinceEpoch,
        );
      }
      expect(
        restored.historicalSaleClue!.millisecondsSinceEpoch,
        before.pendingSaleClue!.millisecondsSinceEpoch,
      );
    },
  );

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
