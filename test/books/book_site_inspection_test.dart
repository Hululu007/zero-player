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
