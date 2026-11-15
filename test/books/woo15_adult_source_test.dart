import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/persistence/installation_metadata.dart';
import 'package:zero_player/features/books/data/aoaostar_book_catalog.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_source_risk.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

const _selected = {
  4218: '1b9fbc433c81ac824c2a20ece0332a66c79c7abe8a4da1b28b74f0a26e220763',
  4220: 'cab07dec6b3f4ab2ece1b1a261aad7e155b9de9bcc4f517f70cd5490011ba393',
  4222: '38ff9c4ee9a4b64192f10046721e2c6a2c50c2ec80d3d3b5eccd3ae7e40b6022',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'redacted homepage evidence matches the selected bundled sources',
    () async {
      final evidence =
          jsonDecode(
                await File(
                  'docs/implementation/legado-woo15-home-review-20261116.json',
                ).readAsString(),
              )
              as Map;
      final catalog = await AoaoStarBookCatalog.load();
      expect(evidence['catalog_archive_sha256'], catalog.revision);
      final records = await _records();
      for (final entry in _selected.entries) {
        final source = parseBookSourceRecord(records[entry.key] as Map);
        expect(source.id, entry.value);
        expect(source.endpoint.host, 'm.woo15.com');
        expect(adultBookSource(source), isTrue);
      }
      final selected = (evidence['selected_sources'] as List).cast<Map>();
      expect({
        for (final row in selected) row['record_index']: row['source_id'],
      }, _selected);
      final imported = await catalog.read();
      final sources = {
        for (final source in imported.sources) source.id: source,
      };
      for (final id in _selected.values) {
        expect(sources[id], isNotNull, reason: id);
        expect(adultBookSource(sources[id]!), isTrue);
      }
      final observations = (evidence['observations'] as List).cast<Map>();
      expect(observations, hasLength(2));
      expect(
        (evidence['method'] as Map)['saved_response_body_or_excerpt'],
        isFalse,
      );
      for (final observation in observations) {
        expect(observation['http_status'], 200);
        expect(observation['sample_bytes'], 32768);
        expect(observation['truncated'], isTrue);
        expect(
          observation['sample_sha256'],
          matches(RegExp(r'^[a-f0-9]{64}$')),
        );
        final metadata = observation['metadata'] as Map;
        expect(metadata['description_indicates_adult_audience'], isTrue);
        expect(metadata['visible_adult_business_clue'], isTrue);
      }
    },
  );

  test('host classification is exact and normalizes case and a final dot', () {
    expect(adultBookHost('m.woo15.com'), isTrue);
    expect(adultBookHost('M.WOO15.COM.'), isTrue);
    for (final other in [
      'woo15.com',
      'www.woo15.com',
      'sub.m.woo15.com',
      'm.woo15.com.example',
      'm.woo15.net',
    ]) {
      expect(adultBookHost(other), isFalse, reason: other);
    }
  });

  test(
    'filter hides the exact host and cached books without deleting them',
    () async {
      final records = await _records();
      final sources = [
        for (final index in _selected.keys)
          parseBookSourceRecord(records[index] as Map),
      ];
      final sibling = BookSource.fromJson({
        'name': '普通来源',
        'kind': 'text',
        'format': 'feed',
        'url': 'https://www.woo15.com/feed',
        'sourceKey': 'fixture:woo15-sibling',
      });
      final root = await Directory.systemTemp.createTemp('woo15-policy-');
      final services = AppServices.scoped(root, AppDatabase.memory());
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      await services.db.write('INSERT OR REPLACE INTO app_meta VALUES(?,?)', [
        installationAccessKey,
        upgradedInstallationAccess,
      ]);
      await services.settings.load();
      await services.supervision.load();
      await services.books.sources(BookKind.text);
      expect(services.contentPolicy.filterAdult, isTrue);
      final filtered = await services.books.importSources([
        ...sources,
        sibling,
      ]);
      expect(filtered.skipped, 3);
      expect(filtered.added, 1);
      expect(services.books.sourceAllowed(sibling), isTrue);

      await services.settings.update({'filterAdult': false});
      final imported = await services.books.importSources(sources);
      expect(imported.added, 3);
      for (final source in sources) {
        await services.books.saveSource(source, {'enabled': true});
        expect(services.books.sourceAllowed(source), isTrue);
      }
      final source = sources.first;
      final book = Book(
        source.id,
        BookKind.text,
        '普通标题',
        '',
        Uri.parse('https://m.woo15.com/__offline_fixture__'),
      );
      final chapter = BookChapter(
        '第一章',
        Uri.parse('https://m.woo15.com/__chapter_fixture__'),
      );
      await services.books.store.saveText(book, chapter, '离线测试文字');
      expect(
        await services.books.readText(book, chapter, CancellationToken()),
        '离线测试文字',
      );

      await services.settings.update({'filterAdult': true});
      for (final source in sources) {
        expect(services.books.sourceAllowed(source), isFalse);
        expect(
          await services.books.sourceEntry(BookKind.text, source.id),
          isNull,
        );
      }
      expect(services.books.sourceAllowed(sibling), isTrue);
      expect(services.books.bookAllowed(book), isFalse);
      await expectLater(
        services.books.readText(book, chapter, CancellationToken()),
        throwsA(isA<ContentBlocked>()),
      );
      expect(await services.books.store.text(book, chapter), '离线测试文字');

      await services.settings.update({'filterAdult': false});
      expect(services.books.sourceAllowed(source), isTrue);
      expect(
        await services.books.readText(book, chapter, CancellationToken()),
        '离线测试文字',
      );
    },
  );
}

Future<List<dynamic>> _records() async {
  final bytes = await File(
    'assets/catalogs/books/legado/catalog.json.bz2',
  ).readAsBytes();
  final data =
      jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(bytes))) as Map;
  return data['records'] as List<dynamic>;
}
