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

  static Future<BookEditionsFixture> create({
    int targetChapterCount = 3,
    int targetCatalogPages = 1,
    bool stallSlowCatalog = false,
    bool serveTargetChapters = false,
    int? denyTargetFrom,
    int denyTargetStatus = 403,
    Map<int, List<int>> targetTransientFailures = const {},
    int fastChapterCount = 5,
  }) async {
    final f = BookEditionsFixture();
    f.http.targetChapterCount = targetChapterCount;
    f.http.targetCatalogPages = targetCatalogPages;
    f.http.stallSlowCatalog = stallSlowCatalog;
    f.http.serveTargetChapters = serveTargetChapters;
    f.http.denyTargetFrom = denyTargetFrom;
    f.http.denyTargetStatus = denyTargetStatus;
    f.http.targetTransientFailures.addAll(
      targetTransientFailures.map((key, value) => MapEntry(key, [...value])),
    );
    f.http.fastChapterCount = fastChapterCount;
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
            if (host == 'target' && targetCatalogPages > 1) ...{
              'toc': '.toc@href',
              'tocPageLinks': 'select option[value]',
            },
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
  int get targetChapterRequests => http.targetChapterRequests;
  Map<int, int> get targetAttempts => Map.unmodifiable(http.targetAttempts);
  set targetChapterCount(int count) => http.targetChapterCount = count;
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
  bool stallSlowCatalog = false;
  bool serveTargetChapters = false;
  int? denyTargetFrom;
  int denyTargetStatus = 403;
  int fastChapterCount = 5;
  int targetChapterRequests = 0;
  final targetAttempts = <int, int>{};
  final targetTransientFailures = <int, List<int>>{};
  int targetChapterCount = 3;
  int targetCatalogPages = 1;
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
    if (uri.host == 'slow.example' &&
        (!client.stallSlowCatalog || uri.path == '/book')) {
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
    if (uri.host == 'target.example' && client.targetCatalogPages > 1) {
      if (uri.path == '/book') {
        return _Response('<a class="toc" href="/toc/1">目录</a>', 200);
      }
      if (uri.path.startsWith('/toc/')) return _catalogPage();
    }
    if (uri.path == '/book') {
      final count = uri.host == 'target.example'
          ? client.targetChapterCount
          : uri.host == 'fast.example'
          ? client.fastChapterCount
          : 7;
      return _Response(
        '<h1 class="title">测试作品</h1><span class="author">作者</span>'
        '${List.generate(count, (i) => '<a class="chapter" href="/chapter/$i">第${i + 1}章 标题$i</a>').join()}',
        200,
      );
    }
    if (uri.host == 'target.example' && uri.path.startsWith('/chapter/')) {
      client.targetChapterRequests++;
      final deniedAt = client.denyTargetFrom;
      final index = int.tryParse(uri.pathSegments.last);
      if (index != null) {
        client.targetAttempts.update(
          index,
          (value) => value + 1,
          ifAbsent: () => 1,
        );
        final failures = client.targetTransientFailures[index];
        if (failures != null && failures.isNotEmpty) {
          final status = failures.removeAt(0);
          final response = _Response('', status);
          if (status == 429) response.headers.set('retry-after', '0');
          return response;
        }
      }
      if (deniedAt != null && index != null && index >= deniedAt) {
        final response = _Response('', client.denyTargetStatus);
        if (client.denyTargetStatus == 429) {
          response.headers.set('retry-after', '12');
        }
        return response;
      }
    }
    if ((uri.host == 'fast.example' ||
            client.serveTargetChapters &&
                (uri.host == 'target.example' || uri.host == 'slow.example')) &&
        uri.path.startsWith('/chapter/')) {
      return _Response('<div class="content">替代渠道的正文</div>', 200);
    }
    return _Response('', 404);
  }

  _Response _catalogPage() {
    final page = int.parse(uri.pathSegments.last);
    final options = List.generate(
      client.targetCatalogPages,
      (i) => '<option value="/toc/${i + 1}">${i + 1}</option>',
    ).join();
    final first = (page - 1) * client.targetChapterCount + 1;
    final chapters = List.generate(client.targetChapterCount, (i) {
      final index = first + i;
      return '<a class="chapter" href="/chapter/$index">第$index章</a>';
    }).join();
    return _Response(
      '<select>$options</select><select>$options</select>$chapters',
      200,
    );
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
