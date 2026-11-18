import '../../../core/network/cancellation_token.dart';
import '../../supervision/domain/supervision_rules.dart';
import '../domain/book.dart';
import 'book_catalog_window.dart';
import 'book_download_evidence.dart';
import 'book_download_guard.dart';
import 'book_store.dart';

typedef BookLatestChapter = ({
  BookChapter target,
  Book origin,
  BookChapter chapter,
});

const _fragmentPrefix = 'zero-player-latest-';

bool _sameWork(Book target, Book other) =>
    target.kind == BookKind.text &&
    other.kind == target.kind &&
    other.sourceId != target.sourceId &&
    bookIdentity(target.author).isNotEmpty &&
    bookIdentity(target.title) == bookIdentity(other.title) &&
    bookIdentity(target.author) == bookIdentity(other.author);

BookChapter _targetChapter(Book target, Book origin, BookChapter chapter) =>
    BookChapter(
      chapter.title,
      target.uri.replace(
        fragment: '$_fragmentPrefix${origin.id}-${chapter.id}',
      ),
    );

/// Extend only a uniquely aligned tail. Chapter counts alone cannot establish
/// continuity: editions may split, reorder, duplicate or omit chapters.
List<BookLatestChapter> planBookLatestChapters(
  Book target,
  List<BookChapter> catalog,
  Iterable<({Book book, List<BookChapter> chapters})> editions,
) {
  if (target.kind != BookKind.text || catalog.isEmpty) return [];
  final result = <BookLatestChapter>[];
  final titles = catalog.map((c) => bookIdentity(c.title)).toList();
  final known = titles.toSet();
  final pending = editions.where((e) => _sameWork(target, e.book)).toList();
  while (pending.isNotEmpty) {
    List<BookChapter> best = [];
    Book? origin;
    for (final edition in pending) {
      final keys = edition.chapters.map((c) => bookIdentity(c.title)).toList();
      final boundary = keys.indexOf(titles.last);
      if (boundary < 0 || keys.lastIndexOf(titles.last) != boundary) continue;
      // Require both trailing chapters when available, in the same order.
      if (titles.length > 1 &&
          (boundary == 0 || keys[boundary - 1] != titles[titles.length - 2])) {
        continue;
      }
      final tail = edition.chapters.skip(boundary + 1).toList();
      final tailKeys = keys.skip(boundary + 1).toList();
      if (tailKeys.any((key) => key.isEmpty || known.contains(key)) ||
          tailKeys.toSet().length != tailKeys.length) {
        continue;
      }
      if (tail.length > best.length) {
        best = tail;
        origin = edition.book;
      }
    }
    if (origin == null) break;
    for (final chapter in best) {
      result.add((
        target: _targetChapter(target, origin, chapter),
        origin: origin,
        chapter: chapter,
      ));
      final key = bookIdentity(chapter.title);
      titles.add(key);
      known.add(key);
    }
    pending.removeWhere((edition) => edition.book.id == origin!.id);
  }
  return result;
}

/// Durable routing is separate from the chapter URL. Both ends retain the
/// existing revision and policy checks; synthetic URLs are never requested.
final class BookLatestAggregation {
  const BookLatestAggregation(this.store, this.guard);
  final BookStore store;
  final BookDownloadGuard guard;

  static bool isAggregated(BookChapter chapter) =>
      chapter.uri.fragment.startsWith(_fragmentPrefix);

  String _key(Book book, BookChapter chapter) =>
      'books_latest_origin:${book.id}:${chapter.id}';

  Future<BookDownloadEvidence?> origin(Book book, BookChapter chapter) async {
    if (!isAggregated(chapter)) return null;
    final evidence = BookDownloadEvidence.fromJson(
      await store.read(_key(book, chapter)),
    );
    if (!evidence.describes(book, chapter) ||
        !_sameWork(book, evidence.origin) ||
        evidence.originChapter.title != chapter.title ||
        _targetChapter(book, evidence.origin, evidence.originChapter).id !=
            chapter.id) {
      throw const FormatException('聚合章节来源记录无效，请重新聚合下载');
    }
    await guard.validate(evidence);
    return evidence;
  }

  Future<List<BookChapter>> prepare(
    Book book,
    List<BookChapter> catalog,
    Iterable<({Book book, List<BookChapter> chapters})> editions,
    CancellationToken token,
  ) async {
    final additions = planBookLatestChapters(book, catalog, editions);
    if (additions.isEmpty) return catalog;
    if (catalog.length + additions.length > BookCatalogWindow.limit) {
      throw const BookCatalogCapacityExceeded();
    }
    final lease = guard.lease();
    final origins = <String, BookDownloadEvidence>{};
    final proofs = <BookDownloadEvidence>[];
    for (final item in additions) {
      token.check();
      final proof = origins[item.origin.id] ??= await guard.capture(
        book,
        item.target,
        item.origin,
        item.chapter,
      );
      proofs.add(
        BookDownloadEvidence(
          target: book,
          targetChapter: item.target,
          targetFingerprint: proof.targetFingerprint,
          targetEpoch: proof.targetEpoch,
          origin: item.origin,
          originChapter: item.chapter,
          originFingerprint: proof.originFingerprint,
          originEpoch: proof.originEpoch,
        ),
      );
    }
    await store.db.atomic(() async {
      token.check();
      for (final proof in origins.values) {
        await guard.validate(proof, expected: lease);
      }
      for (final proof in proofs) {
        await store.write(_key(book, proof.targetChapter), proof.toJson());
      }
      token.check();
      if (guard.lease() != lease) throw const ContentBlocked();
    }, tables: {'app_meta'});
    token.check();
    return [...catalog, ...additions.map((item) => item.target)];
  }
}
