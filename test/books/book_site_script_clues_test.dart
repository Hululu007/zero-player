import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/features/books/data/book_site_check.dart';
import 'package:zero_player/features/books/data/book_site_inspection.dart';
import 'package:zero_player/features/books/data/book_site_script_clues.dart';
import 'package:zero_player/features/books/domain/book.dart';

import '../../test_support/http_test_server.dart';

final _origin = Uri.parse('https://book.example/');

BookSiteInspection _inspect(String body, {bool truncated = false}) =>
    inspectBookSiteHtml(_origin, body, truncated: truncated);

void main() {
  test(
    'literal cross-origin redirects are advisory and never risk markers',
    () {
      for (final script in [
        "location.href = 'https://other.example/path?private=token';",
        "window.location.replace('//other.example/x');",
        "location = 'http://book.example/';",
      ]) {
        final result = _inspect('<script>$script</script>');
        expect(
          result.scriptReview.clues,
          contains(BookPageScriptClue.crossOriginRedirect),
        );
        expect(result.scriptReview.coverage, BookPageScriptCoverage.sampled);
        expect(result.gamblingRisk, isFalse);
        expect(result.adultRisk, isFalse);
        expect(result.label, contains('跨源跳转写法，待复核'));
        expect(result.label, isNot(contains('other.example')));
        expect(result.label, isNot(contains('private=token')));
      }
      for (final script in [
        "location.href = 'https://BOOK.example:443/same';",
        "window.location.assign('/relative');",
        "other.location.href = 'https://other.example/';",
      ]) {
        expect(
          _inspect('<script>$script</script>').scriptReview.hasClues,
          isFalse,
        );
      }
    },
  );

  test('only directly nested decoding and dynamic evaluation is reported', () {
    for (final script in [
      "eval(atob('YWxlcnQoMSk='));",
      "window.eval(atob('YWxlcnQoMSk='));",
      "eval(window.atob('YWxlcnQoMSk='));",
      "eval(decodeURIComponent('%61%6c%65%72%74'));",
      'new Function(String.fromCharCode(97,108,101,114,116));',
    ]) {
      final result = _inspect('<script>$script</script>');
      expect(
        result.scriptReview.clues,
        contains(BookPageScriptClue.decodedDynamicEvaluation),
      );
      expect(result.scriptReview.coverage, BookPageScriptCoverage.sampled);
      expect(result.gamblingRisk, isFalse);
      expect(result.adultRisk, isFalse);
    }
    final alone = _inspect("<script>eval('ordinary');</script>").scriptReview;
    expect(alone.hasClues, isFalse);
    expect(alone.coverage, BookPageScriptCoverage.partial);
    expect(
      _inspect("<script>atob('YWxlcnQoMSk=');</script>").scriptReview.hasClues,
      isFalse,
    );
  });

  test('comments, strings and non-executable script types do not become code', () {
    final pages = [
      "<script>// location.href='https://other.example/'\nvar x=1;</script>",
      "<script>/* eval(atob('YWxlcnQoMSk=')) */ var x=1;</script>",
      '''<script>const text = "location.href='https://other.example/'";</script>''',
      '''<script>"location".href='https://other.example/';</script>''',
      '''<script>"window".location='https://other.example/';</script>''',
      '''<script>"eval"(atob('YWxlcnQoMSk='));</script>''',
      '''<script>"Function"(String.fromCharCode(97,108,101,114,116));</script>''',
      '''<script>eval("atob"('YWxlcnQoMSk='));</script>''',
      '''<script type="application/json">location.href='https://other.example/';</script>''',
      '''<script type="application/json" language="javascript">location.href='https://other.example/';</script>''',
      '''<script type="text/javascript; charset=utf-8">location.href='https://other.example/';</script>''',
      '''<script language="unknown">location.href='https://other.example/';</script>''',
      '''<template><script>location.href='https://other.example/';</script></template>''',
    ];
    for (final page in pages) {
      expect(_inspect(page).scriptReview.hasClues, isFalse, reason: page);
    }
  });

  test('legacy browser JavaScript type and language values are sampled', () {
    for (final attributes in [
      'type="application/x-javascript"',
      'type="text/javascript1.2"',
      'type="TEXT/JSCRIPT"',
      'language="JavaScript1.5"',
      'type="" language="unknown"',
    ]) {
      final result = _inspect(
        "<script $attributes>location.href='https://other.example/';</script>",
      );
      expect(
        result.scriptReview.clues,
        contains(BookPageScriptClue.crossOriginRedirect),
        reason: attributes,
      );
    }
  });

  test('ambiguous syntax, targets, source links and limits stay partial', () {
    for (final script in [
      "<!-- location.href='https://other.example/'\n",
      "const r=/location.href='https://other.example'/;",
      "const t=`location.href='https://other.example/'`;",
      "location.href = prefix + 'https://other.example/';",
      "window['location'] = 'https://other.example/';",
      "location.href = 'https://other.example:not-a-port/';",
      "location.href = 'https://other.example:99999/';",
      "location.href = 'https://other.example:999999999999999999999999999999999999/';",
      "location.href = 'https://user@other.example/';",
      "function f(location){ location.href='https://other.example/'; }",
    ]) {
      final result = _inspect('<script>$script</script>');
      expect(result.scriptReview.hasClues, isFalse, reason: script);
      expect(
        result.scriptReview.coverage,
        BookPageScriptCoverage.partial,
        reason: script,
      );
      expect(result.finding, BookSiteFinding.sampled);
      expect(result.label, isNot(contains('other.example')));
    }
    final linked = _inspect(
      "<script src='/external.js'>location.href='https://other.example/'</script>"
      "<iframe src='/frame'></iframe>",
    );
    expect(linked.scriptReview.hasClues, isFalse);
    expect(linked.scriptReview.coverage, BookPageScriptCoverage.partial);
    final tooMany = _inspect(
      List.filled(9, '<script>var x=1;</script>').join(),
    );
    expect(tooMany.scriptReview.coverage, BookPageScriptCoverage.partial);
    final tooLong = _inspect('<script>${'a' * 8193}</script>');
    expect(tooLong.scriptReview.coverage, BookPageScriptCoverage.partial);
    final truncated = _inspect(
      "<script>location.href='https://other.example/';</script>",
      truncated: true,
    );
    expect(truncated.scriptReview.coverage, BookPageScriptCoverage.partial);
    expect(
      truncated.scriptReview.clues,
      contains(BookPageScriptClue.crossOriginRedirect),
    );
  });

  test('persistence keeps finite codes only and migrates old checks fairly', () {
    final source = BookSource.fromJson({
      'name': '示例',
      'kind': 'text',
      'format': 'feed',
      'url': 'https://book.example/feed',
    });
    final now = DateTime.utc(2026, 11, 16);
    final inspection = _inspect(
      '<meta http-equiv="refresh" content="0;url=https://other.example/">'
      '<p>在线赌场</p>'
      "<script>location.href='https://private.example/?token=secret';</script>",
    );
    final original = BookSiteCheck(
      inspection,
      now,
      bookSourceCheckFingerprint(source),
    );
    final encoded = jsonEncode(original.toJson());
    expect(encoded, isNot(contains('private.example')));
    expect(encoded, isNot(contains('token=secret')));
    expect(encoded, isNot(contains('location.href')));
    final restored = BookSiteCheck.fromJson(jsonDecode(encoded), source)!;
    expect(restored.inspection.finding, BookSiteFinding.gamblingClue);
    expect(restored.inspection.redirect, BookSiteRedirect.external);
    expect(
      restored.inspection.scriptReview.clues,
      contains(BookPageScriptClue.crossOriginRedirect),
    );
    expect(restored.needsRetry, isTrue);
    final strong = _inspect(
      '<p>在线赌场 立即下注</p>'
      "<script>location.href='https://private.example/';</script>",
    );
    expect(strong.gamblingRisk, isTrue);
    expect(strong.scriptReview.hasClues, isTrue);

    final oldSuccessful = BookSiteCheck(
      const BookSiteInspection(BookSiteFinding.sampled),
      now,
      bookSourceCheckFingerprint(source),
    ).toJson()..remove('scriptReview');
    final old = BookSiteCheck.fromJson(oldSuccessful, source)!;
    expect(
      old.inspection.scriptReview.coverage,
      BookPageScriptCoverage.notChecked,
    );
    expect(old.isDue(now), isTrue);
    expect(old.toJson().containsKey('scriptReview'), isFalse);
    final oldFailure = BookSiteCheck(
      const BookSiteInspection(BookSiteFinding.timeout),
      now,
      bookSourceCheckFingerprint(source),
    ).toJson()..remove('scriptReview');
    final failure = BookSiteCheck.fromJson(oldFailure, source)!;
    expect(failure.isDue(now), isFalse);
    expect(failure.isDue(now.add(const Duration(minutes: 30))), isTrue);
  });

  test('homepage sampling never fetches linked scripts or frames', () async {
    final server = await HttpTestServer.start((request) {
      request.response.headers.set('content-type', 'text/html; charset=utf-8');
      request.response.write(
        "<script src='/external.js'></script><iframe src='/frame'></iframe>"
        "<script>location.href='https://other.example/';</script>",
      );
    });
    final http = MediaHttpClient(allowPrivateNetworks: true);
    addTearDown(http.close);
    addTearDown(server.close);
    final result = await BookSiteInspector(
      http,
    ).inspectTargetForTesting(server.baseUri, CancellationToken());
    expect(server.calls, {'/': 1});
    expect(result.scriptReview.coverage, BookPageScriptCoverage.partial);
    expect(
      result.scriptReview.clues,
      contains(BookPageScriptClue.crossOriginRedirect),
    );
  });
}
