import '../../../core/network/cancellation_token.dart';
import '../../supervision/domain/supervision_rules.dart';
import '../domain/book.dart';
import '../domain/book_chapter_alignment.dart';
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
  final aligned = List<BookChapter>.of(catalog);
  final known = catalog.map((c) => bookIdentity(c.title)).toSet();
  final pending = editions.where((e) => _sameWork(target, e.book)).toList();
  while (pending.isNotEmpty) {
    final batch = _latestBatch(target, aligned, known, pending);
    if (batch.isEmpty) break;
    result.addAll(batch);
    for (final item in batch) {
      aligned.add(item.chapter);
      known.add(bookIdentity(item.chapter.title));
    }
    pending.removeWhere((edition) => edition.book.id == batch.first.origin.id);
  }
  return result;
}

List<BookLatestChapter> _latestBatch(
  Book target,
  List<BookChapter> catalog,
  Set<String> known,
  Iterable<({Book book, List<BookChapter> chapters})> editions,
) {
  List<BookChapter> best = [];
  Book? origin;
  final ids = catalog.map((chapter) => chapter.id).toSet();
  for (final edition in editions) {
    final current = edition.book.id == target.id;
    if (!current && !_sameWork(target, edition.book)) continue;
    final boundary = bookChapterTailBoundary(catalog, edition.chapters);
    if (boundary == null) continue;
    final length = edition.chapters.length - boundary - 1;
    if (length == 0 ||
        length < best.length ||
        (length == best.length && (!current || origin?.id == target.id))) {
      continue;
    }
    final tail = edition.chapters.skip(boundary + 1).toList();
    final tailIds = <String>{};
    if (tail.any((chapter) {
      final title = bookIdentity(chapter.title);
      return title.isEmpty ||
          known.contains(title) ||
          (current && ids.contains(chapter.id)) ||
          !tailIds.add(chapter.id);
    })) {
      continue;
    }
    best = tail;
    origin = edition.book;
  }
  if (origin == null) return [];
  return [
    for (final chapter in best)
      (
        target: origin.id == target.id
            ? chapter
            : _targetChapter(target, origin, chapter),
        origin: origin,
        chapter: chapter,
      ),
  ];
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
      await store.readBookValue(book, _key(book, chapter)),
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
    return _persist(book, catalog, additions, token);
  }

  Future<List<BookChapter>> prepareNext(
    Book book,
    List<BookChapter> catalog,
    Iterable<({Book book, List<BookChapter> chapters})> editions,
    CancellationToken token,
    bool Function(Book) isCurrent,
    Future<void> Function(List<BookChapter>) saveCatalog,
  ) {
    if (catalog.isEmpty) {
      // Only the original edition can provide an initial catalog to align against.
      final base = editions
          .where((edition) => edition.book.id == book.id)
          .firstOrNull;
      return _persist(
        book,
        catalog,
        [
          for (final chapter in base?.chapters ?? const <BookChapter>[])
            (target: chapter, origin: book, chapter: chapter),
        ],
        token,
        isCurrent: isCurrent,
        saveCatalog: saveCatalog,
      );
    }
    final additions = _latestBatch(
      book,
      catalog,
      catalog.map((chapter) => bookIdentity(chapter.title)).toSet(),
      editions,
    );
    return _persist(
      book,
      catalog,
      additions,
      token,
      isCurrent: isCurrent,
      saveCatalog: saveCatalog,
    );
  }

  Future<List<BookChapter>> _persist(
    Book book,
    List<BookChapter> catalog,
    List<BookLatestChapter> additions,
    CancellationToken token, {
    bool Function(Book)? isCurrent,
    Future<void> Function(List<BookChapter>)? saveCatalog,
  }) async {
    if (additions.isEmpty) return catalog;
    if (catalog.length + additions.length > BookCatalogWindow.limit) {
      throw const BookCatalogCapacityExceeded();
    }
    final lease = guard.lease();
    final origins = <String, BookDownloadEvidence>{};
    final proofs = <BookDownloadEvidence>[];
    for (final item in additions) {
      token.check();
      if (isCurrent?.call(item.origin) == false) throw const ContentBlocked();
      final proof = origins[item.origin.id] ??= await guard.capture(
        book,
        item.target,
        item.origin,
        item.chapter,
      );
      if (item.origin.id == book.id) continue;
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
    final next = [...catalog, ...additions.map((item) => item.target)];
    void authorize() {
      token.check();
      if (guard.lease() != lease ||
          origins.values.any(
            (proof) => isCurrent?.call(proof.origin) == false,
          )) {
        throw const ContentBlocked();
      }
    }

    await store.db.atomic(() async {
      authorize();
      for (final proof in origins.values) {
        await guard.validate(proof, expected: lease);
      }
      for (final proof in proofs) {
        token.check();
        await store.writeBookValue(
          book,
          _key(book, proof.targetChapter),
          proof.toJson(),
        );
      }
      if (saveCatalog != null) await saveCatalog(next);
      store.db.beforeCommit(authorize);
    }, tables: {'app_meta'});
    return next;
  }
}
