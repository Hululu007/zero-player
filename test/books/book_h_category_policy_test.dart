import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/persistence/installation_metadata.dart';
import 'package:zero_player/features/books/application/book_category_policy.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_source_risk.dart';
import 'package:zero_player/features/books/domain/legado_source.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

const _sources = <int, (String, String, String)>{
  1562: (
    'c78c224cdc006f5657ca069d62f4821732137e56a88166ee49b7e067307a01fa',
    'H文',
    '言情',
  ),
  4799: (
    'f50a1b9e04c3959c3a55ec07bea80c04fb9772bfe05f958c5da2ebd518cf2398',
    '激情H文',
    '都市言情',
  ),
  1360: (
    'd01243dd8c895738382c898561e851fa5a1e13a4d941578ec473641cb268380a',
    '高H',
    '耽美',
  ),
  3554: (
    'f12a4981a79b332d872f90799c3f624c3019e9928a759d48e7b95d643da0a9c6',
    '高H',
    '校园',
  ),
  206: (
    '9f3a9631d67f14d5dc1de9dff73f7aef0b3e8540e237ebdb6f23b84149619d21',
    '高    H',
    '腹黑攻',
  ),
  4533: (
    '741f7ba69997207a3fb04701e2f1cf1fe706520e7b80d8268058ecf1321b17f3',
    '情欲小说',
    '言情小说',
  ),
  4560: (
    '546ed179fed46c6cc05454b5fd6d827f12badb8bdce82eadc0b233f1bcbed62b',
    '情欲小说',
    '言情小说',
  ),
  204: (
    '00ad8bd937876d6947e44802fd56f20dd31031e1eb4b8613c51b9f2ca2abf231',
    '情慾',
    '奇幻',
  ),
  4827: (
    '277996a25054f598fc8c500b7d3224741d101343505bb9c1918ebd7c410369c7',
    '强奸',
    '校园',
  ),
  4246: (
    'bf922ddc62d163a364f76893d01341391becf04acaae2d2cc07dc3340338a016',
    '强奸',
    '科幻',
  ),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'actual mixed sources restrict only explicitly adult book categories',
    () async {
      await _withServices((services, requests) async {
        final records = await _catalogRecords();
        for (final entry in _sources.entries) {
          final source = parseBookSourceRecord(records[entry.key]);
          final (id, adultLabel, ordinaryLabel) = entry.value;
          expect(source.id, id, reason: 'record ${entry.key}');
          expect(
            adultBookSource(source),
            isFalse,
            reason: 'mixed record ${entry.key}',
          );
          final categories = source.legado!.categories;
          final adults = categories
              .where((item) => item.title == adultLabel)
              .toList();
          final ordinary = categories
              .where((item) => item.title == ordinaryLabel)
              .toList();
          expect(adults, isNotEmpty, reason: 'record ${entry.key}');
          expect(ordinary, isNotEmpty, reason: 'record ${entry.key}');
          expect(
            adults.every(
              (item) => !bookCategoryAllowed(services.contentPolicy, item),
            ),
            isTrue,
          );
          expect(
            ordinary.every(
              (item) => bookCategoryAllowed(services.contentPolicy, item),
            ),
            isTrue,
          );
          if (entry.key == 1360) {
            expect(adults.any((item) => item.group == '标签'), isTrue);
          }
          if (entry.key == 204) {
            expect(adults.any((item) => item.group == '标签'), isTrue);
          }
        }
        expect(requests, isEmpty);
      });
    },
  );

  test('H category rankings are hidden and cannot be requested', () async {
    await _withServices((services, requests) async {
      final records = await _catalogRecords();
      for (final index in [1562, 4799]) {
        final source = parseBookSourceRecord(records[index]);
        final target = source.legado!.categories
            .where(
              (item) => index == 1562
                  ? item.title == 'H文' || item.title.startsWith('H小说')
                  : item.title.startsWith('激情H文'),
            )
            .toList();
        expect(target, hasLength(15), reason: 'record $index');
        expect(
          target.every(
            (item) => !bookCategoryAllowed(services.contentPolicy, item),
          ),
          isTrue,
        );
        final changes = await services.books.importSources([source]);
        expect(changes.added, 1);
        await services.books.saveSource(source, {'enabled': true});
        expect(services.books.sourceAllowed(source), isTrue);
        final visible = await services.books.categories(
          source.kind,
          source.id,
          CancellationToken(),
        );
        expect(
          visible.any(
            (item) => target.any((denied) => denied.title == item.title),
          ),
          isFalse,
        );
        expect(
          visible.map((item) => item.title),
          contains(index == 1562 ? '言情' : '都市言情'),
        );
        await expectLater(
          services.books.discover(
            source.kind,
            source.id,
            CancellationToken(),
            category: target.first,
          ),
          throwsA(isA<ContentBlocked>()),
        );
        final book = Book(
          source.id,
          source.kind,
          '普通标题',
          '作者',
          source.endpoint.resolve('/book/1'),
          category: target.first.title,
        );
        expect(services.books.bookAllowed(book), isFalse);
        await services.settings.update({'filterAdult': false});
        final unfiltered = await services.books.categories(
          source.kind,
          source.id,
          CancellationToken(),
        );
        expect(
          unfiltered.map((item) => item.title),
          contains(target.first.title),
        );
        expect(services.books.bookAllowed(book), isTrue);
        await services.settings.update({'filterAdult': true});
      }
      expect(requests, isEmpty);
    });
  });

  test(
    'composite categories of an imported source keep the existing guard',
    () async {
      await _withServices((services, requests) async {
        final source = parseBookSourceRecord((await _catalogRecords())[203]);
        expect(
          source.id,
          '870b827acc3fd539dfef41d0a83dacf6699922b14f7ee3145abdc51de54d3f1c',
        );
        expect(adultBookSource(source), isFalse);
        final categories = source.legado!.categories;
        const adultTitles = {'不限·高H', '連載·高H', '完結·高H'};
        const ordinaryTitles = {'不限·BL', '不限·校園'};
        final restricted = categories
            .where((item) => adultTitles.contains(item.title))
            .toList();
        final ordinary = categories
            .where((item) => ordinaryTitles.contains(item.title))
            .toList();
        expect(restricted, hasLength(3));
        expect(ordinary, hasLength(2));
        expect(
          restricted.every(
            (item) => !bookCategoryAllowed(services.contentPolicy, item),
          ),
          isTrue,
        );
        expect(
          ordinary.every(
            (item) => bookCategoryAllowed(services.contentPolicy, item),
          ),
          isTrue,
        );

        expect((await services.books.importSources([source])).added, 1);
        await services.books.saveSource(source, {'enabled': true});
        expect(services.books.sourceAllowed(source), isTrue);
        Book book(String category) => Book(
          source.id,
          source.kind,
          '普通标题',
          '作者',
          source.endpoint.resolve('/book/1'),
          category: category,
        );
        for (final item in restricted) {
          expect(services.books.bookAllowed(book(item.title)), isFalse);
        }
        for (final item in ordinary) {
          expect(services.books.bookAllowed(book(item.title)), isTrue);
        }

        // Its POST templates cannot be safely compared without executing a
        // network-dependent expression. Keep the existing fail-closed guard.
        final visible = await services.books.categories(
          source.kind,
          source.id,
          CancellationToken(),
        );
        expect(visible, isEmpty);
        for (final item in [restricted.first, ordinary.first]) {
          await expectLater(
            services.books.discover(
              source.kind,
              source.id,
              CancellationToken(),
              category: item,
            ),
            throwsA(isA<ContentBlocked>()),
          );
        }

        final ordinaryBook = book(ordinary.last.title);
        final chapter = BookChapter(
          '第一章',
          source.endpoint.resolve('/chapter/1'),
        );
        const body = '这一章讨论 H文 标签的编辑规范。';
        await services.books.store.saveText(ordinaryBook, chapter, body);
        expect(
          await services.books.readText(
            ordinaryBook,
            chapter,
            CancellationToken(),
          ),
          body,
        );
        expect(requests, isEmpty);

        await services.settings.update({'filterAdult': false});
        for (final item in restricted) {
          expect(bookCategoryAllowed(services.contentPolicy, item), isTrue);
          expect(services.books.bookAllowed(book(item.title)), isTrue);
        }
        final unfiltered = await services.books.categories(
          source.kind,
          source.id,
          CancellationToken(),
        );
        expect(
          unfiltered.map((item) => item.title).toSet(),
          containsAll(adultTitles),
        );
        expect(requests, isEmpty);
      });
    },
  );

  test('composite labels retain boundaries and adjacent warnings', () async {
    await _withServices((services, requests) async {
      for (final value in [
        '不限·高H',
        '連載·高H',
        '完結·高H',
        '校园.高H',
        '校园．高H',
        '类型：高H',
        '言情 H文',
        'H文 言情',
        '校园 · 高H',
        '玄幻 H小说',
        'BL 高H',
        '都市|激情H文',
        '校园·情欲',
        '标签 强奸',
        '反对 强奸 · 高H',
        '禁止 高H 情欲',
        '反对,高H',
        '反对,强奸',
      ]) {
        expect(
          bookCategoryTextAllowed(services.contentPolicy, value),
          isFalse,
          reason: value,
        );
      }
      for (final value in [
        'H.G.威尔斯',
        'H·G·威尔斯',
        'HTML5',
        'HJ文库',
        'H5',
        'PHP文化',
        'https://example.com/docs/HTML5',
        '普通文本：校园',
        '未满十八岁禁止访问',
        'BL',
        '耽美',
        '都市言情',
        '反对 H文',
        '禁止 高H',
        '禁止 高 H',
        '反对 强奸',
        '反对强奸',
        '反对 情欲',
        '强奸法律研究',
      ]) {
        expect(
          bookCategoryTextAllowed(services.contentPolicy, value),
          isTrue,
          reason: value,
        );
      }
      expect(
        bookCategoryTextAllowed(services.contentPolicy, '普通', '类型：高H'),
        isFalse,
      );
      expect(
        bookCategoryTextAllowed(services.contentPolicy, '普通', '反对 H文'),
        isTrue,
      );
      expect(
        bookCategoryTextAllowed(services.contentPolicy, '高H', '反对'),
        isFalse,
      );
      expect(services.contentPolicy.textAllowed('这一章讨论 H文 标签的编辑规范。'), isTrue);
      await services.settings.update({'filterAdult': false});
      for (final value in ['校园.高H', '类型：高H', '言情 H文', '校园·情欲']) {
        expect(
          bookCategoryTextAllowed(services.contentPolicy, value),
          isTrue,
          reason: value,
        );
      }
      expect(requests, isEmpty);
    });
  });

  test(
    'explicit erotic and sexual-violence categories are locally restricted',
    () async {
      await _withServices((services, requests) async {
        final records = await _catalogRecords();
        for (final index in [204, 4827, 4246, 4533, 4560]) {
          final source = parseBookSourceRecord(records[index]);
          final labels = _sources[index]!;
          final target = source.legado!.categories.firstWhere(
            (item) => item.title == labels.$2,
          );
          final changes = await services.books.importSources([source]);
          expect(changes.added, 1, reason: 'record $index');
          await services.books.saveSource(source, {'enabled': true});
          expect(services.books.sourceAllowed(source), isTrue);
          final visible = await services.books.categories(
            source.kind,
            source.id,
            CancellationToken(),
          );
          expect(visible.map((item) => item.title), isNot(contains(labels.$2)));
          expect(visible.map((item) => item.title), contains(labels.$3));
          await expectLater(
            services.books.discover(
              source.kind,
              source.id,
              CancellationToken(),
              category: target,
            ),
            throwsA(isA<ContentBlocked>()),
          );
          Book book(String category) => Book(
            source.id,
            source.kind,
            '普通标题',
            '作者',
            source.endpoint.resolve('/book/1'),
            category: category,
          );
          expect(services.books.bookAllowed(book(labels.$2)), isFalse);
          expect(services.books.bookAllowed(book(labels.$3)), isTrue);
        }
        expect(requests, isEmpty);
      });
    },
  );

  test(
    'ordinary H text remains available and filtering can be disabled',
    () async {
      await _withServices((services, requests) async {
        final records = await _catalogRecords();
        for (final item in [
          (223, 'HTML5'),
          (223, 'Shell Script'),
          (3967, 'HJ文库'),
          (1621, 'H·G·威尔斯'),
        ]) {
          final source = parseBookSourceRecord(records[item.$1]);
          final matches = source.legado!.categories
              .where((category) => category.title == item.$2)
              .toList();
          expect(matches, isNotEmpty, reason: 'record ${item.$1}');
          expect(
            matches.every(
              (category) =>
                  bookCategoryAllowed(services.contentPolicy, category),
            ),
            isTrue,
          );
        }
        for (final value in [
          '言情',
          '言情小说',
          'BL',
          '耽美',
          'Happy',
          'HISTORY',
          'HTML5',
          'H5',
          'PHP文化',
          '强奸法律研究',
        ]) {
          expect(
            bookCategoryTextAllowed(services.contentPolicy, value),
            isTrue,
            reason: value,
          );
        }
        for (final value in [
          '高 H',
          '高Ｈ',
          'Ｈ文',
          'H小說日排行',
          '激情H文总收藏',
          '情慾小說',
          '情慾',
          '強姦',
        ]) {
          expect(
            bookCategoryTextAllowed(services.contentPolicy, value),
            isFalse,
            reason: value,
          );
        }
        expect(
          bookCategoryAllowed(
            services.contentPolicy,
            const LegadoCategory('普通名称', '/ordinary', group: '高H'),
          ),
          isFalse,
        );
        expect(services.contentPolicy.textAllowed('高H'), isTrue);
        expect(services.contentPolicy.textAllowed('强奸'), isTrue);

        await services.settings.update({'filterAdult': false});
        for (final value in [
          '高H',
          'H文',
          'H小说日排行',
          '激情H文',
          '情欲小说',
          '情慾',
          '强奸',
        ]) {
          expect(
            bookCategoryTextAllowed(services.contentPolicy, value),
            isTrue,
            reason: value,
          );
        }
        final credentials = await services.supervision.prepareCredentials(
          'fixture-password',
        );
        await services.supervision.saveCredentials(credentials);
        expect(services.supervision.enabled, isTrue);
        expect(services.contentPolicy.filterAdult, isTrue);
        expect(bookCategoryTextAllowed(services.contentPolicy, '高H'), isFalse);
        expect(bookCategoryTextAllowed(services.contentPolicy, '言情小说'), isTrue);
        expect(requests, isEmpty);
      });
    },
  );
}

Future<List> _catalogRecords() async {
  final bytes = await File(
    'assets/catalogs/books/legado/catalog.json.bz2',
  ).readAsBytes();
  return (jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(bytes)))
          as Map)['records']
      as List;
}

Future<void> _withServices(
  Future<void> Function(AppServices, List<Uri>) body,
) async {
  final tempBase = await Directory.systemTemp.resolveSymbolicLinks();
  final root = await Directory.systemTemp.createTemp('book-h-category-');
  final originalRoot = await root.resolveSymbolicLinks();
  final requests = <Uri>[];
  try {
    await HttpOverrides.runZoned(() async {
      final services = AppServices.scoped(root, AppDatabase.memory());
      try {
        await services.db.write(
          'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
          [installationAccessKey, upgradedInstallationAccess],
        );
        await services.settings.load();
        await services.supervision.load();
        await body(services, requests);
      } finally {
        await services.close();
      }
    }, createHttpClient: (_) => _NoNetwork(requests));
  } finally {
    final actualRoot = await root.resolveSymbolicLinks();
    if (path.normalize(actualRoot).toLowerCase() !=
            path.normalize(originalRoot).toLowerCase() ||
        path.normalize(path.dirname(actualRoot)).toLowerCase() !=
            path.normalize(tempBase).toLowerCase() ||
        !path.basename(actualRoot).startsWith('book-h-category-')) {
      throw StateError(
        'Temporary category directory escaped its expected parent',
      );
    }
    await root.delete(recursive: true);
  }
}

final class _NoNetwork implements HttpClient {
  _NoNetwork(this.requests);
  final List<Uri> requests;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) {
    requests.add(uri);
    throw StateError('Unexpected network request in category test');
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isSetter) return null;
    return super.noSuchMethod(invocation);
  }
}
