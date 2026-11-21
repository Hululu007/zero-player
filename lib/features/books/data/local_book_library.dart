import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../supervision/application/content_policy.dart';
import '../../supervision/domain/supervision_rules.dart';
import '../domain/book.dart';
import 'book_store.dart';
import 'local_book.dart';
import 'rich_book.dart';

typedef RemoveLinkedDocument =
    Future<bool> Function(Book, Future<void> Function(), bool);
typedef HoldLocalDocument =
    Future<Future<void> Function()?> Function(Book, File);

/// Owns local document parsing, policy checks and staged persistence.
/// Reuses the repository's work authorization without accessing source state.
final class LocalBookLibrary {
  LocalBookLibrary({
    required this.store,
    required this.documents,
    required this.policy,
    required this._bookAllowed,
    this.removeLinkedDocument,
    this.holdDocument,
  });

  final BookStore store;
  final Directory documents;
  final ContentPolicy policy;
  final bool Function(Book) _bookAllowed;
  final RemoveLinkedDocument? removeLinkedDocument;
  final HoldLocalDocument? holdDocument;

  File documentFile(Book book, String extension) =>
      File(p.join(documents.path, '${book.id}.$extension'));

  Future<String> documentFormat(Book book) async {
    if (book.sourceId != 'local') return '';
    if (const {'txt', 'epub', 'pdf'}.contains(book.documentFormat)) {
      return book.documentFormat;
    }
    // Legacy content URIs have no extension. Only inspect our own fixed paths.
    for (final extension in ['epub', 'pdf']) {
      if (await documentFile(book, extension).exists()) return extension;
    }
    return 'txt';
  }

  void _requireImportAllowed() {
    if (policy.supervision.enabled || policy.supervision.corrupted) {
      throw const ContentBlocked();
    }
  }

  Future<Book> importLocal(File file) async {
    final name = p.basename(file.path);
    final extension = p.extension(name).toLowerCase();
    if (!{'.txt', '.epub', '.pdf'}.contains(extension)) {
      throw const FormatException('仅支持 TXT、EPUB 和 PDF');
    }
    _requireImportAllowed();
    final bytes = await readLocalBookBytes(file);
    final parsed = switch (extension) {
      '.epub' => await parseEpubBookOffThread(name, bytes),
      '.pdf' => await parsePdfBook(name, bytes),
      _ => await parseTextBookOffThread(name, bytes),
    };
    if (parsed.sections.isEmpty || parsed.sections.length > 4000) {
      throw const FormatException('电子书正文为空或章节过多');
    }
    final book = Book(
      'local',
      BookKind.text,
      parsed.title,
      parsed.author,
      Uri(scheme: 'book', path: sha256.convert(bytes).toString()),
      documentFormat: extension.substring(1),
    );
    void authorize() {
      _requireImportAllowed();
      if (!_bookAllowed(book) ||
          parsed.sections.any(
            (section) =>
                !policy.textAllowed(section.title) ||
                !policy.textAllowed(section.text),
          )) {
        throw const ContentBlocked();
      }
    }

    authorize();
    final contents = {
      for (final (index, section) in parsed.sections.indexed)
        BookChapter(section.title, book.uri.replace(fragment: '$index')):
            section.text,
    };
    await _saveLocalImport(
      book,
      contents,
      authorize,
      file: extension == '.txt'
          ? null
          : documentFile(book, extension.substring(1)),
      bytes: bytes,
    );
    return book;
  }

  Future<void> _saveLocalImport(
    Book book,
    Map<BookChapter, String> contents,
    void Function() authorize, {
    required File? file,
    required List<int> bytes,
  }) async {
    Directory? staging;
    try {
      if (file != null) {
        await documents.create(recursive: true);
        staging = await documents.createTemp('.pending-');
        await File(
          p.join(staging.path, 'document'),
        ).writeAsBytes(bytes, flush: true);
      }
      await store.db.atomic(() async {
        authorize();
        await store.saveTexts(book, contents);
        await store.saveBook(
          book,
          chapters: contents.keys.toList(),
          favorite: true,
        );
        if (file != null) {
          await File(p.join(staging!.path, 'document')).rename(file.path);
        }
      }, tables: {'app_meta'});
    } finally {
      if (staging != null) {
        try {
          final pending = File(p.join(staging.path, 'document'));
          if (await pending.exists()) await pending.delete();
          await staging.delete();
        } on FileSystemException {
          // A failed cleanup must not mask the outcome of the import.
        }
      }
    }
  }

  Future<void> removeLocalBook(
    Book book, {
    Future<void> Function()? removeRecord,
    bool clearOffline = true,
  }) async {
    final remove =
        removeRecord ?? () => store.deleteBook(book, clearOffline: true);
    if (await removeLinkedDocument?.call(book, remove, clearOffline) == true) {
      return;
    }
    await store.db.atomic(() async {
      await remove();
      if (!clearOffline) return;
      for (final extension in ['epub', 'pdf']) {
        final file = documentFile(book, extension);
        if (await file.exists()) await file.delete();
      }
    }, tables: {'app_meta'});
  }
}
