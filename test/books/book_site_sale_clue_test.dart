import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/application/book_site_checks.dart';
import 'package:zero_player/features/books/data/book_site_inspection.dart';
import 'package:zero_player/features/books/data/book_site_sale_clues.dart';
import 'package:zero_player/features/books/domain/book.dart';

import '../../test_support/verified_temp_directory.dart';

const saleShape =
    '<h1>This domain is for sale</h1>'
    '<h1>This domain is for sale</h1>'
    '<h3>Contact the owner</h3><form><input></form>';
const sale = '<!doctype html><html><body>$saleShape</body></html>';
const normal = '<!doctype html><html><body><h1>普通书站</h1></body></html>';

BookSource _source({String host = 'sale.example', String name = '样本'}) =>
    BookSource.fromJson({
      'name': name,
      'kind': 'text',
      'format': 'feed',
      'url': 'https://$host/feed?secret=discarded',
      'sourceKey': 'stable-fixture',
    });

Uri _root(BookSource source) =>
    Uri(scheme: 'https', host: source.endpoint.host, path: '/');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _structureTests();
  _historyTests();
  _repositoryTest();
}

void _structureTests() {
  final target = _root(_source());
  test('sale landing-page structure is a weak clue, never a strong risk', () {
    final result = inspectBookSiteHtml(target, sale);
    expect(result.saleReview.suspected, isTrue);
    expect(result.saleReview.coverage, BookPageSaleCoverage.complete);
    expect(result.label, contains('疑似域名出售静态结构（可见性未确认）'));
    expect(result.gamblingRisk, isFalse);
    expect(result.adultRisk, isFalse);
    expect(result.finding, BookSiteFinding.sampled);
    final mixed = inspectBookSiteHtml(
      target,
      sale.replaceFirst('</body>', '<p>在线赌场 立即下注</p></body>'),
    );
    expect(mixed.saleReview.suspected, isTrue);
    expect(mixed.gamblingRisk, isTrue);
  });

  test('article mentions, incomplete shapes and hidden text do not match', () {
    for (final sample in [
      '<html><body><p>This domain is for sale</p></body></html>',
      '<html><body><h1>This domain is for sale</h1></body></html>',
      '<html><body><article>$saleShape</article></body></html>',
      '<html><body><div class="blog-post">$saleShape</div></body></html>',
      '<html><body><div hidden>$saleShape</div></body></html>',
      '<html><body><div aria-hidden="true">$saleShape</div></body></html>',
      '<html><body><div inert>$saleShape</div></body></html>',
      '<html><body><div style="display:none">$saleShape</div></body></html>',
      '<html><body><script>"$saleShape"</script></body></html>',
    ]) {
      expect(
        inspectBookSiteHtml(target, sample).saleReview.suspected,
        isFalse,
        reason: sample,
      );
    }
  });

  test(
    'CSS-hidden structure is an unrendered partial clue, not visible fact',
    () {
      for (final sample in [
        '<html><head><style>.hidden{display:none}</style></head><body>'
            '<div class="card hidden"><h1>This domain is for sale</h1></div>'
            '<div class="card hidden"><h1>This domain is for sale</h1></div>'
            '<h3>Contact the owner</h3><form></form></body></html>',
        '<html><head><link rel="stylesheet" href="/x.css"></head>'
            '<body>$saleShape</body></html>',
      ]) {
        final result = inspectBookSiteHtml(target, sample);
        expect(result.saleReview.suspected, isTrue);
        expect(result.saleReview.coverage, BookPageSaleCoverage.partial);
        expect(result.label, contains('可见性未确认'));
        expect(result.adultRisk || result.gamblingRisk, isFalse);
      }
    },
  );

  test(
    'deep, broad and oversized documents cannot exhaust scan or clear history',
    () {
      final hugeDepth =
          List.filled(100, '<div>').join() +
          saleShape +
          List.filled(100, '</div>').join();
      final hugeBreadth = List.filled(2100, '<i>x</i>').join();
      final hugeText = 'x' * 65537;
      final hugeAttribute = '<div class="${'x' * 1025}">$saleShape</div>';
      final hugeAria = '<div aria-hidden="${'x' * 1025}">$saleShape</div>';
      final hugeAriaAndChildren =
          '<div aria-hidden="${'x' * 120000}">'
          '${List.filled(1000, '<i></i>').join()}$saleShape</div>';
      final hugeRel = '<link rel="${'x' * 1025}">$saleShape';
      final hugeNestedAria =
          '<h1><span aria-hidden="${'x' * 1025}">'
          'This domain is for sale</span></h1>'
          '<h3>Contact the owner</h3><form></form>';
      final longAncestor = '<div aria-hidden="${'x' * 1000}">';
      final manyLongAncestors =
          '${List.filled(48, longAncestor).join()}$saleShape'
          '${List.filled(48, '</div>').join()}';
      final headingSharedBudget =
          '${List.filled(9, longAncestor).join()}'
          '<h1><span>This </span><span>domain </span>'
          '<span>is for sale</span></h1>'
          '<h3>Contact the owner</h3><form></form>'
          '${List.filled(9, '</div>').join()}';
      final source = _source();
      final first = BookSiteCheck.after(
        inspectBookSiteHtml(target, sale),
        DateTime(2026, 11, 16, 9),
        source,
        null,
      );
      for (final body in [
        hugeDepth,
        hugeBreadth,
        hugeText,
        hugeAttribute,
        hugeAria,
        hugeAriaAndChildren,
        hugeRel,
        hugeNestedAria,
        manyLongAncestors,
        headingSharedBudget,
      ]) {
        final result = inspectBookSiteHtml(
          target,
          '<html><body>$body</body></html>',
        );
        expect(result.saleReview.coverage, BookPageSaleCoverage.partial);
        expect(result.saleReview.suspected, isFalse);
        expect(result.label, contains('域名出售静态结构检查不完整'));
        expect(
          BookSiteCheck.after(
            result,
            first.checkedAt.add(const Duration(hours: 1)),
            source,
            first,
          ).historicalSaleClue,
          first.checkedAt,
        );
      }
    },
  );

  test('aria-hidden and link rel accept values at the attribute budget', () {
    final withinBudget = 'x' * 1024;
    final result = inspectBookSiteHtml(
      target,
      '<html><body><link rel="$withinBudget">'
      '<div aria-hidden="$withinBudget">$saleShape</div></body></html>',
    );
    expect(result.saleReview.coverage, BookPageSaleCoverage.complete);
    expect(result.saleReview.suspected, isTrue);
  });

  test('script, truncation, non-root and redirected coverage cannot clear', () {
    final scripted = inspectBookSiteHtml(
      target,
      sale.replaceFirst('</body>', '<script>void 0;</script></body>'),
    );
    expect(scripted.saleReview.suspected, isTrue);
    expect(scripted.saleReview.coverage, BookPageSaleCoverage.partial);
    expect(
      inspectBookSiteHtml(target, normal, truncated: true).saleReview.coverage,
      BookPageSaleCoverage.partial,
    );
    expect(
      inspectBookSiteHtml(target.resolve('/other'), sale).saleReview.suspected,
      isFalse,
    );
    expect(
      inspectBookSiteHtml(target, '<html><body><p>partial').saleReview.coverage,
      BookPageSaleCoverage.partial,
    );
  });
}

void _historyTests() {
  final source = _source();
  final root = _root(source);
  final firstTime = DateTime(2026, 11, 16, 9);
  final first = BookSiteCheck.after(
    inspectBookSiteHtml(root, sale),
    firstTime,
    source,
    null,
    siteRevision: 'one',
  );
  test(
    'persisted clues survive failure, partial samples and changed revisions',
    () {
      final raw = first.toJson();
      expect(jsonEncode(raw), isNot(contains('sale.example')));
      expect(jsonEncode(raw), isNot(contains('secret=discarded')));
      final restored = BookSiteCheck.fromJson(raw, source)!;
      expect(restored.pendingSaleClue, firstTime);
      for (final result in [
        const BookSiteInspection(BookSiteFinding.timeout),
        const BookSiteInspection(
          BookSiteFinding.externalRedirect,
          redirect: BookSiteRedirect.external,
        ),
        inspectBookSiteHtml(root, normal, truncated: true),
        inspectBookSiteHtml(
          root,
          normal.replaceFirst('</body>', '<script>void 0;</script></body>'),
        ),
        inspectBookSiteHtml(Uri.parse('https://other.example/'), normal),
      ]) {
        final after = BookSiteCheck.after(
          result,
          firstTime.add(const Duration(hours: 1)),
          source,
          restored,
        );
        expect(after.historicalSaleClue, firstTime);
        expect(
          BookSiteCheck.fromJson(after.toJson(), source)!.pendingSaleClue,
          firstTime,
        );
      }
      final revised = _source(name: '新版来源');
      expect(revised.id, source.id);
      final moved = BookSiteCheck.fromJson(raw, revised)!;
      expect(moved.inspection.finding, BookSiteFinding.sourceChanged);
      expect(moved.historicalSaleClue, firstTime);
      final newRevision = BookSiteCheck.fromJson(
        raw,
        source,
        requireRevision: true,
        currentRevision: 'two',
      )!;
      expect(newRevision.historicalSaleClue, firstTime);
      expect(newRevision.isDue(firstTime), isTrue);
      final newHost = _source(host: 'new.example');
      expect(newHost.id, source.id);
      expect(BookSiteCheck.fromJson(raw, newHost), isNull);
    },
  );

  test('only a full same-origin homepage clears the historical clue', () {
    final cleared = BookSiteCheck.after(
      inspectBookSiteHtml(root, normal),
      firstTime.add(const Duration(hours: 1)),
      source,
      first,
    );
    expect(cleared.pendingSaleClue, isNull);
    expect(
      BookSiteCheck.fromJson(cleared.toJson(), source)!.pendingSaleClue,
      isNull,
    );
    final legacy = first.toJson()..remove('saleReview');
    final old = BookSiteCheck.fromJson(legacy, source)!;
    expect(old.pendingSaleClue, firstTime);
    expect(old.isDue(firstTime), isTrue);
  });

  test('a partial manual result retains newer supervised history', () {
    final later = BookSiteCheck.after(
      inspectBookSiteHtml(root, sale),
      firstTime.add(const Duration(minutes: 5)),
      source,
      first,
    );
    final partial = BookSiteCheck.after(
      const BookSiteInspection(BookSiteFinding.timeout),
      firstTime.add(const Duration(minutes: 6)),
      source,
      first,
      scriptHistoryPrevious: later,
    );
    expect(partial.historicalSaleClue, later.checkedAt);
  });

  test(
    'a manual full clear is not resurrected by older supervised history',
    () {
      final cleared = BookSiteCheck.after(
        inspectBookSiteHtml(root, normal),
        firstTime.add(const Duration(minutes: 5)),
        source,
        first,
      );
      final partial = BookSiteCheck.after(
        const BookSiteInspection(BookSiteFinding.timeout),
        firstTime.add(const Duration(minutes: 6)),
        source,
        first,
        scriptHistoryPrevious: cleared,
      );
      expect(partial.pendingSaleClue, isNull);
    },
  );
}

void _repositoryTest() {
  test(
    'checking and restoring an advisory does not alter source risk or settings',
    () async {
      final temp = await VerifiedTempDirectory.create('book-sale-advisory-');
      final services = AppServices.scoped(temp.directory, AppDatabase.memory());
      addTearDown(() async {
        await services.close();
        await temp.delete();
      });
      await services.supervision.load();
      await services.settings.load();
      final source = _source();
      await services.books.importSources([source]);
      await services.books.saveSource(source, {
        'enabled': false,
        'favorite': true,
      });
      var entry = (await services.books.sources(
        BookKind.text,
      )).singleWhere((entry) => entry.source.id == source.id);
      final checks = BookSiteChecks(
        services.books,
        inspect: (_, _) async => inspectBookSiteHtml(_root(source), sale),
      );
      final summary = await checks.run([entry], CancellationToken());
      expect(summary.checked, 1);
      expect(summary.quarantined, 0);
      expect(summary.adult, 0);
      expect(await services.books.riskStore.get(source.id), isNull);
      entry = (await services.books.sources(
        BookKind.text,
      )).singleWhere((entry) => entry.source.id == source.id);
      expect(entry.enabled, isFalse);
      expect(entry.favorite, isTrue);
      expect(
        (await checks.load([entry]))[source.id]!.pendingSaleClue,
        isNotNull,
      );
      final timeout = BookSiteChecks(
        services.books,
        inspect: (_, _) async =>
            const BookSiteInspection(BookSiteFinding.timeout),
      );
      await timeout.run([entry], CancellationToken());
      expect(
        (await timeout.load([entry]))[source.id]!.historicalSaleClue,
        isNotNull,
      );
      expect(await services.books.riskStore.get(source.id), isNull);
    },
  );
}
