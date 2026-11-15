import 'dart:convert';

import '../../../core/network/cancellation_token.dart';
import '../../../core/network/document_client.dart';
import '../domain/book.dart';
import '../domain/legado_source.dart';

/// Public, free-track protocol identified by static inspection of the source JAR.
final class XimalayaAudioClient {
  const XimalayaAudioClient(this.network);

  final DocumentClient network;

  static const categories = <LegadoCategory>[
    LegadoCategory('有声小说', '3'),
    LegadoCategory('儿童', '6'),
    LegadoCategory('历史', '9'),
  ];

  Future<Map> _get(
    Uri uri,
    String host,
    CancellationToken token, {
    bool allowRedirects = true,
  }) async {
    final target = publicBookUri(uri);
    if (target.host != host) throw const FormatException('喜马拉雅接口域名无效');
    final response = await network.get(
      target,
      cancellation: token,
      mapRedirect: allowRedirects
          ? null
          : (_) => throw const FormatException('成人过滤期间不跟随发现页面重定向'),
      headers: const {'User-Agent': 'Mozilla/5.0'},
      validateTarget: (redirect) {
        if (publicBookUri(redirect).host != host) {
          throw const FormatException('喜马拉雅接口跳转超出域名范围');
        }
      },
    );
    token.check();
    final value = jsonDecode(response.text);
    if (value is! Map) throw const FormatException('喜马拉雅接口数据无效');
    return value;
  }

  Future<BookDiscoveryPage> discover(
    BookSource source,
    CancellationToken token, {
    LegadoCategory? category,
    int page = 1,
    bool allowRedirects = true,
  }) async {
    final id = category?.address ?? categories.first.address;
    if (!categories.any((entry) => entry.address == id)) {
      throw const FormatException('喜马拉雅分类编号无效');
    }
    final current = page.clamp(1, 100);
    final data = await _get(
      Uri.https('www.ximalaya.com', '/revision/category/v2/albums', {
        'pageNum': '$current',
        'pageSize': '30',
        'sort': '0',
        'categoryId': id,
      }),
      'www.ximalaya.com',
      token,
      allowRedirects: allowRedirects,
    );
    if (data['ret'] != 200 || data['data'] is! Map) {
      throw const FormatException('喜马拉雅分类数据无效');
    }
    final result = data['data'] as Map;
    final books = _albums(source, result['albums'], discovery: true);
    final total = int.tryParse('${result['total']}') ?? 0;
    return (
      books: books,
      next: current * 30 < total && current < 100 ? '${current + 1}' : null,
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
    final data = await _get(
      Uri.https('search.ximalaya.com', '/front/v1', {
        'core': 'album',
        'kw': query.trim(),
        'page': '${page.clamp(1, 100)}',
        'rows': '20',
        'device': 'android',
      }),
      'search.ximalaya.com',
      token,
    );
    final response = data['response'];
    if (response is! Map) throw const FormatException('喜马拉雅搜索数据无效');
    return _albums(source, response['docs'], discovery: false);
  }

  List<Book> _albums(
    BookSource source,
    Object? raw, {
    required bool discovery,
  }) {
    if (raw is! List) throw const FormatException('喜马拉雅书目结构无效');
    final books = <Book>[];
    for (final row in raw.take(30)) {
      if (row is! Map ||
          row['isPaid'] == true ||
          row['is_paid'] == true ||
          row['is_vip'] == true ||
          (int.tryParse('${row['vipType'] ?? 0}') ?? 0) != 0 ||
          (int.tryParse('${row['price_type_id'] ?? 0}') ?? 0) != 0) {
        continue;
      }
      final id = '${discovery ? row['albumId'] : row['id']}';
      final title = bookLabel(discovery ? row['albumTitle'] : row['title']);
      if (!RegExp(r'^\d{1,12}$').hasMatch(id) || title.isEmpty) continue;
      final coverRaw =
          '${discovery ? row['albumCoverPath'] : row['cover_path']}';
      final cover = coverRaw.startsWith('http')
          ? coverRaw.replaceFirst('http://', 'https://').split('!').first
          : 'https://imagev2.xmcdn.com/${coverRaw.split('!').first}';
      books.add(
        Book(
          source.id,
          BookKind.audio,
          title,
          bookLabel(discovery ? row['albumUserNickName'] : row['nickname']),
          source.endpoint.replace(queryParameters: {'albumId': id}),
          description: bookLabel(row['intro'], 600),
          cover: Uri.tryParse(cover)?.host == 'imagev2.xmcdn.com' ? cover : '',
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
    final id = book.uri.queryParameters['albumId'] ?? '';
    if (book.uri.host != source.endpoint.host ||
        !RegExp(r'^\d{1,12}$').hasMatch(id)) {
      throw const FormatException('喜马拉雅专辑编号无效');
    }
    final chapters = <BookChapter>[];
    var last = 1;
    for (var page = 1; page <= last && page <= 134; page++) {
      final data = await _get(
        source.endpoint.replace(
          queryParameters: {'albumId': id, 'page': '$page', 'pageSize': '30'},
        ),
        source.endpoint.host,
        token,
      );
      if (data['ret'] != 0 || data['data'] is! Map) {
        throw const FormatException('喜马拉雅目录数据无效');
      }
      final result = data['data'] as Map;
      final rows = result['list'];
      if (rows is! List) throw const FormatException('喜马拉雅章节结构无效');
      last = (int.tryParse('${result['maxPageId']}') ?? 1).clamp(1, 1000);
      for (final row in rows.take(30)) {
        if (row is! Map ||
            row['isPaid'] == true ||
            (int.tryParse('${row['paidType']}') ?? 0) != 0 ||
            row['isVideo'] == true) {
          continue;
        }
        final trackId = '${row['trackId']}';
        final title = bookLabel(row['title']);
        if (!RegExp(r'^\d{1,15}$').hasMatch(trackId) || title.isEmpty) continue;
        chapters.add(
          BookChapter(
            title,
            Uri.https(source.endpoint.host, '/mobile/track/$trackId'),
          ),
        );
      }
    }
    if (last > 134) throw const FormatException('喜马拉雅目录超过 4020 章，未完整获取');
    return chapters;
  }

  Future<Uri> audio(
    BookSource source,
    BookChapter chapter,
    CancellationToken token,
  ) async {
    if (chapter.uri.host != source.endpoint.host ||
        !RegExp(r'^/mobile/track/\d{1,15}$').hasMatch(chapter.uri.path)) {
      throw const FormatException('喜马拉雅章节地址无效');
    }
    final data = await _get(chapter.uri, source.endpoint.host, token);
    if (data['ret'] != 0 ||
        data['isPaid'] == true ||
        (int.tryParse('${data['paidType']}') ?? 0) != 0) {
      throw const FormatException('该章节不提供免费音频');
    }
    final address = data['playUrl64'] ?? data['playUrl32'];
    if (address is! String || address.isEmpty) {
      throw const FormatException('喜马拉雅未返回免费音频地址');
    }
    final original = Uri.parse(address);
    if (original.host != 'aod.cos.tx.xmcdn.com' ||
        !{'http', 'https'}.contains(original.scheme)) {
      throw const FormatException('喜马拉雅音频域名无效');
    }
    return source.requestTarget(
      original.replace(scheme: 'https', port: 443),
      media: true,
    );
  }
}
