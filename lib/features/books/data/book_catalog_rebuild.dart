import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import '../../../core/network/cancellation_token.dart';
import '../../supervision/domain/supervision_rules.dart';
import '../domain/book.dart';
import 'book_download_evidence.dart';
import 'book_store.dart';
import 'books_repository.dart';

const defaultChapterRule = r'第[零〇一二三四五六七八九十百千万两0-9０-９]+[章节回卷部篇](?:.*)?';
const _prefix = 'zero-player-rebuilt-';
final _chapterMarker = RegExp(r'^zero-player-rebuilt-[0-9a-f]{64}-[0-9]+$');

String rebuiltCatalogKey(Book book) => 'books_rebuilt_catalog:${book.id}';

bool isRebuiltBookChapter(BookChapter chapter) =>
    _chapterMarker.hasMatch(chapter.uri.fragment);

typedef _Original = ({BookChapter chapter, String digest, int start, int end});

final class BookCatalogRebuild {
  const BookCatalogRebuild(this.books);

  final BooksRepository books;

  Future<List<BookChapter>> catalog(Book book) async {
    final raw = await books.store.readBookValue(book, rebuiltCatalogKey(book));
    return [
      if (raw case {'catalog': final List items})
        for (final item in items.whereType<Map>()) BookChapter.fromJson(item),
    ];
  }

  Future<List<String>> rules(Book book) async {
    final raw = await books.store.readBookValue(book, rebuiltCatalogKey(book));
    return switch (raw) {
      {'rules': final List rules} => rules.whereType<String>().toList(),
      _ => [defaultChapterRule],
    };
  }

  Future<List<BookChapter>> rebuild(
    BookShelfEntry entry,
    List<String> rules,
    CancellationToken token, {
    required bool Function() available,
  }) async {
    final book = entry.book;
    if (book.kind != BookKind.text ||
        (book.sourceId == 'local' &&
            await books.localDocumentFormat(book) != 'txt')) {
      throw const FormatException('章节重建适用于已经完整下载的文字书');
    }
    if (book.sourceId != 'local') await books.ensureSourceRiskLoaded();
    final store = books.store;
    final lease = books.downloadGuard.lease();
    final private = await store.isPrivateBook(book.id);
    final session = private ? store.vault.captureSession() : null;
    void validate() {
      token.check();
      if (!available() ||
          !books.bookAllowed(book) ||
          private != store.vault.isPrivate(book.id) ||
          lease != books.downloadGuard.lease()) {
        throw const ContentBlocked();
      }
      if (session != null) store.vault.checkSession(session);
    }

    validate();
    final saved = await store.savedText(book);
    if (entry.catalogOmitted != 0 ||
        entry.chapters.isEmpty ||
        entry.chapters.any((chapter) => !saved.contains(chapter.id))) {
      throw const FormatException('需完整下载原目录的所有章节后才能重建');
    }
    final (text, originals, evidence) = await _mergeOriginals(
      entry,
      token,
      validate,
    );
    final headings = await _scanHeadings(text, rules, token);
    validate();
    final revision = _digest(
      jsonEncode([
        rules,
        for (final item in originals) [item.chapter.id, item.digest],
      ]),
    );
    final catalog = <BookChapter>[];
    final records = <String, List<Map<String, Object?>>>{};
    var cursor = 0;
    for (final (index, (start, title)) in headings.indexed) {
      validate();
      final end = index + 1 == headings.length
          ? text.length
          : headings[index + 1].$1;
      final chapter = BookChapter(
        title,
        book.uri.replace(fragment: '$_prefix$revision-$index'),
      );
      final body = text.substring(start, end);
      books.requireBook(book, chapter);
      books.chapterPolicy.prepare(book, chapter, body);
      catalog.add(chapter);
      final spans = <Map<String, Object?>>[];
      while (originals[cursor].end <= start) {
        cursor++;
      }
      for (
        var source = cursor;
        source < originals.length && originals[source].start < end;
        source++
      ) {
        final item = originals[source];
        spans.add({
          'chapter': item.chapter.toJson(),
          'digest': item.digest,
          'start': (start - item.start).clamp(0, item.end - item.start),
          'end': (end - item.start).clamp(0, item.end - item.start),
        });
      }
      records[chapter.id] = spans;
    }
    for (final source in evidence) {
      books.requireDownloadEvidence(source);
    }
    await store.replaceRebuiltCatalog(
      book,
      catalog,
      rules,
      records,
      originalIds: entry.chapters.map((chapter) => chapter.id),
      validate: validate,
    );
    return catalog;
  }

  Future<(String, List<_Original>, Set<BookDownloadEvidence>)> _mergeOriginals(
    BookShelfEntry entry,
    CancellationToken token,
    void Function() validate,
  ) async {
    final merged = StringBuffer();
    final originals = <_Original>[];
    final evidence = <BookDownloadEvidence>{};
    for (final chapter in entry.chapters) {
      validate();
      final original = await books.offlineText(entry.book, chapter, token);
      final body = original.body;
      if (body == null || body.trim().isEmpty) {
        throw const FormatException('存在缺失正文，请重新下载后再重建');
      }
      if (original.evidence case final source?) evidence.add(source);
      if (originals.isNotEmpty) merged.write('\n\n');
      final start = merged.length;
      merged.write(body);
      originals.add((
        chapter: chapter,
        digest: _digest(body),
        start: start,
        end: merged.length,
      ));
    }
    return (merged.toString(), originals, evidence);
  }

  Future<String> read(
    Book book,
    BookChapter chapter,
    CancellationToken token,
  ) async {
    final store = books.store;
    final vault = store.vault;
    final private = await store.isPrivateBook(book.id);
    final session = private ? vault.captureSession() : null;
    final lease = books.downloadGuard.lease();
    final raw = await store.readBookValue(
      book,
      'books_rebuilt_chapter:${book.id}:${chapter.id}',
    );
    if (raw is! List || raw.isEmpty) {
      throw const FormatException('重建目录已变化，请回到作品目录重新打开');
    }
    final buffer = StringBuffer();
    final evidence = <BookDownloadEvidence>[];
    for (final span in raw) {
      token.check();
      if (span case {
        'chapter': final Map source,
        'digest': final String digest,
        'start': final int start,
        'end': final int end,
      }) {
        final original = await books.offlineText(
          book,
          BookChapter.fromJson(source),
          token,
        );
        final body = original.body;
        if (body != null &&
            end <= body.length &&
            start >= 0 &&
            start < end &&
            _digest(body) == digest) {
          if (buffer.isNotEmpty) buffer.write('\n\n');
          buffer.write(body.substring(start, end));
          if (original.evidence case final source?) evidence.add(source);
          continue;
        }
      }
      throw const FormatException('原离线正文已变化，请重新重建目录');
    }
    token.check();
    books.requireBook(book, chapter);
    if (private != vault.isPrivate(book.id) ||
        lease != books.downloadGuard.lease()) {
      throw const ContentBlocked();
    }
    if (session != null) vault.checkSession(session);
    for (final source in evidence) {
      books.requireDownloadEvidence(source);
    }
    return books.chapterPolicy.prepare(book, chapter, buffer.toString());
  }
}

String _digest(String body) => sha256.convert(utf8.encode(body)).toString();

typedef _HeadingRequest = (SendPort, String, List<String>);

Future<List<(int, String)>> _scanHeadings(
  String text,
  List<String> patterns,
  CancellationToken token,
) async {
  if (patterns.isEmpty ||
      patterns.length > 12 ||
      patterns.any((pattern) => pattern.isEmpty || pattern.length > 300)) {
    throw const FormatException('请填写 1–12 条分章规则，每条最多 300 字符');
  }
  final results = ReceivePort();
  final cancelled = Completer<void>();
  final unlisten = token.listen(() => cancelled.complete());
  Isolate? worker;
  try {
    worker = await Isolate.spawn(_matchHeadings, (
      results.sendPort,
      text,
      patterns,
    ));
    final matched = await Future.any<Object?>([
      results.first,
      cancelled.future.then((_) => null),
    ]).timeout(const Duration(seconds: 12));
    token.check();
    return switch (matched) {
      final List<(int, String)> headings => headings,
      final String error => throw FormatException(error),
      _ => throw const FormatException('无法识别章节标题'),
    };
  } on TimeoutException {
    throw const FormatException('分章规则匹配超时，请缩短或简化表达式');
  } finally {
    worker?.kill(priority: Isolate.immediate);
    unlisten();
    results.close();
  }
}

void _matchHeadings(_HeadingRequest message) {
  final (output, text, patterns) = message;
  try {
    final rules = [
      for (final pattern in patterns)
        RegExp('^(?:$pattern)\$', caseSensitive: false),
    ];
    final headings = <(int, String)>[];
    var offset = 0;
    while (offset < text.length) {
      final newline = text.indexOf('\n', offset);
      final end = newline < 0 ? text.length : newline;
      if (end - offset <= 250) {
        final line = text.substring(offset, end).trim();
        if (line.isNotEmpty && rules.any((rule) => rule.hasMatch(line))) {
          final title = bookLabel(line);
          if (headings.isEmpty && offset > 0) headings.add((0, '序章'));
          headings.add((offset, title));
          if (headings.length > 25000) {
            output.send('识别出的章节超过 25,000 项，请收紧分章规则');
            return;
          }
        }
      }
      offset = end + 1;
    }
    if (headings.isEmpty) {
      output.send('没有找到符合规则的标题，请修改分章规则');
      return;
    }
    output.send(headings);
  } on FormatException {
    output.send('分章规则包含无效的正则表达式');
  }
}
