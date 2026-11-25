import '../../../core/network/cancellation_token.dart';
import '../../../core/platform/protected_book_export.dart';
import '../../supervision/domain/supervision_rules.dart';
import '../domain/book.dart';
import 'book_catalog_rebuild.dart';
import 'book_comic_export.dart';
import 'books_repository.dart';

final class BookOfflineExport {
  const BookOfflineExport(this.books, {this.output});

  final BooksRepository books;
  final ProtectedBookExport? output;

  Future<int> save(
    Book book,
    List<BookChapter> chapters,
    CancellationToken token, {
    required bool Function() visible,
  }) async {
    if (book.kind == BookKind.audio ||
        (book.sourceId == 'local' &&
            await books.localDocumentFormat(book) != 'txt')) {
      throw const FormatException('此格式没有可导出的离线章节');
    }
    if (book.sourceId != 'local') await books.ensureSourceRiskLoaded();
    await books.chapterPolicy.load();
    final vault = books.store.vault;
    final private = await books.store.isPrivateBook(book.id);
    final session = private ? vault.captureSession() : null;
    final lease = books.downloadGuard.lease();
    void validateState() {
      token.check();
      if (!visible() ||
          !books.bookAllowed(book) ||
          (book.sourceId != 'local' && !books.sourceRisksReady) ||
          private != vault.isPrivate(book.id) ||
          books.downloadGuard.lease() != lease) {
        throw const ContentBlocked();
      }
      if (session != null) vault.checkSession(session);
    }

    final name = book.title.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
    validateState();
    return switch (book.kind) {
      BookKind.text => _saveText(book, chapters, name, token, validateState),
      BookKind.comic => _saveImages(book, chapters, name, token, validateState),
      BookKind.audio => throw const FormatException('此格式没有可导出的离线章节'),
    };
  }

  Future<int> _saveText(
    Book book,
    List<BookChapter> chapters,
    String name,
    CancellationToken token,
    void Function() validateState,
  ) async {
    final buffer = StringBuffer('${book.title}\n${book.author}\n\n');
    final included = <void Function()>[];
    final downloaded = await books.store.savedText(book);
    for (final chapter in chapters) {
      validateState();
      if (isRebuiltBookChapter(chapter)) {
        final body = await books.readText(book, chapter, token);
        final newline = body.indexOf('\n');
        final first = newline < 0 ? body : body.substring(0, newline);
        if (first.trim() != chapter.title) buffer.write('${chapter.title}\n\n');
        buffer.write('$body\n\n');
        included.add(() => books.requireBook(book, chapter));
        continue;
      }
      if (!downloaded.contains(chapter.id)) continue;
      final saved = await books.offlineText(book, chapter, token);
      final original = saved.body;
      if (original == null) continue;
      final body = books.chapterPolicy.prepare(book, chapter, original);
      buffer.write('${chapter.title}\n\n$body\n\n');
      included.add(() {
        books.requireBook(book, chapter);
        books.requireDownloadEvidence(saved.evidence);
        books.chapterPolicy.prepare(book, chapter, original);
      });
    }
    if (included.isEmpty) throw const FormatException('没有可导出的离线章节');
    final validation = BookExportValidation(
      cancellation: token,
      validateState: validateState,
      validateContent: () {
        for (final check in included) {
          check();
        }
      },
    );
    await (output ?? ProtectedBookExport()).saveText(
      '$name.txt',
      buffer.toString(),
      cancellation: token,
      validate: validation.check,
    );
    return included.length;
  }

  Future<int> _saveImages(
    Book book,
    List<BookChapter> chapters,
    String name,
    CancellationToken token,
    void Function() validateState,
  ) async {
    final files = <ComicExportImage>[];
    final contents = <String>['${book.title} · ${book.author}'];
    final included = <BookChapter>[];
    final downloaded = await books.store.savedImages(book);
    for (final chapter in chapters) {
      validateState();
      if (!downloaded.contains(chapter.id)) continue;
      books.requireBook(book, chapter);
      final images = await books.offlineComicForExport(book, chapter, token);
      validateState();
      included.add(chapter);
      final folder = included.length.toString().padLeft(4, '0');
      contents.add('$folder  ${chapter.title}');
      for (final (index, image) in images.entries.indexed) {
        token.check();
        final extension = image.key.pathSegments.lastOrNull
            ?.toLowerCase()
            .split('.')
            .lastOrNull;
        final suffix =
            const {'png', 'jpg', 'jpeg', 'webp', 'gif'}.contains(extension)
            ? extension
            : 'img';
        files.add((
          path: '$folder/${(index + 1).toString().padLeft(4, '0')}.$suffix',
          bytes: image.value,
        ));
      }
    }
    if (included.isEmpty) throw const FormatException('没有可导出的离线漫画');
    final validation = BookExportValidation(
      cancellation: token,
      validateState: validateState,
      validateContent: () {
        for (final chapter in included) {
          books.requireBook(book, chapter);
        }
      },
    );
    final bytes = await encodeComicArchive(files, contents.join('\n'));
    validation.check();
    await (output ?? ProtectedBookExport()).saveBytes(
      '$name.zip',
      bytes,
      'application/zip',
      cancellation: token,
      validate: validation.check,
    );
    return included.length;
  }
}
