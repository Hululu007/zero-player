import 'dart:isolate';

import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_http.dart';

typedef PublicationImportedList = ({
  String name,
  Uri source,
  List<PublicationEdition> books,
  bool truncated,
});

final _doulistPath = RegExp(r'^/doulist/([0-9]{1,20})/?$');
final _doubanBook = RegExp(r'^/subject/[0-9]+/?$');
final _weReadPath = RegExp(r'^/misc/booklist/[a-zA-Z0-9_-]{1,100}/?$');

Uri publicationListAddress(String input) {
  for (final match in RegExp(r'https://[^\s<>《》【】「」，。！？]+').allMatches(input)) {
    final uri = Uri.tryParse(match[0]!);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty) {
      continue;
    }
    if (const {
      'www.douban.com',
      'book.douban.com',
      'douban.com',
    }.contains(uri.host)) {
      final list = _doulistPath.firstMatch(uri.path);
      if (list != null) {
        return Uri.https('www.douban.com', '/doulist/${list[1]}/');
      }
    }
    if (uri.host == 'weread.qq.com' && _weReadPath.hasMatch(uri.path)) {
      return Uri.https(uri.host, uri.path.replaceFirst(RegExp(r'/$'), ''));
    }
  }
  throw const FormatException('请输入豆瓣豆列或微信读书的公开书单链接');
}

Future<PublicationImportedList> importPublicationList(
  PublicationHttp http,
  String input,
  CancellationToken token,
) async {
  final source = publicationListAddress(input);
  final douban = source.host == 'www.douban.com';
  final books = <String, PublicationEdition>{};
  var name = '';
  var more = false;
  final maxPages = douban ? 10 : 1;
  for (var page = 0; page < maxPages; page++) {
    final uri = page == 0
        ? source
        : source.replace(queryParameters: {'start': '${25 * page}'});
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
    final parsed = await _decodePage(source, raw);
    token.check();
    if (page == 0) name = parsed.name;
    for (final book in parsed.books) {
      books.putIfAbsent(book.id, () => book);
    }
    more = parsed.more;
    if (!more) break;
  }
  if (name.isEmpty || books.isEmpty) {
    throw const FormatException('公开书单没有可导入的书目');
  }
  return (
    name: name,
    source: source,
    books: books.values.take(250).toList(),
    truncated: more || books.length > 250,
  );
}

typedef PublicationListPage = ({
  String name,
  List<PublicationEdition> books,
  bool more,
});

Future<PublicationListPage> _decodePage(Uri source, String raw) =>
    Isolate.run(() => parsePublicationListPage(source, raw));

PublicationListPage parsePublicationListPage(Uri source, String raw) {
  final document = html.parse(raw);
  final douban = source.host == 'www.douban.com';
  final name = publicationLabel(
    document
        .querySelector(douban ? '#content h1' : '.booklist_header_title')
        ?.text,
    max: 100,
  );
  if (name.isEmpty) {
    final title = document.querySelector('title')?.text ?? '';
    throw PublicationFailure(
      RegExp(r'验证|captcha|异常请求', caseSensitive: false).hasMatch(title)
          ? PublicationProblem.challenge
          : PublicationProblem.invalid,
    );
  }
  final books = <PublicationEdition>[];
  for (final row
      in document
          .querySelectorAll(
            douban
                ? '.doulist-item .doulist-subject'
                : '.booklist_books .booklist_book',
          )
          .take(251)) {
    final link = douban ? row.querySelector('.title a') : null;
    final title = publicationLabel(
      douban ? link?.text : row.querySelector('.booklist_book_title')?.text,
    );
    if (title.isEmpty) continue;
    final Uri? page;
    if (douban) {
      final target = Uri.tryParse(link?.attributes['href'] ?? '');
      if (target == null ||
          target.scheme != 'https' ||
          target.host != 'book.douban.com' ||
          target.port != 443 ||
          target.userInfo.isNotEmpty ||
          !_doubanBook.hasMatch(target.path)) {
        continue;
      }
      page = Uri.https(target.host, target.path);
    } else {
      page = null;
    }
    final author = publicationLabel(
      douban
          ? RegExp(
              r'作者\s*[:：]\s*([^\r\n]+)',
            ).firstMatch(row.querySelector('.abstract')?.text ?? '')?.group(1)
          : row.querySelector('.booklist_book_author')?.text,
    );
    books.add(
      PublicationEdition(
        id: publicationId(page?.toString() ?? '$source\n$title\n$author'),
        title: title,
        author: author,
        page: page,
      ),
    );
  }
  return (
    name: name,
    books: books,
    more: douban && document.querySelector('.paginator .next a') != null,
  );
}
