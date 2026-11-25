import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/platform/protected_book_export.dart';
import 'package:zero_player/features/books/data/book_offline_export.dart';
import 'package:zero_player/core/persistence/installation_metadata.dart';
import 'package:zero_player/features/books/data/books_repository.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/data/book_policy_evidence.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/legado_source.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

import '../../test_support/verified_temp_directory.dart';
import '../../test_support/comic_source_authorization.dart';

part 'book_discovery_category_reading_cases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _mixedBookAccessTests();
  _staticBookAccessTests();
  _detailsTargetTests();
  _pendingDetailEvidenceTests();
  _directoryTargetTests();
  _textAndStoredTargetTests();
  _inFlightPolicyTests();
  _nonLegadoTargetTests();
  _comicTargetTests();
  _comicIntegrityTests();
  _comicBudgetTests();
  _audioTargetTests();
  _mediaProbeTargetTests();
  _restrictedDiscoveryTests();
  _discoveryPaginationTests();
  _discoveryChangeTests();
  _discoveryAliasTests();
  _bundledAndAdapterTests();
  _directAddressTests();
}

void _mixedBookAccessTests() {
  test(
    'mixed sources filter categories and books without labeling the source',
    () async {
      await _withFixture((f) async {
        final source = _mixed();
        await f.install(source);
        final categories = await f.repo.categories(
          BookKind.text,
          source.id,
          CancellationToken(),
        );
        expect(categories.map((item) => item.title), ['仙侠', 'BL']);
        expect(f.repo.sourceAllowed(source), isTrue);
        expect(await f.repo.riskStore.get(source.id), isNull);

        Book book(String category) => Book(
          source.id,
          BookKind.text,
          '普通作品',
          '作者',
          source.endpoint.resolve('/book/1'),
          category: category,
        );
        for (final label in ['成人', '肉文', '肉漫']) {
          expect(f.repo.bookAllowed(book(label)), isFalse, reason: label);
        }
        for (final label in ['玄幻', 'BL', '耽美']) {
          expect(f.repo.bookAllowed(book(label)), isTrue, reason: label);
        }

        final page = await f.repo.discover(
          BookKind.text,
          source.id,
          CancellationToken(),
        );
        expect(page.books.map((book) => book.title), ['星际普通']);
        expect(f.requests.map((request) => request.$2.path), ['/normal']);
        expect(f.requests.single.$2.queryParameters['page'], '1');

        f.requests.clear();
        final aggregate = await f.repo.find(
          BookKind.text,
          '',
          CancellationToken(),
          sourceIds: {source.id},
        );
        expect(aggregate.books.map((book) => book.title), ['星际普通']);
        expect(f.requests.map((request) => request.$2.path), ['/normal']);

        // With no search rule, a nonempty search also falls back to discovery.
        f.requests.clear();
        final fallback = await f.repo.find(
          BookKind.text,
          '星际',
          CancellationToken(),
          sourceIds: {source.id},
        );
        expect(fallback.books.map((book) => book.title), ['星际普通']);
        expect(f.requests.map((request) => request.$2.path), ['/normal']);
      });
    },
  );

  test('books at a known restricted category address are hidden', () async {
    await _withFixture((f) async {
      final source = _source('book-address.example', [
        {'title': '肉文', 'url': '/list,{"method":"POST","body":"kind=adult"}'},
        {'title': '普通', 'url': '/list?kind=normal'},
        {'title': '成人', 'url': "@js:java.ajax('/unknown')"},
      ]);
      await f.install(source);
      Book book(String url, {String request = ''}) => Book(
        source.id,
        BookKind.text,
        '普通标题',
        '作者',
        source.endpoint.resolve(url),
        request: request,
      );
      expect(f.repo.bookAllowed(book('/list?kind=adult')), isFalse);
      expect(f.repo.bookAllowed(book('/list?kind=normal')), isTrue);
      expect(
        f.repo.bookAllowed(
          book(
            '/list',
            request:
                'https://book-address.example/list,{"method":"POST","body":"kind=adult"}',
          ),
        ),
        isFalse,
      );
      expect(
        f.repo.bookAllowed(
          book(
            '/list',
            request:
                'https://book-address.example/list,{"method":"POST","body":"kind=normal"}',
          ),
        ),
        isTrue,
      );
      expect(f.repo.bookAllowed(book('/unrelated/1')), isTrue);
      await expectLater(
        f.repo.details(book('/list?kind=adult'), CancellationToken()),
        throwsA(anything),
      );
      await expectLater(
        f.repo.chapters(book('/list?kind=adult'), CancellationToken()),
        throwsA(anything),
      );
      expect(f.requests, isEmpty);
    });
  });
}

void _staticBookAccessTests() {
  test(
    'static non-Legado categories only block the matching book path',
    () async {
      await _withFixture((f) async {
        final source = BookSource.fromJson({
          'name': '普通静态源',
          'kind': 'text',
          'format': 'html',
          'url': 'https://static-books.example/',
          'search': '/search/{key}',
          'discoveryCategories': [
            {'title': '肉文', 'url': '/book/1'},
            {'title': '成人', 'url': '/page/{{page}}'},
          ],
          'rules': {
            'list': '.book',
            'title': 'a@text',
            'book': 'a@href',
            'chapters': '.chapter',
            'chapterTitle': '@text',
            'chapterUrl': '@href',
            'content': 'p@text',
          },
        });
        await f.install(source);
        Book book(String path) => Book(
          source.id,
          BookKind.text,
          '普通作品',
          '作者',
          source.endpoint.resolve(path),
        );
        expect(f.repo.bookAllowed(book('/book/1')), isFalse);
        expect(f.repo.bookAllowed(book('/book/2')), isTrue);
        expect(f.repo.bookAllowed(book('/page/2')), isFalse);
      });
    },
  );

  test(
    'ordinary search filters a result whose address is a restricted category',
    () async {
      await _withFixture((f) async {
        final base = _source('search-address.example', [
          {'title': '肉文', 'url': '/book/1'},
          {'title': '普通', 'url': '/normal'},
        ]);
        final spec = base.legado!.toJson();
        final source = BookSource.fromJson({
          ...base.toJson(),
          'legado': {
            ...spec,
            'search': '/search?key={{key}}',
            'rules': {
              ...(spec['rules'] as Map),
              'searchList': '.bookbox',
              'searchTitle': '.bookname a@text',
              'searchLink': '.bookname a@href',
            },
          },
        });
        await f.install(source);
        final result = await f.repo.find(
          BookKind.text,
          '星际',
          CancellationToken(),
          sourceIds: {source.id},
        );
        expect(result.books, isEmpty);
        expect(f.requests.map((request) => request.$2.path), ['/search']);
      });
    },
  );
}

void _restrictedDiscoveryTests() {
  test(
    'all restricted categories and their scripts are not requested',
    () async {
      await _withFixture((f) async {
        final source = _source('restricted.example', [
          {'title': '肉文', 'url': "@js:java.ajax('/danger')"},
          {'title': '普通', 'group': '成人专区', 'url': '/adult'},
        ]);
        await f.install(source);
        expect(
          await f.repo.categories(
            BookKind.text,
            source.id,
            CancellationToken(),
          ),
          isEmpty,
        );
        expect(
          (await f.repo.discover(
            BookKind.text,
            source.id,
            CancellationToken(),
          )).books,
          isEmpty,
        );
        expect(
          (await f.repo.find(
            BookKind.text,
            '',
            CancellationToken(),
            sourceIds: {source.id},
          )).books,
          isEmpty,
        );
        expect(
          (await f.repo.find(
            BookKind.text,
            '星际',
            CancellationToken(),
            sourceIds: {source.id},
          )).books,
          isEmpty,
        );
        expect(f.requests, isEmpty);

        final noCategories = _featured();
        await f.install(noCategories);
        final normal = await f.repo.find(
          BookKind.text,
          '',
          CancellationToken(),
          sourceIds: {noCategories.id},
        );
        expect(normal.books.map((book) => book.title), ['普通精选']);
        expect(f.requests, isEmpty);

        final aliases = _source('aliases.example', [
          {'title': '成人', 'url': '/same'},
          {'title': '普通', 'url': '/same'},
          {'title': '玄幻', 'url': '/normal?page={{page}}'},
        ]);
        await f.install(aliases);
        final remaining = await f.repo.categories(
          BookKind.text,
          aliases.id,
          CancellationToken(),
        );
        expect(remaining.map((item) => item.title), ['玄幻']);
        await f.repo.discover(BookKind.text, aliases.id, CancellationToken());
        expect(f.requests.single.$2.path, '/normal');
      });
    },
  );
}

void _discoveryPaginationTests() {
  test(
    'category identity and pagination stay bound across retry and changes',
    () async {
      await _withFixture((f) async {
        final source = _mixed();
        await f.install(source);
        final otherSource = _source('other.example', [
          {'title': '仙侠', 'group': '小说', 'url': '/normal?page={{page}}'},
        ]);
        await f.install(otherSource);
        final available = await f.repo.categories(
          BookKind.text,
          source.id,
          CancellationToken(),
        );
        final allowed = available.first;
        final first = await f.repo.discover(
          BookKind.text,
          source.id,
          CancellationToken(),
          category: allowed,
        );
        final cursor = first.next;
        expect(cursor, isNotNull);
        f.requests.clear();
        for (var i = 0; i < 2; i++) {
          final next = await f.repo.discover(
            BookKind.text,
            source.id,
            CancellationToken(),
            category: allowed,
            page: 2,
            cursor: cursor,
          );
          expect(next.books, isNotEmpty);
        }
        expect(
          f.requests.map((request) => request.$2.queryParameters['page']),
          ['2', '2'],
        );
        f.requests.clear();
        await expectLater(
          f.repo.discover(
            BookKind.text,
            source.id,
            CancellationToken(),
            category: allowed,
            page: 2,
            cursor: 'forged',
          ),
          throwsFormatException,
        );
        await expectLater(
          f.repo.discover(
            BookKind.text,
            source.id,
            CancellationToken(),
            category: available.last,
            page: 2,
            cursor: cursor,
          ),
          throwsFormatException,
        );
        await expectLater(
          f.repo.discover(
            BookKind.text,
            otherSource.id,
            CancellationToken(),
            category: allowed,
            page: 2,
            cursor: cursor,
          ),
          throwsFormatException,
        );
        await expectLater(
          f.repo.discover(
            BookKind.text,
            source.id,
            CancellationToken(),
            category: const LegadoCategory('仙侠', '/adult', group: '小说'),
          ),
          throwsFormatException,
        );
        expect(f.requests, isEmpty);

        await f.repo.saveSource(source, {'enabled': false});
        await f.repo.saveSource(source, {'enabled': true});
        await expectLater(
          f.repo.discover(
            BookKind.text,
            source.id,
            CancellationToken(),
            category: allowed,
            page: 2,
            cursor: cursor,
          ),
          throwsFormatException,
        );
        expect(f.requests, isEmpty);

        final fresh = await f.repo.discover(
          BookKind.text,
          source.id,
          CancellationToken(),
          category: allowed,
        );
        await f.services.settings.update({'filterAdult': false});
        f.requests.clear();
        await expectLater(
          f.repo.discover(
            BookKind.text,
            source.id,
            CancellationToken(),
            category: allowed,
            page: 2,
            cursor: fresh.next,
          ),
          throwsFormatException,
        );
        expect(f.requests, isEmpty);
        expect(
          (await f.repo.categories(
            BookKind.text,
            source.id,
            CancellationToken(),
          )).first.title,
          '成人',
        );
        await f.repo.discover(BookKind.text, source.id, CancellationToken());
        expect(f.requests.single.$2.path, '/adult');
        await f.services.settings.update({'filterAdult': true});
        f.requests.clear();
        await f.repo.discover(BookKind.text, source.id, CancellationToken());
        expect(f.requests.single.$2.path, '/normal');
      });
    },
  );
}

void _discoveryChangeTests() {
  test('policy or source changes cancel in-flight discovery', () async {
    await _withFixture((f) async {
      final source = _mixed();
      await f.install(source);
      await f.services.settings.update({'filterAdult': false});
      final firstGate = f.hold('/adult');
      final first = expectLater(
        f.repo.discover(BookKind.text, source.id, CancellationToken()),
        throwsA(anything),
      );
      await firstGate.started.future.timeout(const Duration(seconds: 5));
      await f.services.settings.update({'filterAdult': true});
      firstGate.release();
      await first.timeout(const Duration(seconds: 5));

      final secondGate = f.hold('/normal');
      final second = expectLater(
        f.repo.discover(BookKind.text, source.id, CancellationToken()),
        throwsA(anything),
      );
      await secondGate.started.future.timeout(const Duration(seconds: 5));
      await f.repo.saveSource(source, {'enabled': false});
      await f.repo.saveSource(source, {'enabled': true});
      secondGate.release();
      await second.timeout(const Duration(seconds: 5));

      final thirdGate = f.hold('/normal');
      final cancellation = CancellationToken();
      final third = expectLater(
        f.repo.discover(BookKind.text, source.id, cancellation),
        throwsA(anything),
      );
      await thirdGate.started.future.timeout(const Duration(seconds: 5));
      cancellation.cancel();
      thirdGate.release();
      await third.timeout(const Duration(seconds: 5));
    });
  });

  test('page links cannot cross into known restricted categories', () async {
    await _withFixture((f) async {
      final source = _mixed();
      await f.install(source);
      f.nextLinks['/normal'] = '/adult?page=2';
      final first = await f.repo.discover(
        BookKind.text,
        source.id,
        CancellationToken(),
      );
      expect(first.books, isNotEmpty);
      expect(first.next, isNull);
      expect(f.requests.map((request) => request.$2.path), ['/normal']);

      f.requests.clear();
      f.nextLinks['/normal'] = '/normal?page=2';
      final safe = await f.repo.discover(
        BookKind.text,
        source.id,
        CancellationToken(),
      );
      expect(safe.next, isNotNull);
      await f.repo.discover(
        BookKind.text,
        source.id,
        CancellationToken(),
        page: 2,
        cursor: safe.next,
      );
      expect(f.requests.map((request) => request.$2.path), [
        '/normal',
        '/normal',
      ]);

      final alias = _source('alias-pages.example', [
        {'title': '肉文', 'url': '/adult'},
        {'title': '普通', 'url': '/adult?page=1'},
      ]);
      await f.install(alias);
      f.requests.clear();
      expect(
        await f.repo.categories(BookKind.text, alias.id, CancellationToken()),
        isEmpty,
      );
      expect(
        (await f.repo.discover(
          BookKind.text,
          alias.id,
          CancellationToken(),
        )).books,
        isEmpty,
      );
      expect(f.requests, isEmpty);
    });
  });
}

void _discoveryAliasTests() {
  test('unknown restricted scripts block ordinary category aliases', () async {
    await _withFixture((f) async {
      final source = _source('unknown-adult.example', [
        {'title': '肉文', 'url': "@js:'/adult'"},
        {'title': '普通', 'url': '/adult'},
      ]);
      await f.install(source);
      expect(
        await f.repo.categories(BookKind.text, source.id, CancellationToken()),
        isEmpty,
      );
      expect(
        (await f.repo.discover(
          BookKind.text,
          source.id,
          CancellationToken(),
        )).books,
        isEmpty,
      );
      expect(f.requests, isEmpty);
      final normal = _source('only-normal.example', [
        {'title': '普通', 'url': '/normal'},
      ]);
      await f.install(normal);
      expect(
        (await f.repo.categories(
          BookKind.text,
          normal.id,
          CancellationToken(),
        )).map((v) => v.title),
        ['普通'],
      );
      expect(
        (await f.repo.discover(
          BookKind.text,
          normal.id,
          CancellationToken(),
        )).books,
        isNotEmpty,
      );
      expect(f.requests.map((request) => request.$2.path), ['/normal']);
    });
  });

  test(
    'global discovery is hidden only when a category is restricted',
    () async {
      await _withFixture((f) async {
        final mixed = _source('global-mixed.example', [
          {'title': '全部', 'url': '/all'},
          {'title': '肉文', 'url': '/adult'},
          {'title': '普通', 'url': '/normal'},
        ]);
        await f.install(mixed);
        expect(
          (await f.repo.categories(
            BookKind.text,
            mixed.id,
            CancellationToken(),
          )).map((v) => v.title),
          ['普通'],
        );
        await f.repo.discover(BookKind.text, mixed.id, CancellationToken());
        expect(f.requests.map((request) => request.$2.path), ['/normal']);
        f.requests.clear();
        final normal = _source('global-safe.example', [
          {'title': '全部', 'url': '/all'},
          {'title': '普通', 'url': '/normal'},
        ]);
        await f.install(normal);
        expect(
          (await f.repo.categories(
            BookKind.text,
            normal.id,
            CancellationToken(),
          )).map((v) => v.title),
          ['全部', '普通'],
        );
        await f.repo.discover(BookKind.text, normal.id, CancellationToken());
        expect(f.requests.map((request) => request.$2.path), ['/all']);
      });
    },
  );
}

void _bundledAndAdapterTests() {
  test('bundled mixed catalog record hides its global category', () async {
    final compressed = await File(
      'assets/catalogs/books/legado/catalog.json.bz2',
    ).readAsBytes();
    final catalog =
        jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(compressed))) as Map;
    final source = parseBookSourceRecord(
      (catalog['records'] as List)[4560] as Map,
    );
    expect(
      source.id,
      '546ed179fed46c6cc05454b5fd6d827f12badb8bdce82eadc0b233f1bcbed62b',
    );
    await _withFixture((f) async {
      await f.install(source);
      final categories = await f.repo.categories(
        BookKind.text,
        source.id,
        CancellationToken(),
      );
      expect(categories.map((item) => item.title), isNot(contains('全部')));
      expect(categories.map((item) => item.title), isNot(contains('百合肉文')));
      expect(categories.map((item) => item.title), contains('言情小说'));
      expect(f.requests, isEmpty);
    });
  });

  test(
    'ShuYin defaults to an allowed category when navigation is mixed',
    () async {
      await _withFixture((f) async {
        final source = (await f.repo.sources(BookKind.audio))
            .singleWhere((entry) => entry.source.format == BookFormat.shuyin)
            .source;
        await f.repo.saveSource(source, {'enabled': true});
        f.shuyinNavigation.addAll([
          {'classid': '9', 'classname': '肉文'},
          {'classid': '12', 'classname': '普通'},
        ]);
        expect(
          (await f.repo.categories(
            BookKind.audio,
            source.id,
            CancellationToken(),
          )).map((v) => v.title),
          ['普通'],
        );
        f.formRequests.clear();
        final result = await f.repo.discover(
          BookKind.audio,
          source.id,
          CancellationToken(),
        );
        expect(result.books, isNotEmpty);
        final lists = f.formRequests
            .where((body) => body['act'] == 'list')
            .toList();
        expect(lists.map((body) => body['classid']), ['12']);
        f.shuyinNavigation.removeWhere((row) => row['classid'] == '9');
        f.formRequests.clear();
        expect(
          (await f.repo.categories(
            BookKind.audio,
            source.id,
            CancellationToken(),
          )).map((v) => v.title),
          ['全部', '普通'],
        );
        await f.repo.discover(BookKind.audio, source.id, CancellationToken());
        expect(
          f.formRequests
              .where((body) => body['act'] == 'list')
              .map((body) => body['classid']),
          ['0'],
        );
      });
    },
  );
}

void _directAddressTests() {
  test('filtered discovery never follows a same-host redirect', () async {
    await _withFixture((f) async {
      final source = _source('redirect.example', [
        {'title': '肉文', 'url': '/adult'},
        {'title': '普通', 'url': '/normal'},
      ]);
      await f.install(source);
      f.redirects['/normal'] = '/adult';
      await expectLater(
        f.repo.discover(BookKind.text, source.id, CancellationToken()),
        throwsA(anything),
      );
      expect(f.requests.map((request) => request.$2.path), ['/normal']);
      f.requests.clear();
      await f.services.settings.update({'filterAdult': false});
      await f.repo.discover(
        BookKind.text,
        source.id,
        CancellationToken(),
        category: const LegadoCategory('普通', '/normal'),
      );
      expect(f.requests.map((request) => request.$2.path), [
        '/normal',
        '/adult',
      ]);
    });
  });

  test(
    'direct book addresses reject restricted aliases and redirects',
    () async {
      await _withFixture((f) async {
        final base = _source('direct.example', [
          {'title': '肉文', 'url': '/series/1'},
          {'title': '普通', 'url': '/normal'},
        ]);
        final spec = base.legado!.toJson();
        final source = BookSource.fromJson({
          ...base.toJson(),
          'legado': {
            ...spec,
            'bookUrlPattern': r'https://direct\.example/.*',
            'rules': {
              ...(spec['rules'] as Map),
              'infoTitle': '.bookname a@text',
            },
          },
        });
        await f.install(source);
        final blocked = await f.repo.find(
          BookKind.text,
          'https://direct.example/series/2',
          CancellationToken(),
          sourceIds: {source.id},
        );
        expect(blocked.books, isEmpty);
        expect(f.requests, isEmpty);
        final normal = await f.repo.find(
          BookKind.text,
          'https://direct.example/book/1',
          CancellationToken(),
          sourceIds: {source.id},
        );
        expect(normal.books.map((book) => book.title), ['星际普通']);
        expect(f.requests.map((request) => request.$2.path), ['/book/1']);
        f.requests.clear();
        f.redirects['/book/1'] = '/series/1';
        final redirected = await f.repo.find(
          BookKind.text,
          'https://direct.example/book/1',
          CancellationToken(),
          sourceIds: {source.id},
        );
        expect(redirected.books, isEmpty);
        expect(f.requests.map((request) => request.$2.path), ['/book/1']);

        final uncertainBase = _source('unknown-direct.example', [
          {'title': '肉文', 'url': "@js:'/adult'"},
          {'title': '普通', 'url': '/normal'},
        ]);
        final uncertainSpec = uncertainBase.legado!.toJson();
        final uncertain = BookSource.fromJson({
          ...uncertainBase.toJson(),
          'legado': {
            ...uncertainSpec,
            'bookUrlPattern': r'https://unknown-direct\.example/.*',
            'rules': {
              ...(uncertainSpec['rules'] as Map),
              'infoTitle': '.bookname a@text',
            },
          },
        });
        await f.install(uncertain);
        f.requests.clear();
        final unknown = await f.repo.find(
          BookKind.text,
          'https://unknown-direct.example/book/1',
          CancellationToken(),
          sourceIds: {uncertain.id},
        );
        expect(unknown.books, isEmpty);
        expect(f.requests, isEmpty);
      });
    },
  );
}

BookSource _mixed() => _source('mixed.example', [
  {'title': '成人', 'url': '/adult'},
  {'title': '肉文', 'url': '/adult-novels'},
  {'title': '都市', 'group': '成人专区', 'url': '/adult-group'},
  {'title': '仙侠', 'group': '小说', 'url': '/normal?page={{page}}'},
  {'title': 'BL', 'url': '/bl'},
]);

BookSource _readingSource(String host) => BookSource.fromJson({
  'name': '普通阅读源',
  'url': 'https://$host/',
  'kind': 'text',
  'format': 'html',
  'legado': {
    'explore': [
      {'title': '肉文', 'url': '/adult'},
      {'title': '成人', 'url': '/list,{"method":"POST","body":"kind=adult"}'},
      {'title': '普通', 'url': '/normal'},
    ],
    'rules': {
      'infoTitle': '.bookname a@text',
      'toc': '.toc@href',
      'chapters': '.chapter',
      'chapterTitle': '@text',
      'chapterUrl': '@href',
      'nextToc': '.nexttoc@href',
      'content': '.body@text',
      'nextContent': '.next@href',
    },
  },
});

Book _readingBook(BookSource source) => Book(
  source.id,
  BookKind.text,
  '普通作品',
  '作者',
  source.endpoint.resolve('/book/1'),
);

BookSource _mediaSource(String host, BookKind kind) => BookSource.fromJson({
  'name': '普通媒体源',
  'url': 'https://$host/',
  'kind': kind.name,
  'format': 'html',
  'legado': {
    'explore': [
      {'title': '肉文', 'url': '/adult'},
      {'title': '普通', 'url': '/normal'},
    ],
    'rules': {'content': kind == BookKind.comic ? 'img@src' : 'audio@src'},
  },
});

Book _mediaBook(BookSource source) => Book(
  source.id,
  source.kind,
  '普通作品',
  '作者',
  source.endpoint.resolve('/book/1'),
);

BookSource _source(String host, List<Map<String, String>> categories) =>
    BookSource.fromJson({
      'name': '普通混合书源',
      'url': 'https://$host/',
      'kind': 'text',
      'format': 'html',
      'legado': {
        'explore': categories,
        'rules': {
          'exploreList': '.bookbox',
          'exploreTitle': '.bookname a@text',
          'exploreLink': '.bookname a@href',
          'exploreCategory': '.kind@text',
          'nextExplore': '.pages a.next@href',
          'content': '#content@text',
        },
      },
    });

BookSource _featured() => BookSource.fromJson({
  'name': '普通精选',
  'url': 'https://featured.example/',
  'kind': 'text',
  'format': 'featured',
  'featured': [
    {'title': '普通精选', 'url': '/book'},
  ],
  'rules': {
    'chapters': 'a',
    'chapterTitle': '@text',
    'chapterUrl': '@href',
    'content': 'p@text',
  },
});

Future<void> _withFixture(Future<void> Function(_Fixture) body) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final temporary = await VerifiedTempDirectory.create('category-policy-');
  final root = temporary.directory;
  final requests = <(String, Uri)>[];
  final gates = <String, _Gate>{};
  final nextLinks = <String, String>{};
  final redirects = <String, String>{};
  final pages = <String, String>{};
  final referers = <String, String?>{};
  final media = <String, (ContentType, List<int>)>{};
  final shuyinNavigation = <Map<String, String>>[];
  final formRequests = <Map<String, String>>[];
  server.listen((request) async {
    try {
      if (request.method == 'POST' &&
          request.uri.path == '/ecmsapi/index.php') {
        final form = Uri.splitQueryString(
          await utf8.decoder.bind(request).join(),
        );
        formRequests.add(form);
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(
            form['act'] == 'navigation'
                ? {'code': 1, 'list': shuyinNavigation}
                : {
                    'code': 1,
                    'data': {
                      'list': [
                        {'id': '1', 'title': '星际普通'},
                      ],
                      'totalpage': 1,
                    },
                  },
          ),
        );
        await request.response.close();
        return;
      }
      referers[request.uri.path] = request.headers.value(
        HttpHeaders.refererHeader,
      );
      final redirect = redirects[request.uri.path];
      if (redirect != null) {
        request.response.statusCode = 302;
        request.response.headers.set(HttpHeaders.locationHeader, redirect);
        await request.response.close();
        return;
      }
      final gate = gates[request.uri.path];
      if (gate != null) {
        if (!gate.started.isCompleted) gate.started.complete();
        await gate.released.future;
      }
      if (request.method == 'POST') await request.drain<void>();
      final payload = media[request.uri.path];
      if (payload != null) {
        request.response.headers.contentType = payload.$1;
        request.response.add(payload.$2);
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        pages[request.uri.path] ??
            '''
        <div class="bookbox"><div class="bookname">
          <a href="/book/1">星际普通</a></div><span class="kind">玄幻</span></div>
        ${request.uri.queryParameters['page'] == '2' ? '' : '<div class="pages"><a class="next" href="${nextLinks[request.uri.path] ?? '/normal?page=2'}">下一页</a></div>'}
      ''',
      );
      await request.response.close();
    } on Object {
      // A cancelled request may close the loopback socket before the reply.
    }
  });
  try {
    await HttpOverrides.runZoned(
      () async {
        final services = AppServices.scoped(root, AppDatabase.memory());
        try {
          await services.db.write(
            'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
            [installationAccessKey, upgradedInstallationAccess],
          );
          await services.settings.load();
          await services.supervision.load();
          for (final entry in await services.books.sources(
            BookKind.text,
            enabledOnly: true,
          )) {
            await services.books.saveSource(entry.source, {'enabled': false});
          }
          await body(
            _Fixture(
              services,
              requests,
              gates,
              nextLinks,
              redirects,
              pages,
              referers,
              media,
              shuyinNavigation,
              formRequests,
            ),
          );
        } finally {
          for (final gate in gates.values) {
            gate.release();
          }
          await services.close();
        }
      },
      createHttpClient: (context) {
        final client = _RealHttpOverrides().createHttpClient(context)
          ..findProxy = (_) => 'DIRECT';
        return _LoopbackClient(
          client,
          Uri.parse('http://127.0.0.1:${server.port}'),
          requests,
        );
      },
    );
  } finally {
    await server.close(force: true);
    await temporary.delete();
  }
}

final class _Fixture {
  _Fixture(
    this.services,
    this.requests,
    this.gates,
    this.nextLinks,
    this.redirects,
    this.pages,
    this.referers,
    this.media,
    this.shuyinNavigation,
    this.formRequests,
  );
  final AppServices services;
  final List<(String, Uri)> requests;
  final Map<String, _Gate> gates;
  final Map<String, String> nextLinks;
  final Map<String, String> redirects;
  final Map<String, String> pages;
  final Map<String, String?> referers;
  final Map<String, (ContentType, List<int>)> media;
  final List<Map<String, String>> shuyinNavigation, formRequests;
  BooksRepository get repo => services.books;

  Future<void> install(BookSource source) async {
    await authorizeComicFixture(services, source);
    await repo.importSources([source]);
    await repo.saveSource(source, {'enabled': true});
  }

  _Gate hold(String path) => gates[path] = _Gate();
}

final class _Gate {
  final started = Completer<void>();
  final released = Completer<void>();
  void release() {
    if (!released.isCompleted) released.complete();
  }
}

final class _RealHttpOverrides extends HttpOverrides {}

/// Redirect all fixture hosts to loopback before any network connection exists.
final class _LoopbackClient implements HttpClient {
  _LoopbackClient(this.client, this.base, this.requests);
  final HttpClient client;
  final Uri base;
  final List<(String, Uri)> requests;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) {
    requests.add((method, uri));
    final local = base.replace(
      path: uri.path,
      query: uri.hasQuery ? uri.query : null,
    );
    return client.openUrl(method, local);
  }

  @override
  void close({bool force = false}) => client.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isSetter) return null;
    return super.noSuchMethod(invocation);
  }
}
