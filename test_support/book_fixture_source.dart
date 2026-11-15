import 'package:zero_player/features/books/domain/book.dart';

/// A real, disabled-by-default source for tests that read saved online works.
BookSource bookFixtureSource(String host, {BookKind kind = BookKind.text}) =>
    BookSource.fromJson({
      'name': '测试来源',
      'url': 'https://$host/',
      'kind': kind.name,
      'format': 'html',
      'search': '/search/{key}',
      'rules': {
        'list': '.book',
        'title': '.title@text',
        'book': 'a@href',
        'chapters': '.chapter',
        'chapterTitle': '@text',
        'chapterUrl': '@href',
        'content': '.content',
      },
    });
