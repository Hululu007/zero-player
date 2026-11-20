import 'dart:convert';

import '../../../core/network/cancellation_token.dart';
import '../../../core/network/document_client.dart';
import '../domain/book.dart';
import '../domain/book_catalog_rules.dart';
import '../domain/legado_source.dart';

/// Static HTTPS adapter derived from the public BoKan source protocol.
final class BookanAudioClient {
  const BookanAudioClient(this.network);

  final DocumentClient network;
  static final _legacyMapping = BookCatalogRules.fromJson(const {
    'list': 'list',
    'id': 'id',
    'title': 'name',
    'author': 'extra.author',
    'description': 'intro',
    'cover': 'cover',
  });

  static const categories = <LegadoCategory>[
    LegadoCategory('经典必读', '1314'),
    LegadoCategory('国学经典', '1320'),
    LegadoCategory('文学文艺', '1306'),
    LegadoCategory('少年读物', '1305'),
    LegadoCategory('儿童文学', '1304'),
    LegadoCategory('心理哲学', '1310'),
    LegadoCategory('育儿心经', '1309'),
    LegadoCategory('家庭健康', '1311'),
    LegadoCategory('青春励志', '1307'),
    LegadoCategory('历史小说', '1312'),
    LegadoCategory('商业财经', '1315'),
    LegadoCategory('科技科普', '1313'),
    LegadoCategory('故事会', '1303'),
    LegadoCategory('红色岁月', '1316'),
    LegadoCategory('社会观察', '1318'),
    LegadoCategory('音乐戏曲', '1317'),
    LegadoCategory('相声评书', '1319'),
  ];

  Future<Map> _get(
    Uri uri,
    String host,
    CancellationToken token, {
    bool allowRedirects = true,
  }) async {
    final target = publicBookUri(uri);
    if (target.host != host) throw const FormatException('博看接口域名无效');
    final response = await network.get(
      target,
      cancellation: token,
      mapRedirect: allowRedirects
          ? null
          : (_) => throw const FormatException('成人过滤期间不跟随发现页面重定向'),
      validateTarget: (redirect) {
        if (publicBookUri(redirect).host != host) {
          throw const FormatException('博看接口跳转超出域名范围');
        }
      },
    );
    token.check();
    final value = jsonDecode(response.text);
    if (value is! Map || value['code'] != 0 || value['data'] is! Map) {
      throw const FormatException('博看接口未返回有效数据');
    }
    return value['data'] as Map;
  }

  Future<BookDiscoveryPage> discover(
    BookSource source,
    CancellationToken token, {
    LegadoCategory? category,
    int page = 1,
    bool allowRedirects = true,
  }) async {
    final id = category?.address ?? categories.first.address;
    if (!categories.any((item) => item.address == id)) {
      throw const FormatException('博看分类编号无效');
    }
    final current = page.clamp(1, 1000);
    final uri = source.endpoint.replace(
      queryParameters: {
        'instance_id': '25304',
        'page': '$current',
        'category_id': id,
        'num': '24',
      },
    );
    final data = await _get(
      uri,
      source.endpoint.host,
      token,
      allowRedirects: allowRedirects,
    );
    final books = _books(source, data, 24, stage: 'discover');
    final total = int.tryParse('${data['total']}') ?? 0;
    return (
      books: books,
      next: current * 24 < total && books.isNotEmpty && current < 1000
          ? '${current + 1}'
          : null,
    );
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
    final uri = Uri.https('es.bookan.com.cn', '/api/v3/voice/book', {
      'instanceId': '25304',
      'keyword': query.trim(),
      'pageNum': '${page.clamp(1, 1000)}',
      'limitNum': '20',
    });
    final data = await _get(uri, 'es.bookan.com.cn', token);
    return _books(source, data, 20, stage: 'search');
  }

  List<Book> _books(
    BookSource source,
    Map payload,
    int limit, {
    required String stage,
  }) {
    final mapping = source.jsonCatalog[stage] ?? _legacyMapping;
    final raw = mapping.read(payload, 'list');
    if (raw is! List) throw const FormatException('博看书目结构无效');
    final books = <Book>[];
    for (final row in raw.take(limit)) {
      if (row is! Map) continue;
      final id = '${mapping.read(row, 'id')}';
      final title = bookLabel(mapping.read(row, 'title'));
      if (!RegExp(r'^\d{1,10}$').hasMatch(id) || title.isEmpty) continue;
      final uri = source.endpoint.replace(
        path: '/voice/album/units',
        queryParameters: {'album_id': id},
      );
      books.add(
        Book(
          source.id,
          BookKind.audio,
          title,
          bookLabel(mapping.read(row, 'author')),
          uri,
          description: bookLabel(mapping.read(row, 'description'), 600),
          cover: bookCoverAddress(
            source.endpoint,
            '${mapping.read(row, 'cover') ?? ''}',
          ),
        ),
      );
    }
    return books;
  }

  Future<List<BookChapter>> chapters(
    BookSource source,
    Book book,
    CancellationToken token,
  ) async {
    final id = book.uri.queryParameters['album_id'] ?? '';
    if (!RegExp(r'^\d{1,10}$').hasMatch(id) ||
        book.uri.host != source.endpoint.host) {
      throw const FormatException('博看作品编号无效');
    }
    final chapters = <BookChapter>[];
    var lastPage = 1;
    for (var page = 1; page <= 20 && page <= lastPage; page++) {
      final uri = book.uri.replace(
        queryParameters: {
          'album_id': id,
          'page': '$page',
          'num': '20',
          'order': '1',
        },
      );
      final data = await _get(uri, source.endpoint.host, token);
      lastPage = (int.tryParse('${data['last_page']}') ?? 1).clamp(1, 200);
      final rows = data['list'];
      if (rows is! List) throw const FormatException('博看章节结构无效');
      for (final row in rows.take(20)) {
        if (row is! Map) continue;
        final title = bookLabel(row['title']);
        final address = row['file'];
        if (title.isEmpty || address is! String || address.isEmpty) continue;
        try {
          final audio = source.requestTarget(
            legacyBookUri(Uri.parse(address)),
            media: true,
          );
          chapters.add(BookChapter(title, audio));
        } on FormatException {
          // Skip media outside the reviewed HTTPS domain.
        }
      }
    }
    if (lastPage > 20) throw const FormatException('博看目录超过 400 章，未完整获取');
    return chapters;
  }

  Uri audio(BookSource source, BookChapter chapter) =>
      source.requestTarget(chapter.uri, media: true);
}
