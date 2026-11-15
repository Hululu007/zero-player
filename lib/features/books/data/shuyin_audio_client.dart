import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/network/cancellation_token.dart';
import '../../../core/network/document_client.dart';
import '../domain/book.dart';
import '../domain/legado_source.dart';

/// Bounded, first-party adapter for the public ShuYin FM API. No plugin code runs.
final class ShuYinAudioClient {
  const ShuYinAudioClient(this.network);

  final DocumentClient network;

  static const _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Referer': 'https://m.mekui.com/',
    'Accept': 'application/json, text/plain, */*',
  };
  static const _tokenKey = '056a308c515e16b2fe5a5c631319339cbc60a8ee0e03d016';

  Future<Map> _request(
    BookSource source,
    CancellationToken token,
    Map<String, String> params, {
    bool signedAudio = false,
  }) async {
    final Document response;
    if (signedAudio) {
      final raw = params.entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join('&');
      final signature = md5.convert(utf8.encode('$raw&token=$_tokenKey'));
      final target = source.endpoint.replace(query: '$raw&token=$signature');
      response = await network.get(
        target,
        headers: _headers,
        cancellation: token,
        validateTarget: source.requestTarget,
      );
    } else {
      // The publisher's GET search cache can return results for another query.
      response = await network.postForm(
        source.endpoint,
        params,
        headers: _headers,
        cancellation: token,
      );
    }
    token.check();
    final value = jsonDecode(response.text);
    if (value is! Map || value['code'] != 1) {
      throw const FormatException('书音FM 未返回有效数据');
    }
    return value;
  }

  Future<List<LegadoCategory>> categories(
    BookSource source,
    CancellationToken token,
  ) async {
    final data = await _request(source, token, {
      'mod': 'column',
      'act': 'navigation',
      'classid': '0',
    });
    final rows = data['list'];
    if (rows is! List) return const [];
    return [
      const LegadoCategory('全部', '0'),
      for (final row in rows.take(80))
        if (row is Map &&
            RegExp(r'^\d{1,6}$').hasMatch('${row['classid']}') &&
            bookLabel(row['classname']).isNotEmpty)
          LegadoCategory(bookLabel(row['classname']), '${row['classid']}'),
    ];
  }

  Future<BookDiscoveryPage> discover(
    BookSource source,
    CancellationToken token, {
    LegadoCategory? category,
    int page = 1,
  }) async {
    final classId = category?.address ?? '0';
    if (!RegExp(r'^\d{1,6}$').hasMatch(classId)) {
      throw const FormatException('分类编号无效');
    }
    final data = await _request(source, token, {
      'mod': 'movie',
      'act': 'list',
      'classid': classId,
      'page': '${page.clamp(1, 1000)}',
      'pagesize': '20',
    });
    return _page(source, data['data'], page);
  }

  Future<List<Book>> books(
    BookSource source,
    String query,
    CancellationToken token, {
    int page = 1,
  }) async {
    if (query.trim().isEmpty) {
      return (await discover(source, token, page: page)).books;
    }
    final data = await _request(source, token, {
      'mod': 'movie',
      'act': 'search',
      'keyword': query.trim(),
      'page': '${page.clamp(1, 1000)}',
      'pagesize': '20',
    });
    if ((data['data'] as Map?)?['keyword'] != query.trim()) {
      throw const FormatException('搜索响应与关键词不符');
    }
    return _page(source, data['data'], page).books;
  }

  BookDiscoveryPage _page(BookSource source, Object? raw, int page) {
    if (raw is! Map || raw['list'] is! List) {
      throw const FormatException('书音FM 书目结构无效');
    }
    final rows = raw['list'] as List;
    final books = <Book>[];
    for (final row in rows.take(20)) {
      if (row is! Map) continue;
      final book = _book(source, row);
      if (book != null) books.add(book);
    }
    final total = int.tryParse('${raw['totalpage']}') ?? 1;
    return (
      books: books,
      next: page < total && page < 1000 ? '${page + 1}' : null,
    );
  }

  Book? _book(BookSource source, Map row) {
    final id = '${row['id']}';
    final title = bookLabel(row['title']);
    if (!RegExp(r'^\d{1,10}$').hasMatch(id) || title.isEmpty) return null;
    final uri = source.endpoint.replace(
      queryParameters: {'mod': 'movie', 'act': 'detail', 'id': id},
    );
    return Book(
      source.id,
      BookKind.audio,
      title,
      bookLabel(row['player']),
      uri,
      description: bookLabel(row['moviesay'], 600),
      cover: bookCoverAddress(source.endpoint, '${row['titlepic'] ?? ''}'),
    );
  }

  Future<Book> details(
    BookSource source,
    Book book,
    CancellationToken token,
  ) async {
    final id = _id(book.uri);
    final data = await _request(source, token, {
      'mod': 'movie',
      'act': 'detail',
      'id': id,
    });
    final row = (data['data'] as Map?)?['detail'];
    if (row is! Map || '${row['id']}' != id) {
      throw const FormatException('书音FM 详情不匹配');
    }
    return book.withDetails(_book(source, row) ?? book);
  }

  Future<List<BookChapter>> chapters(
    BookSource source,
    Book book,
    CancellationToken token,
  ) async {
    final id = _id(book.uri);
    final chapters = <BookChapter>[];
    for (var page = 1; page <= 8; page++) {
      final response = await _request(source, token, {
        'mod': 'movie',
        'act': 'movielist',
        'id': id,
        'page': '$page',
        'pagesize': '500',
      });
      final data = response['data'];
      if (data is! Map ||
          '${data['movid']}' != id ||
          data['moielist'] is! List) {
        throw const FormatException('书音FM 目录不匹配');
      }
      final rows = data['moielist'] as List;
      for (final row in rows.take(500)) {
        if (row is! Map || !RegExp(r'^\d{1,6}$').hasMatch('${row['id']}')) {
          continue;
        }
        final title = bookLabel(row['title']);
        if (title.isEmpty) continue;
        chapters.add(
          BookChapter(
            title,
            source.endpoint.replace(
              queryParameters: {
                'act': 'wapseries',
                'mod': 'movie',
                'id': id,
                'movieId': '${row['id']}',
              },
            ),
          ),
        );
      }
      final count = int.tryParse('${data['count']}') ?? chapters.length;
      if (chapters.length >= count || rows.isEmpty) break;
      if (page == 8) {
        throw const FormatException('书音FM 目录超过 4000 章，未完整获取');
      }
    }
    return chapters;
  }

  Future<Uri> audio(
    BookSource source,
    BookChapter chapter,
    CancellationToken token,
  ) async {
    final id = _id(chapter.uri);
    final movieId = chapter.uri.queryParameters['movieId'] ?? '';
    if (!RegExp(r'^\d{1,6}$').hasMatch(movieId)) {
      throw const FormatException('章节编号无效');
    }
    final data = await _request(source, token, {
      'act': 'wapseries',
      'id': id,
      'mod': 'movie',
      'movieId': movieId,
      't': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
    }, signedAudio: true);
    final address = (data['data'] as Map?)?['SeriesUrl'];
    if (address is! String || address.isEmpty) {
      throw const FormatException('书音FM 未返回音频地址');
    }
    return source.requestTarget(Uri.parse(address), media: true);
  }

  String _id(Uri uri) {
    final id = uri.queryParameters['id'] ?? '';
    if (!RegExp(r'^\d{1,10}$').hasMatch(id)) {
      throw const FormatException('作品编号无效');
    }
    return id;
  }
}
