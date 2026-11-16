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

Map<BookPageScriptClue, int> _timestamps(
  Map<BookPageScriptClue, DateTime> clues,
) => {
  for (final entry in clues.entries)
    entry.key: entry.value.millisecondsSinceEpoch,
};

void main() {
  test(
    'literal cross-origin redirects are advisory and never risk markers',
    () {
      for (final script in [
        "location.href = 'https://other.example/path?private=token';",
        "window.location.replace('//other.example/x');",
        "globalThis.location.href = 'https://other.example/';",
        "self.location.assign('https://other.example/');",
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
        "other.self.location.href = 'https://other.example/';",
        "other.globalThis.location.href = 'https://other.example/';",
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
      '''<script>"self".location='https://other.example/';</script>''',
      '''<script>"globalThis".location='https://other.example/';</script>''',
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
      "self['location'] = 'https://other.example/';",
      "location.href = 'https://other.example:not-a-port/';",
      "location.href = 'https://other.example:99999/';",
      "location.href = 'https://other.example:999999999999999999999999999999999999/';",
      "location.href = 'https://user@other.example/';",
      "function f(location){ location.href='https://other.example/'; }",
      "function f(self){ self.location='https://other.example/'; }",
      "function f(globalThis = {}) { globalThis.location='https://other.example/'; }",
      "const helper=1, self={}; self.location='https://other.example/';",
      "const f = self => self.location='https://other.example/';",
      "function f({self}) { self.location='https://other.example/'; }",
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

  test(
    'incomplete checks preserve each clue and complete samples resolve it',
    () {
      final source = BookSource.fromJson({
        'name': '历史样本',
        'kind': 'text',
        'format': 'feed',
        'url': 'https://book.example/feed',
        'sourceKey': 'fixture:history',
      });
      final t1 = DateTime.utc(2026, 11, 16, 8);
      final first = BookSiteCheck.after(
        _inspect("<script>location.href='https://other.example/';</script>"),
        t1,
        source,
        null,
      );
      final timeout = BookSiteCheck.after(
        const BookSiteInspection(BookSiteFinding.timeout),
        t1.add(const Duration(minutes: 1)),
        source,
        first,
      );
      expect(timeout.inspection.scriptReview.hasClues, isFalse);
      expect(
        timeout
            .historicalScriptClues[BookPageScriptClue.crossOriginRedirect]!
            .millisecondsSinceEpoch,
        t1.millisecondsSinceEpoch,
      );
      expect(timeout.consecutiveFailures, 1);
      expect(
        timeout.nextDue.difference(timeout.checkedAt),
        const Duration(minutes: 30),
      );
      final t3 = t1.add(const Duration(minutes: 2));
      final partial = BookSiteCheck.after(
        _inspect(
          "<script src='/external.js'></script><script>eval(atob('YWxlcnQoMSk='));</script>",
        ),
        t3,
        source,
        timeout,
      );
      expect(
        partial.inspection.scriptReview.coverage,
        BookPageScriptCoverage.partial,
      );
      expect(_timestamps(partial.pendingScriptClues), {
        BookPageScriptClue.crossOriginRedirect: t1.millisecondsSinceEpoch,
        BookPageScriptClue.decodedDynamicEvaluation: t3.millisecondsSinceEpoch,
      });
      expect(_timestamps(partial.historicalScriptClues), {
        BookPageScriptClue.crossOriginRedirect: t1.millisecondsSinceEpoch,
      });
      final restored = BookSiteCheck.fromJson(
        jsonDecode(jsonEncode(partial.toJson())),
        source,
      )!;
      expect(
        _timestamps(restored.pendingScriptClues),
        _timestamps(partial.pendingScriptClues),
      );
      final redirect = BookSiteCheck.after(
        _inspect('<meta http-equiv="refresh" content="0;url=/other">'),
        t1.add(const Duration(minutes: 3)),
        source,
        restored,
      );
      expect(redirect.needsRetry, isTrue);
      expect(
        _timestamps(redirect.pendingScriptClues),
        _timestamps(partial.pendingScriptClues),
      );
      final onlyEval = BookSiteCheck.after(
        _inspect("<script>eval(atob('YWxlcnQoMSk='));</script>"),
        t1.add(const Duration(minutes: 4)),
        source,
        redirect,
      );
      expect(onlyEval.pendingScriptClues.keys, [
        BookPageScriptClue.decodedDynamicEvaluation,
      ]);
      final clear = BookSiteCheck.after(
        _inspect('<p>普通页面</p>'),
        t1.add(const Duration(minutes: 5)),
        source,
        onlyEval,
      );
      expect(clear.pendingScriptClues, isEmpty);
      expect(
        clear.nextDue.difference(clear.checkedAt),
        const Duration(days: 7),
      );
    },
  );

  test('legacy and damaged history restore only validated existing clues', () {
    final source = BookSource.fromJson({
      'name': '旧样本',
      'kind': 'text',
      'format': 'feed',
      'url': 'https://book.example/feed',
    });
    final now = DateTime.utc(2026, 11, 16);
    final first = BookSiteCheck.after(
      _inspect("<script>location.href='https://other.example/';</script>"),
      now,
      source,
      null,
    );
    final legacy = first.toJson()
      ..remove('scriptCluesLastObserved')
      ..remove('sourceHostSha256');
    final old = BookSiteCheck.fromJson(legacy, source)!;
    final missed = BookSiteCheck.after(
      const BookSiteInspection(BookSiteFinding.httpError),
      now.add(const Duration(hours: 1)),
      source,
      old,
    );
    expect(
      missed
          .historicalScriptClues[BookPageScriptClue.crossOriginRedirect]!
          .millisecondsSinceEpoch,
      now.millisecondsSinceEpoch,
    );
    final damaged = BookSiteCheck.fromJson({
      ...first.toJson(),
      'scriptCluesLastObserved': {
        'crossOriginRedirect': 'invalid',
        'decodedDynamicEvaluation': -1,
        'unknownClue': now.millisecondsSinceEpoch,
      },
    }, source)!;
    expect(_timestamps(damaged.pendingScriptClues), {
      BookPageScriptClue.crossOriginRedirect: now.millisecondsSinceEpoch,
    });
    expect(
      _timestamps(
        BookSiteCheck.fromJson({
          ...first.toJson(),
          'scriptCluesLastObserved': 'invalid',
        }, source)!.pendingScriptClues,
      ),
      {BookPageScriptClue.crossOriginRedirect: now.millisecondsSinceEpoch},
    );
  });

  test(
    'pre-revision sample with matching full fingerprint migrates as history',
    () {
      final source = BookSource.fromJson({
        'name': '旧版命中',
        'kind': 'text',
        'format': 'feed',
        'url': 'https://book.example/feed',
      });
      final now = DateTime.utc(2026, 11, 16);
      final original = BookSiteCheck.after(
        _inspect("<script>location.href='https://other.example/';</script>"),
        now,
        source,
        null,
      );
      final legacy = original.toJson()
        ..remove('sourceId')
        ..remove('sourceHostSha256')
        ..remove('siteRevision')
        ..remove('scriptCluesLastObserved');
      final migrated = BookSiteCheck.fromJson(
        legacy,
        source,
        currentRevision: 'a' * 32,
        requireRevision: true,
      )!;
      expect(migrated.inspection.finding, BookSiteFinding.sourceChanged);
      expect(migrated.inspection.label, contains('来源或检查记录需重新确认'));
      expect(migrated.inspection.scriptReview.hasClues, isFalse);
      expect(
        migrated
            .historicalScriptClues[BookPageScriptClue.crossOriginRedirect]!
            .millisecondsSinceEpoch,
        now.millisecondsSinceEpoch,
      );
      expect(migrated.isDue(now), isTrue);
      expect(
        BookSiteCheck.fromJson(
          {...legacy, 'sourceId': 'wrong'},
          source,
          currentRevision: 'a' * 32,
          requireRevision: true,
        ),
        isNull,
      );
      expect(
        BookSiteCheck.fromJson(
          {...legacy, 'sourceHostSha256': 'wrong'},
          source,
          currentRevision: 'a' * 32,
          requireRevision: true,
        ),
        isNull,
      );
      final changed = BookSource.fromJson({
        ...source.toJson(),
        'name': '改变的规则',
      });
      expect(
        BookSiteCheck.fromJson(
          legacy,
          changed,
          currentRevision: 'a' * 32,
          requireRevision: true,
        ),
        isNull,
      );
    },
  );

  test('rule updates preserve same-host clues as due history only', () {
    final source = BookSource.fromJson({
      'name': '旧版本',
      'kind': 'text',
      'format': 'feed',
      'url': 'https://book.example/feed',
      'sourceKey': 'fixture:stable-id',
    });
    final now = DateTime.utc(2026, 11, 16);
    final first = BookSiteCheck.after(
      _inspect("<script>location.href='https://other.example/';</script>"),
      now,
      source,
      null,
    );
    final updated = BookSource.fromJson({...source.toJson(), 'name': '新版本'});
    final stale = BookSiteCheck.fromJson(first.toJson(), updated)!;
    expect(stale.inspection.finding, BookSiteFinding.sourceChanged);
    expect(stale.inspection.scriptReview.hasClues, isFalse);
    expect(stale.inspection.gamblingRisk, isFalse);
    expect(
      stale
          .historicalScriptClues[BookPageScriptClue.crossOriginRedirect]!
          .millisecondsSinceEpoch,
      now.millisecondsSinceEpoch,
    );
    expect(stale.isDue(now), isTrue);
    expect(stale.consecutiveFailures, 0);
    expect(BookSiteCheck.fromJson(stale.toJson(), updated)!.isDue(now), isTrue);
    final failed = BookSiteCheck.after(
      const BookSiteInspection(BookSiteFinding.timeout),
      now,
      updated,
      stale,
    );
    expect(failed.consecutiveFailures, 1);
    expect(
      failed
          .historicalScriptClues[BookPageScriptClue.crossOriginRedirect]!
          .millisecondsSinceEpoch,
      now.millisecondsSinceEpoch,
    );
    final moved = BookSource.fromJson({
      ...source.toJson(),
      'url': 'https://different.example/feed',
    });
    expect(moved.id, source.id);
    expect(BookSiteCheck.fromJson(first.toJson(), moved), isNull);
    final otherId = BookSource.fromJson({
      ...source.toJson(),
      'sourceKey': 'fixture:other-id',
    });
    expect(otherId.id, isNot(source.id));
    expect(BookSiteCheck.fromJson(first.toJson(), otherId), isNull);
    final legacy = first.toJson()..remove('sourceHostSha256');
    expect(BookSiteCheck.fromJson(legacy, updated), isNull);
    final missingId = first.toJson()..remove('sourceId');
    expect(BookSiteCheck.fromJson(missingId, updated), isNull);
    final damagedHost = {...first.toJson(), 'sourceHostSha256': 'invalid'};
    expect(BookSiteCheck.fromJson(damagedHost, updated), isNull);
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
