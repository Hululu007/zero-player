import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/domain/book.dart';

/// Real repository/parser with isolated HTML origins. No socket can be opened.
final class BookEditionsFixture {
  late Directory root;
  late AppServices services;
  final http = _Client();
  late Book book;
  final sources = <String, BookSource>{};

  static Future<BookEditionsFixture> create() async {
    final f = BookEditionsFixture();
    f.root = await Directory.systemTemp.createTemp('book-editions-');
    await HttpOverrides.runZoned(() async {
      f.services = AppServices.scoped(f.root, AppDatabase.memory());
      await f.services.settings.load();
      await f.services.supervision.load();
      for (final entry in await f.services.books.sources(BookKind.text)) {
        if (entry.enabled) {
          await f.services.books.saveSource(entry.source, {'enabled': false});
        }
      }
      for (final host in ['target', 'fast', 'slow', 'failed']) {
        f.sources[host] = BookSource.fromJson({
          'name': '$host 渠道',
          'url': 'https://$host.example/',
          'kind': 'text',
          'format': 'html',
          'search': '/search/{key}',
          'rules': {
            'list': '.book',
            'title': '.title@text',
            'author': '.author@text',
            'book': 'a@href',
            'infoTitle': '.title@text',
            'infoAuthor': '.author@text',
            'chapters': '.chapter',
            'chapterTitle': '@text',
            'chapterUrl': '@href',
            'content': '.content',
          },
        });
      }
      await f.services.books.importSources(f.sources.values.toList());
      for (final source in f.sources.values) {
        await f.services.books.saveSource(source, {'enabled': true});
      }
      f.book = Book(
        f.sources['target']!.id,
        BookKind.text,
        '测试作品',
        '作者',
        Uri.https('target.example', '/book'),
      );
    }, createHttpClient: (_) => f.http);
    return f;
  }

  bool get slowWaiting => http.slowWaiting;
  bool get slowReleased => http.gate.isCompleted;
  void releaseSlow() {
    if (!http.gate.isCompleted) http.gate.complete();
  }

  Future<void>? _closing;
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    releaseSlow();
    await services.books.close();
    await services.close();
    await root.delete(recursive: true);
  }
}

final class _Client implements HttpClient {
  final gate = Completer<void>();
  bool slowWaiting = false;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) async {
    if (method != 'GET' ||
        !{
          'target.example',
          'fast.example',
          'slow.example',
          'failed.example',
        }.contains(uri.host)) {
      throw const SocketException('Non-fixture requests are forbidden');
    }
    return _Request(this, uri);
  }

  @override
  void close({bool force = false}) {
    if (!gate.isCompleted) gate.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class _Request implements HttpClientRequest {
  _Request(this.client, this.uri);
  final _Client client;
  final _aborted = Completer<void>();
  @override
  final Uri uri;
  @override
  final HttpHeaders headers = _Headers();
  @override
  Future<HttpClientResponse> close() async {
    if (uri.host == 'slow.example') {
      client.slowWaiting = true;
      await Future.any([client.gate.future, _aborted.future]);
      if (_aborted.isCompleted) throw const RequestCancelled();
    }
    if (uri.host == 'failed.example') return _Response('', 404);
    if (uri.path.startsWith('/search/')) {
      return _Response(
        '<div class="book"><a href="/book" class="title">测试作品</a>'
        '<span class="author">作者</span></div>',
        200,
      );
    }
    if (uri.path == '/book') {
      final count = uri.host == 'target.example'
          ? 3
          : uri.host == 'fast.example'
          ? 5
          : 7;
      return _Response(
        '<h1 class="title">测试作品</h1><span class="author">作者</span>'
        '${List.generate(count, (i) => '<a class="chapter" href="/chapter/$i">第${i + 1}章 标题$i</a>').join()}',
        200,
      );
    }
    return _Response('', 404);
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    if (!_aborted.isCompleted) _aborted.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.html, this.statusCode);
  final String html;
  @override
  final int statusCode;
  @override
  final HttpHeaders headers = _Headers()
    ..set('content-type', 'text/html; charset=utf-8');
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(utf8.encode(html)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class _Headers implements HttpHeaders {
  final values = <String, List<String>>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = [value.toString()];
  @override
  String? value(String name) => values[name.toLowerCase()]?.firstOrNull;
  @override
  void forEach(void Function(String, List<String>) action) =>
      values.forEach(action);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
