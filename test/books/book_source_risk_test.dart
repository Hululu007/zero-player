import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/persistence/installation_metadata.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_source_risk.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

BookSource _source(
  String host,
  String name, {
  String group = '漫画',
  String kind = 'comic',
}) => BookSource.fromJson({
  'name': name,
  'group': group,
  'kind': kind,
  'format': 'html',
  'url': 'https://$host/',
  'search': '/search/{key}',
  'rules': {
    'list': '.book',
    'title': '.title@text',
    'book': 'a@href',
    'chapters': '.chapter',
    'chapterTitle': '@text',
    'chapterUrl': '@href',
    'content': '.content',
  },
});

Future<void> _allowAdultFixture(AppServices services) => services.db.write(
  'INSERT OR REPLACE INTO app_meta VALUES(?,?)',
  [installationAccessKey, upgradedInstallationAccess],
);

BookSource _wesrcVariant(String host, {required bool unsafe}) {
  final source = _source(host, '测试版本', kind: 'text');
  return BookSource.fromJson({
    ...source.toJson(),
    'legado': {
      'search': '/search/{{key}}',
      'rules': {
        'searchList': unsafe
            ? 'Packages.okhttp3; global.wesrc; http://yck.hr7t4h.cn/yck/funcs; '
                  'eval(Base64.decode(global.wesrc, 0));'
            : 'JSON.parse(result)',
        'content': r'$.data.content',
      },
    },
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _sourceClassificationTests();
  _adultEvidenceTests();
  _defaultAdultVisibilityTests();
  _adultEvidencePersistenceTests();
  _riskReviewTests();
  _historicalSourceTests();
  _localReadingPolicyTests();
  _subscriptionUpdatePolicyTests();
}

void _sourceClassificationTests() {
  test('off-site redirect hosts stay quarantined', () {
    for (final host in [
      'www.jpxgyw.cc',
      'www.yeseimg.com',
      'www.kukk.net',
      'www.bdido.com',
    ]) {
      expect(quarantinedComicSource(_source(host, '漫画')), isTrue);
    }
    expect(
      quarantinedComicSource(_source('manga.bilibili.com', '漫画')),
      isFalse,
    );
  });

  test(
    'explicit adult labels and bundled adult-labelled hosts are restricted',
    () {
      for (final source in [
        _source('example.com', '漫画🔞'),
        _source('example.com', '普通漫画', group: '🔞漫画'),
        _source('example.com', '肉漫屋'),
        _source('www.18mh.cc', '普通漫画'),
        _source('www.jpxgyw.cc', '普通漫画'),
        _source('www.lcmhx.asia', '普通漫画'),
      ]) {
        expect(adultComicSource(source), isTrue, reason: source.name);
      }
    },
  );

  test('text and audio source labels are classified without genre guesses', () {
    expect(
      adultBookSource(_source('example.com', '普通源🔞', kind: 'text')),
      isTrue,
    );
    expect(
      adultBookSource(_source('example.com', '成人小说网', kind: 'text')),
      isTrue,
    );
    expect(
      adultBookSource(
        _source('example.com', '普通源', group: '🔞', kind: 'audio'),
      ),
      isTrue,
    );
    expect(
      adultBookSource(_source('example.com', '耽美小说', kind: 'text')),
      isFalse,
    );
    expect(
      adultBookSource(_source('example.com', '言情小说', kind: 'text')),
      isFalse,
    );
    expect(quarantinedBookHost('book.tiexue.net'), isTrue);
    expect(quarantinedBookHost('m.60ks.com'), isTrue);
    expect(quarantinedBookHost('www.60ks.com'), isFalse);
    expect(quarantinedBookHost('www.shubang.net'), isFalse);
    expect(quarantinedBookHost('www.qishuzw.com'), isTrue);
    expect(quarantinedBookHost('qishuzw.com'), isFalse);
    expect(quarantinedBookHost('hao8.net'), isTrue);
    expect(quarantinedBookHost('www.hao8.net'), isFalse);
  });

  test(
    'bundled Litu source retains adult evidence without blocking the host',
    () async {
      final bytes = await File(
        'assets/catalogs/books/legado/catalog.json.bz2',
      ).readAsBytes();
      final catalog =
          jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(bytes))) as Map;
      final rows = catalog['records'] as List;
      final comicRecord = rows[1124] as Map;
      final labelledRecord = rows[3309] as Map;
      expect(comicRecord['exploreUrl'], contains('全部黄漫'));
      expect(labelledRecord['bookSourceName'], contains('🔞'));
      expect(comicRecord['searchUrl'], labelledRecord['searchUrl']);
      final comic = parseBookSourceRecord(comicRecord);
      final labelled = parseBookSourceRecord(labelledRecord);
      expect(comic.kind, BookKind.comic);
      expect(comic.endpoint.host, 'litu100.xyz');
      expect(labelled.endpoint.host, comic.endpoint.host);
      expect(adultBookSource(comic), isTrue);
      expect(adultBookSource(labelled), isTrue);
      expect(adultBookHost('litu100.xyz'), isFalse);
      expect(adultBookHost('www.litu100.xyz'), isFalse);
    },
  );

  test('bundled UAA source retains adult catalog evidence by ID', () async {
    final bytes = await File(
      'assets/catalogs/books/legado/catalog.json.bz2',
    ).readAsBytes();
    final catalog =
        jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(bytes))) as Map;
    final record = (catalog['records'] as List)[989] as Map;
    expect(record['exploreUrl'], contains('肉量·全部'));
    expect(record['exploreUrl'], contains('都市激情'));
    expect(record['exploreUrl'], contains('调教虐待'));
    final source = parseBookSourceRecord(record);
    expect(
      source.id,
      '08b828adf2d0154db83894b6b77db3defa9dfae30de8a832fc26a5f7c72cbe07',
    );
    expect(adultBookSource(source), isTrue);
    expect(adultBookHost('api.uaa.com'), isFalse);
  });
}

void _adultEvidenceTests() {
  test(
    'deduplication retains explicit adult evidence from an older variant',
    () {
      final older = _source('sample.example', '原来源', group: '🔞', kind: 'text');
      final newer = _source(
        'sample.example',
        '普通来源',
        group: '小说',
        kind: 'text',
      );
      final result = parseBookSources(
        jsonEncode([
          {...older.toJson(), 'updatedAt': 1},
          {...newer.toJson(), 'updatedAt': 2},
        ]),
      );
      expect(result.sources, hasLength(1));
      expect(result.sources.single.name, '普通来源');
      expect(result.sources.single.adultEvidence, isTrue);
      expect(
        adultBookSource(BookSource.fromJson(result.sources.single.toJson())),
        isTrue,
      );
    },
  );

  test(
    'generic comics and non-comic titles are not classified by this rule',
    () {
      expect(adultComicSource(_source('manga.bilibili.com', '漫画')), isFalse);
      expect(adultComicSource(_source('example.com', '韩漫大全')), isFalse);
      expect(
        adultComicSource(_source('www.18mh.cc', '新闻', kind: 'text')),
        isFalse,
      );
    },
  );
}

void _defaultAdultVisibilityTests() {
  test('default adult filter hides a persisted adult comic source', () async {
    final root = await Directory.systemTemp.createTemp('comic-source-risk-');
    final services = AppServices.scoped(root, AppDatabase.memory());
    addTearDown(() async {
      await services.close();
      await root.delete(recursive: true);
    });
    await services.settings.load();
    await services.supervision.load();
    expect(services.contentPolicy.filterAdult, isTrue);
    final source = _source('www.18mh.cc', '普通漫画');
    expect(services.books.sourceAllowed(source), isFalse);
    expect(
      services.books.bookAllowed(
        Book(
          source.id,
          BookKind.comic,
          '普通作品',
          '',
          Uri.parse('https://www.18mh.cc/comic/1'),
        ),
      ),
      isFalse,
    );
    expect(
      services.books.bookAllowed(
        Book(
          'old-quarantined-source',
          BookKind.comic,
          '普通作品',
          '',
          Uri.parse('https://www.kukk.net/comic/1'),
        ),
      ),
      isFalse,
    );
    expect(
      services.books.sourceAllowed(_source('www.kukk.net', '普通漫画')),
      isFalse,
    );
    await services.books.store.write('books_source:${source.id}', {
      'source': source.toJson(),
      'enabled': true,
    });
    expect(await services.books.sourceEntry(BookKind.comic, source.id), isNull);
    expect(
      (await services.books.sources(
        BookKind.comic,
      )).where((entry) => entry.source.id == source.id),
      isEmpty,
    );
  });
}

void _adultEvidencePersistenceTests() {
  test(
    'adult source metadata survives removal and reopening offline data',
    () async {
      final root = await Directory.systemTemp.createTemp('book-risk-restart-');
      final database = File('${root.path}/books.sqlite');
      var services = AppServices.scoped(root, AppDatabase(database));
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      await _allowAdultFixture(services);
      await services.settings.load();
      await services.supervision.load();
      await services.settings.update({'filterAdult': false});
      final source = _source('evidence.example', '成人源🔞', kind: 'text');
      final book = Book(
        source.id,
        BookKind.text,
        '普通标题',
        '作者',
        source.endpoint.resolve('/book'),
      );
      final chapter = BookChapter('第一章', source.endpoint.resolve('/chapter'));
      await services.books.importSources([source]);
      await services.books.store.saveText(book, chapter, '离线正文');
      expect(
        await services.books.readText(book, chapter, CancellationToken()),
        '离线正文',
      );
      await services.books.removeSource(source);
      await services.close();

      services = AppServices.scoped(root, AppDatabase(database));
      await services.settings.load();
      await services.supervision.load();
      await services.settings.update({'filterAdult': true});
      expect(services.books.bookAllowed(book), isFalse);
      await expectLater(
        services.books.readText(book, chapter, CancellationToken()),
        throwsA(isA<ContentBlocked>()),
      );
      expect(await services.books.store.text(book, chapter), '离线正文');
      await services.settings.update({'filterAdult': false});
      expect(
        await services.books.readText(book, chapter, CancellationToken()),
        '离线正文',
      );
    },
  );
}

void _riskReviewTests() {
  test(
    'assessment is host scoped, persistent and cleared only by current review',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'book-risk-assessment-',
      );
      final services = AppServices.scoped(root, AppDatabase.memory());
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      await services.settings.load();
      await services.supervision.load();
      final source = _source('root.example', '文字源', kind: 'text');
      final alias = _source('root.example', '漫画别名');
      final sibling = _source('other.root.example', '其他站', kind: 'text');
      await services.books.importSources([source, alias, sibling]);
      await services.books.markSourceRisk(source, quarantine: true);
      expect(services.books.sourceAllowed(source), isFalse);
      expect(services.books.sourceAllowed(alias), isFalse);
      expect(services.books.sourceAllowed(sibling), isTrue);
      final oldReview = (await services.books.sourceRiskEntries()).singleWhere(
        (entry) => entry.sourceId == source.id,
      );
      await services.books.markSourceRisk(source, quarantine: true);
      await expectLater(
        services.books.clearSourceRisk(oldReview),
        throwsFormatException,
      );
      final review = (await services.books.sourceRiskEntries()).singleWhere(
        (entry) => entry.sourceId == source.id,
      );
      await services.books.clearSourceRisk(review);
      expect(services.books.sourceAllowed(source), isTrue);
      expect(services.books.sourceAllowed(alias), isTrue);
      await services.books.markSourceRisk(source, quarantine: true);
      await expectLater(
        services.books.clearSourceRisk(review),
        throwsFormatException,
      );
      expect(services.books.sourceAllowed(alias), isFalse);
    },
  );
}

void _historicalSourceTests() {
  test(
    'an unverifiable orphan is hidden while adult filtering is active',
    () async {
      final root = await Directory.systemTemp.createTemp('book-orphan-risk-');
      final services = AppServices.scoped(root, AppDatabase.memory());
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      await _allowAdultFixture(services);
      await services.settings.load();
      await services.supervision.load();
      final book = Book(
        'deleted-source',
        BookKind.text,
        '普通标题',
        '',
        Uri.parse('https://orphan.example/book'),
      );
      final chapter = BookChapter(
        '第一章',
        Uri.parse('https://orphan.example/chapter'),
      );
      await services.books.store.saveText(book, chapter, '离线正文');
      await services.books.ensureSourceRiskLoaded();
      expect(services.books.bookAllowed(book), isFalse);
      await expectLater(
        services.books.readText(book, chapter, CancellationToken()),
        throwsA(isA<ContentBlocked>()),
      );
      await services.settings.update({'filterAdult': false});
      expect(
        await services.books.readText(book, chapter, CancellationToken()),
        '离线正文',
      );
    },
  );

  test(
    'remote-code variants and unknown historical versions are blocked',
    () async {
      final root = await Directory.systemTemp.createTemp('book-rule-risk-');
      final services = AppServices.scoped(root, AppDatabase.memory());
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      await _allowAdultFixture(services);
      await services.settings.load();
      await services.supervision.load();
      await services.settings.update({'filterAdult': false});
      final hosts = ['souxs.leeyegy.com', 'www.qklady.com', 'wap.maxreader.la'];
      await services.books.ensureSourceRiskLoaded();
      for (final host in hosts) {
        final source = _wesrcVariant(host, unsafe: true);
        final safeVersion = _wesrcVariant(host, unsafe: false);
        expect(source.id, safeVersion.id);
        expect(quarantinedBookSourceId(source.id), isTrue);
        expect(quarantinedBookSource(source), isTrue);
        expect(quarantinedBookSource(safeVersion), isFalse);
        expect(services.books.sourceAllowed(source), isFalse);
        final imported = await services.books.importSources([source]);
        expect(imported.skipped, 1);
        // Existing installations can already have this source and offline work.
        await services.books.store.write('books_source:${source.id}', {
          'source': source.toJson(),
          'enabled': true,
        });
        await services.books.refreshSourceRisks();
        final historical = Book(
          source.id,
          BookKind.text,
          '普通作品',
          '',
          source.endpoint.resolve('/book'),
        );
        expect(services.books.bookAllowed(historical), isFalse);
        final chapter = BookChapter('第一章', source.endpoint.resolve('/chapter'));
        await services.books.store.saveText(historical, chapter, '离线正文');
        await services.books.store.deleteSource(source);
        await services.books.refreshSourceRisks();
        expect(services.books.bookAllowed(historical), isFalse);
        await expectLater(
          services.books.readText(historical, chapter, CancellationToken()),
          throwsA(isA<ContentBlocked>()),
        );
        final recovered = await services.books.importSources([safeVersion]);
        expect(recovered.added, 1);
        expect(services.books.sourceAllowed(safeVersion), isTrue);
        expect(services.books.bookAllowed(historical), isTrue);
      }
      // An independently identified source on the same host is not swept in.
      final otherKind = _source('www.qklady.com', '另一类来源', kind: 'audio');
      expect(quarantinedBookSourceId(otherKind.id), isFalse);
      expect(services.books.sourceAllowed(otherKind), isTrue);
    },
  );
}

void _localReadingPolicyTests() {
  test('local reading does not depend on the online source snapshot', () async {
    final root = await Directory.systemTemp.createTemp('local-book-risk-');
    final services = AppServices.scoped(root, AppDatabase.memory());
    addTearDown(() async {
      await services.close();
      await root.delete(recursive: true);
    });
    await services.settings.load();
    await services.supervision.load();
    final book = Book(
      'local',
      BookKind.text,
      '本地书',
      '',
      Uri.parse('book:local'),
    );
    final chapter = BookChapter('第一章', Uri.parse('book:local#1'));
    await services.books.store.saveText(book, chapter, '本地正文');
    services.books.suspendSourceRisks();
    expect(
      await services.books.readText(book, chapter, CancellationToken()),
      '本地正文',
    );
    final credentials = await services.supervision.prepareCredentials(
      'fixture-password',
    );
    await services.supervision.saveCredentials(credentials);
    await expectLater(
      services.books.readText(book, chapter, CancellationToken()),
      throwsA(isA<ContentBlocked>()),
    );
  });
}

void _subscriptionUpdatePolicyTests() {
  test(
    'a rejected adult-labelled subscription update restricts the prior source',
    () async {
      final root = await Directory.systemTemp.createTemp('book-adult-update-');
      final database = File('${root.path}/books.sqlite');
      var services = AppServices.scoped(root, AppDatabase(database));
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      await services.settings.load();
      await services.supervision.load();
      final source = _source(
        'subscribed.example',
        '普通书源',
        group: '小说',
        kind: 'text',
      );
      final subscription = Uri.parse(
        'https://subscription.example/sources.json',
      );
      await services.books.importSources([source], subscription: subscription);
      await services.books.saveSource(source, {'enabled': true});
      final book = Book(
        source.id,
        BookKind.text,
        '普通作品',
        '',
        source.endpoint.resolve('/book'),
      );
      final chapter = BookChapter('第一章', source.endpoint.resolve('/chapter'));
      await services.books.store.saveText(book, chapter, '普通离线正文');
      expect(
        await services.books.readText(book, chapter, CancellationToken()),
        '普通离线正文',
      );
      final adultUpdate = BookSource.fromJson({
        ...source.toJson(),
        'name': '该渠道🔞',
        'updatedAt': 123,
      });
      expect(adultUpdate.id, source.id);
      var notifications = 0;
      services.contentPolicy.addListener(() => notifications++);
      final changes = await services.books.importSources([
        adultUpdate,
      ], subscription: subscription);
      expect(changes.skipped, 1);
      expect(notifications, greaterThan(0));
      expect(
        await services.books.sourceEntry(BookKind.text, source.id),
        isNull,
      );
      expect(services.books.bookAllowed(book), isFalse);
      await expectLater(
        services.books.readText(book, chapter, CancellationToken()),
        throwsA(isA<ContentBlocked>()),
      );
      await services.close();

      services = AppServices.scoped(root, AppDatabase(database));
      await services.settings.load();
      await services.supervision.load();
      await services.books.ensureSourceRiskLoaded();
      expect(
        await services.books.sourceEntry(BookKind.text, source.id),
        isNull,
      );
      expect(services.books.bookAllowed(book), isFalse);
      await expectLater(
        services.books.readText(book, chapter, CancellationToken()),
        throwsA(isA<ContentBlocked>()),
      );
      expect(await services.books.store.text(book, chapter), '普通离线正文');
    },
  );
}
