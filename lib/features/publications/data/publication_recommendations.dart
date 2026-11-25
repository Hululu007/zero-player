import 'dart:isolate';

import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_http.dart';

enum PublicationBoard {
  douban('豆瓣读书 · Top 250', 'book.douban.com', '/top250', 10),
  weReadRising('微信读书 · 飙升榜', 'weread.qq.com', '/web/category/rising', 1),
  weReadAll('微信读书 · 总榜', 'weread.qq.com', '/web/category/all', 1);

  const PublicationBoard(this.label, this.host, this.path, this.pages);
  final String label, host, path;
  final int pages;
  bool get isDouban => this == douban;

  Uri url(int page) => Uri.https(
    host,
    path,
    isDouban && page > 1 ? {'start': '${(page - 1) * 25}'} : null,
  );
}

typedef PublicationFeaturedDetails = ({String isbn, String description});

final class PublicationRecommendations {
  PublicationRecommendations(this.http, this.allowed);
  final PublicationHttp http;
  final bool Function(String) allowed;
  final _cache =
      <(PublicationBoard, int), (DateTime, List<PublicationEdition>)>{};
  final _details = <Uri, PublicationFeaturedDetails>{};

  Future<List<PublicationEdition>> load(
    PublicationBoard board,
    int page,
    CancellationToken token, {
    bool refresh = false,
  }) async {
    token.check();
    RangeError.checkValueInInterval(page, 1, board.pages, 'page');
    final uri = board.url(page);
    http.authorize(uri);
    final key = (board, page);
    final cached = _cache[key];
    if (!refresh &&
        cached != null &&
        DateTime.now().difference(cached.$1) < const Duration(minutes: 15)) {
      return _allowed(cached.$2);
    }
    final raw = await http.text(
      uri,
      token,
      deadline: publicationCatalogueDeadline,
      allowGzip: true,
      scope: (target) {
        if (target != uri) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
    );
    final books = await _decodeBoard(board, raw);
    token.check();
    http.authorize(uri);
    _cache[key] = (DateTime.now(), books);
    return _allowed(books);
  }

  List<PublicationEdition> _allowed(List<PublicationEdition> books) => [
    for (final book in books)
      if (allowed('${book.title} ${book.author}')) book,
  ];

  Future<PublicationFeaturedDetails?> details(
    PublicationEdition book,
    CancellationToken token,
  ) async {
    final page = book.page;
    if (page == null ||
        !_isDoubanBook(page) ||
        !allowed('${book.title} ${book.author}')) {
      return null;
    }
    token.check();
    http.authorize(page);
    if (_details[page] case final cached?) return cached;
    final raw = await http.text(
      page,
      token,
      deadline: publicationCatalogueDeadline,
      allowGzip: true,
      scope: (uri) {
        if (uri != page) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
    );
    final detail = await _decodeFeaturedDetails(raw);
    token.check();
    http.authorize(page);
    if (detail != null) {
      if (_details.length >= 40) _details.remove(_details.keys.first);
      _details[page] = detail;
    }
    return detail;
  }

  void clear() {
    _cache.clear();
    _details.clear();
  }
}

bool _isDoubanBook(Uri uri) =>
    uri.scheme == 'https' &&
    uri.port == 443 &&
    uri.host == 'book.douban.com' &&
    uri.userInfo.isEmpty &&
    !uri.hasQuery &&
    !uri.hasFragment &&
    _doubanBookPath.hasMatch(uri.path);

final _doubanBookPath = RegExp(r'^/subject/[0-9]+/?$');

Future<PublicationFeaturedDetails?> _decodeFeaturedDetails(String raw) =>
    Isolate.run(() => parsePublicationFeaturedDetails(raw));

PublicationFeaturedDetails? parsePublicationFeaturedDetails(String raw) {
  final document = html.parse(raw);
  final info = document.querySelector('#info');
  if (info == null) return null;
  final isbn = normalizedIsbn(
    RegExp(r'ISBN:\s*([0-9Xx-]{10,17})').firstMatch(info.text)?.group(1) ?? '',
  );
  final summary =
      document.querySelector('#link-report .all .intro') ??
      document.querySelector('#link-report .intro');
  final description = publicationLabel(
    summary?.querySelector('p')?.text,
    max: 650,
  );
  return (isbn: isbn, description: description);
}

Future<List<PublicationEdition>> _decodeBoard(
  PublicationBoard board,
  String raw,
) => Isolate.run(() => parsePublicationBoard(board, raw));

List<PublicationEdition> parsePublicationBoard(
  PublicationBoard board,
  String raw,
) {
  final base = board.url(1);
  final document = html.parse(raw);
  final books = <String, PublicationEdition>{};
  final douban = board.isDouban;
  final expectedPath = douban
      ? _doubanBookPath
      : RegExp(r'^/web/reader/[a-zA-Z0-9]+/?$');
  for (final row
      in document
          .querySelectorAll(douban ? 'tr.item' : 'li.wr_bookList_item')
          .take(30)) {
    String field(String selector, {int max = 256}) =>
        publicationLabel(row.querySelector(selector)?.text, max: max);
    final link = row.querySelector(
      douban ? '.pl2 a' : '.wr_bookList_item_link',
    );
    final reference = Uri.tryParse(link?.attributes['href'] ?? '');
    if (reference == null) continue;
    final page = base.resolveUri(reference);
    if (page.scheme != 'https' ||
        page.host != base.host ||
        page.port != 443 ||
        page.userInfo.isNotEmpty ||
        !expectedPath.hasMatch(page.path)) {
      continue;
    }
    final title = douban
        ? publicationLabel(link?.attributes['title'] ?? link?.text)
        : field('.wr_bookList_item_title');
    if (title.isEmpty) continue;
    final bibliographic = douban
        ? field('p.pl').split(' / ')
        : const <String>[];
    final date = bibliographic.indexWhere(
      (value) => RegExp(r'^\d{4}(?:-\d{1,2}){0,2}$').hasMatch(value),
    );
    final score = field(
      douban ? '.rating_nums' : '.wr_bookList_item_reading_percent',
    );
    final canonical = Uri.https(base.host, page.path);
    books[canonical.path] = PublicationEdition(
      id: publicationId('$canonical'),
      title: title,
      author: douban ? bibliographic.first : field('.wr_bookList_item_author'),
      translator: date > 2
          ? bibliographic.sublist(1, date - 1).join(' / ')
          : '',
      publisher: date > 1 ? bibliographic[date - 1] : '',
      edition: date > 1 ? bibliographic[date] : '',
      rating: score.isEmpty ? '' : '${douban ? '豆瓣评分' : '微信读书推荐值'} $score',
      description: field(douban ? '.inq' : '.wr_bookList_item_desc', max: 1200),
      cover: publicationCoverUrl(
        base,
        row
            .querySelector(douban ? 'a.nbg img' : '.wr_bookCover_img')
            ?.attributes['src'],
        (uri) => hostIn(uri, douban ? 'doubanio.com' : 'weread.qq.com'),
      ),
      page: canonical,
    );
  }
  if (books.isEmpty) {
    final title = document.querySelector('title')?.text ?? '';
    throw PublicationFailure(
      RegExp(r'验证|captcha|异常请求', caseSensitive: false).hasMatch(title)
          ? PublicationProblem.challenge
          : PublicationProblem.invalid,
    );
  }
  return books.values.toList();
}
