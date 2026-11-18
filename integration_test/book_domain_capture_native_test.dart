import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/features/books/data/book_latest_aggregation.dart';
import 'package:zero_player/features/books/data/legado/legado_script.dart';
import 'package:zero_player/features/books/data/legado/legado_worker.dart';
import 'package:zero_player/features/books/domain/book.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'captured live pages parse with reviewed native rules',
    (tester) async {
      const projectRoot = String.fromEnvironment('PROJECT_ROOT');
      final root = Directory('$projectRoot/build/book-domain-update-20261118');
      final data =
          jsonDecode(
                await rootBundle.loadString(
                  'assets/catalogs/books/reviewed-domain-updates.json',
                ),
              )
              as Map;
      final results = <Map<String, Object?>>[];
      final editions = <({Book book, List<BookChapter> chapters})>[];
      for (final raw in data['updates'] as List) {
        final result = await _captureSite(raw as Map, root);
        editions.add((book: result.book, chapters: result.chapters));
        results.add(result.metadata);
      }
      final short = editions.last;
      final added = planBookLatestChapters(
        short.book,
        short.chapters,
        editions,
      );
      expect(short.chapters.length + added.length, greaterThanOrEqualTo(949));
      await File('${root.path}/native-capture-parsing.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'results': results,
          'aggregatedEntries': short.chapters.length + added.length,
          'scope':
              'Native parser replay of pages captured through OS proxy; not an application direct-network pass.',
        }),
      );
    },
    skip: !const bool.fromEnvironment('RUN_BOOK_DOMAIN_CAPTURED'),
  );
}

Future<LegadoPage> _run(
  BookSource source,
  Uri uri,
  LegadoOperation operation,
  String input, {
  Book? book,
  Map<String, String> documents = const {},
}) => runLegadoJob(
  LegadoJob(
    source,
    uri,
    operation,
    input: input,
    book: book,
    documents: documents,
  ),
  CancellationToken(),
);

Future<LegadoPage> _deqiBody(
  BookSource source,
  Uri uri,
  Directory root,
  String input,
) async {
  final tokenUrl =
      'https://www.deqixss.com/scripts/chapter.js.php?aid=123&cid=80104&referrer=${Uri.encodeComponent(uri.toString())}';
  final documents = {
    tokenUrl: await File('${root.path}/deqi-token-fresh.js').readAsString(),
  };
  try {
    await _run(
      source,
      uri,
      LegadoOperation.content,
      input,
      documents: documents,
    );
    fail('API response is required');
  } on LegadoNeedsDocument catch (pending) {
    documents[pending.address] = await File(
      '${root.path}/deqi-content-browser.json',
    ).readAsString();
  }
  return _run(
    source,
    uri,
    LegadoOperation.content,
    input,
    documents: documents,
  );
}

Future<({Book book, List<BookChapter> chapters, Map<String, Object?> metadata})>
_captureSite(Map raw, Directory root) async {
  final source = BookSource.fromJson(raw['source'] as Map);
  final deqi = source.endpoint.host.contains('deqi');
  final prefix = deqi ? 'deqi' : 'jh';
  final uri = source.endpoint.resolve(deqi ? '/books/123/' : '/140499/');
  Future<String> page(String name) =>
      File('${root.path}/$prefix-$name.html').readAsString();
  final search = await _run(
    source,
    uri,
    LegadoOperation.books,
    await page('search'),
  );
  final found = search.books.singleWhere(
    (b) => b.title == '夜无疆' && b.author == '辰东',
  );
  expect(found.uri, uri);
  final detail = (await _run(
    source,
    uri,
    LegadoOperation.details,
    await page('book'),
  )).books.single;
  expect(detail.category, isNotEmpty);
  final chapters = (await _run(
    source,
    uri,
    LegadoOperation.toc,
    await page('book'),
    book: detail,
  )).chapters;
  expect(chapters.length, deqi ? greaterThanOrEqualTo(949) : 68);
  final chapterUri = source.endpoint.resolve(
    deqi ? '/books/123/80104.html' : '/140499/61930968.html',
  );
  final chapter = chapters.singleWhere((c) => c.uri == chapterUri);
  final content = deqi
      ? await _deqiBody(source, chapterUri, root, await page('chapter'))
      : await _run(
          source,
          chapterUri,
          LegadoOperation.content,
          await page('chapter'),
        );
  var characters = content.content.length;
  if (!deqi) {
    expect(content.links, ['61930968_2.html']);
    final second = await _run(
      source,
      chapterUri.resolve(content.links.single),
      LegadoOperation.content,
      await page('chapter2'),
    );
    expect(second.links, isEmpty);
    characters += second.content.length;
    expect(second.content, isNot(contains('本章未完')));
  }
  expect(characters, greaterThan(2000));
  return (
    book: detail,
    chapters: chapters,
    metadata: {
      'host': source.endpoint.host,
      'chapters': chapters.length,
      'latest': chapters.last.title,
      'sampleChapter': chapter.title,
      'bodyCharacters': characters,
      'category': detail.category,
    },
  );
}
