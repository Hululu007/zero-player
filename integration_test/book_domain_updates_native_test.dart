import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/request_trace.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_latest_aggregation.dart';
import 'package:zero_player/features/books/domain/book.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'reviewed domains support real search, catalogues and complete chapters',
    (tester) async {
      const projectRoot = String.fromEnvironment('PROJECT_ROOT');
      expect(projectRoot, isNotEmpty);
      final root = await Directory.systemTemp.createTemp('book-new-domain-');
      final services = AppServices.scoped(root, AppDatabase.memory());
      final results = <Map<String, Object?>>[];
      final books = <({Book book, List<BookChapter> chapters})>[];
      try {
        await services.settings.load();
        await services.supervision.load();
        await tester.pumpWidget(const SizedBox());
        final entries = await services.books.sources(BookKind.text);
        for (final host in ['www.deqixss.com', 'www.jhsssd.com']) {
          final source = entries
              .singleWhere((e) => e.source.endpoint.host == host)
              .source;
          await services.books.saveSource(source, {'enabled': true});
          final trace = <Map<String, Object?>>[];
          final metadata = await _checkSite(services, source, trace, books);
          expect(trace, isNotEmpty);
          expect(
            trace.every((r) => Uri.parse(r['url'] as String).host == host),
            isTrue,
          );
          expect(trace.every((r) => r['error'] == null), isTrue);
          metadata['trace'] = trace;
          results.add(metadata);
        }
        final short = books.singleWhere(
          (e) => e.book.uri.host == 'www.jhsssd.com',
        );
        final added = planBookLatestChapters(short.book, short.chapters, books);
        expect(short.chapters.length + added.length, greaterThanOrEqualTo(949));
        final report = File(
          '$projectRoot/build/book-domain-update-20261118/native-reading.json',
        );
        await report.parent.create(recursive: true);
        await report.writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'results': results,
            'aggregatedEntries': short.chapters.length + added.length,
            'scope':
                'Real repository, default filtering, public metadata and one chapter per site. No bulk body downloads.',
          }),
        );
        debugPrint(
          'Reviewed domains passed: ${results.map((r) => '${r['host']}: ${r['chapters']} entries / ${r['bodyCharacters']} characters').join('; ')}',
        );
      } finally {
        await services.close();
        await root.delete(recursive: true);
      }
    },
    skip: !const bool.fromEnvironment('RUN_BOOK_DOMAIN_ONLINE'),
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

Future<Map<String, Object?>> _checkSite(
  AppServices services,
  BookSource source,
  List<Map<String, Object?>> trace,
  List<({Book book, List<BookChapter> chapters})> books,
) => traceRequests(trace, () async {
  final host = source.endpoint.host;
  final token = CancellationToken();
  final found = await services.books.find(
    BookKind.text,
    '夜无疆',
    token,
    sourceId: source.id,
  );
  expect(found.failed, 0, reason: '$host: ${jsonEncode(trace)}');
  final book = found.books.singleWhere(
    (b) => b.title == '夜无疆' && b.author == '辰东',
  );
  final detail = await services.books.details(book, token);
  expect(detail.category, isNotEmpty);
  final chapters = await services.books.chapters(detail, token, refresh: true);
  expect(
    chapters.length,
    host.contains('deqi') ? greaterThanOrEqualTo(949) : 68,
  );
  final chapter = host.contains('deqi')
      ? chapters.firstWhere((c) => c.title.startsWith('第69章 '))
      : chapters.last;
  final text = await services.books.readText(detail, chapter, token);
  expect(text.length, greaterThan(2000), reason: host);
  expect(text, isNot(contains('正在加载章节内容')));
  expect(text, isNot(contains('本章未完，请点击下一页继续阅读')));
  books.add((book: detail, chapters: chapters));
  return <String, Object?>{
    'host': host,
    'sourceId': source.id,
    'title': detail.title,
    'author': detail.author,
    'category': detail.category,
    'chapters': chapters.length,
    'latest': chapters.last.title,
    'sampleChapter': chapter.title,
    'bodyCharacters': text.length,
  };
});
