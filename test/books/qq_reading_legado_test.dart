import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/data/legado/legado_worker.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/qq_reading_legacy_source_fix.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map raw;
  setUpAll(() async {
    final archive = await File(
      'assets/catalogs/books/legado/catalog.json.bz2',
    ).readAsBytes();
    final catalog =
        jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive))) as Map;
    raw = (catalog['records'] as List)[3685] as Map;
  });

  test('only the audited original rule set is repaired', () {
    final source = parseBookSourceRecord(raw);
    expect(
      source.id,
      'd6238338a2720edc88eb06d920d7438c69fab9f7f25cb61a0beff9a49ebfeba4',
    );
    expect(source.legado!.search, contains('/api/booksearch/query?'));
    final saved = _oldConfig(source, raw);
    final legacy = saved['legado'] as Map;
    expect(BookSource.fromJson(saved).legado!.rules, source.legado!.rules);
    final customRules = {...legacy['rules'] as Map, 'content': 'custom'};
    final custom = {...legacy, 'rules': customRules};
    expect(
      repairQqReadingLegadoSource(saved, custom)['search'],
      raw['searchUrl'],
    );
    expect(
      BookSource.fromJson({...saved, 'legado': custom}).legado!.search,
      raw['searchUrl'],
    );
    expect(
      repairQqReadingLegadoSource({
        ...saved,
        'url': 'https://other.example/',
      }, legacy)['search'],
      raw['searchUrl'],
    );
    expect(
      repairQqReadingLegadoSource(saved, {
        ...legacy,
        'library': 'custom',
      })['search'],
      raw['searchUrl'],
    );
  });

  test('public search JSON and book details use the updated fields', () async {
    final source = parseBookSourceRecord(raw);
    final token = CancellationToken();
    final search = await runLegadoJob(
      LegadoJob(
        source,
        Uri.parse('https://book.qq.com/api/booksearch/query'),
        LegadoOperation.books,
        input: jsonEncode({
          'code': 0,
          'data': {
            'bookList': [
              {
                'bid': 29855984,
                'title': '三国演义',
                'author': '罗贯中',
                'intro': '简介',
                'category3Name': '名著',
                'totalWords': 1234,
              },
            ],
          },
        }),
      ),
      token,
    );
    final book = search.books.single;
    expect(book.title, '三国演义');
    expect(book.author, '罗贯中');
    expect(book.description, '简介');
    expect(book.uri, Uri.parse('https://book.qq.com/book-detail/29855984'));
    final details = await runLegadoJob(
      LegadoJob(
        source,
        book.uri,
        LegadoOperation.details,
        book: book,
        input:
            '<div class="book-wrap"><div class="book-cover"><img src="https://images.example/cover.jpg"></div><div class="book-info"><h1>三国演义</h1><div class="book-meta"><span class="author gray">罗贯中 著</span></div></div></div>',
      ),
      token,
    );
    expect(details.books.single.author, '罗贯中');
    expect(details.books.single.cover, 'https://images.example/cover.jpg');
  });
}

Map<String, Object?> _oldConfig(BookSource source, Map raw) {
  final search = raw['ruleSearch'] as Map;
  final info = raw['ruleBookInfo'] as Map;
  return {
    ...source.toJson(),
    'legado': {
      ...source.legado!.toJson(),
      'search': raw['searchUrl'],
      'rules': {
        ...source.legado!.rules,
        'searchList': search['bookList'],
        'searchTitle': search['name'],
        'searchLink': search['bookUrl'],
        'searchAuthor': search['author'],
        'searchCover': search['coverUrl'],
        'searchCategory': search['kind'],
        'searchDescription': search['intro'],
        'searchWordCount': search['wordCount'],
        'infoAuthor': info['author'],
        'infoCover': info['coverUrl'],
      },
    },
  };
}
