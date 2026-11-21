import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../../../core/network/cancellation_token.dart';
import '../../books/data/local_book.dart';
import '../../books/data/rich_book.dart';
import '../../books/domain/book.dart';
import '../domain/publication.dart';

typedef DocumentAdmission = ({
  String title,
  String author,
  List<String> chapters,
  bool hasText,
  bool password,
});

Future<DocumentAdmission> admitPublication(
  File file,
  PublicationFormat format,
  String filename,
  CancellationToken token, {
  required void Function(String text) authorize,
  String? password,
  bool scan = true,
}) async {
  final size = await file.length();
  if (size <= 0 || size > format.maxBytes) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  if (format == PublicationFormat.epub) {
    final book = await parseEpubBookOffThread(
      filename,
      await readLocalBookBytes(file),
    );
    token.check();
    authorize('${book.title} ${book.author}');
    for (final section in book.sections) {
      token.check();
      authorize(section.title);
      authorize(section.text);
    }
    return (
      title: book.title,
      author: book.author,
      chapters: book.sections.map((section) => section.title).toList(),
      hasText: true,
      password: false,
    );
  }
  if (format != PublicationFormat.pdf) {
    throw const PublicationFailure(PublicationProblem.unsupported);
  }
  return _scanPdf(file, filename, password, token, authorize, scan);
}

Future<DocumentAdmission> _scanPdf(
  File file,
  String name,
  String? password,
  CancellationToken token,
  void Function(String) authorize,
  bool scan,
) async {
  await pdfrxFlutterInitialize();
  token.check();
  var offeredPassword = false;
  PdfDocument? document;
  try {
    document = await PdfDocument.openFile(
      file.path,
      passwordProvider: password == null
          ? null
          : () {
              token.check();
              if (offeredPassword) return null;
              offeredPassword = true;
              return password;
            },
    );
    token.check();
    if (document.pages.isEmpty || document.pages.length > 4000) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    final title = bookLabel(p.basenameWithoutExtension(name));
    authorize(title);
    var hasText = false;
    if (scan) {
      for (final page in document.pages) {
        token.check();
        final body = (await page.loadText())?.fullText ?? '';
        token.check();
        // Preserve the existing page-level filtering boundary and avoid an
        // archive-sized string or a persisted plaintext index at admission.
        if (body.length > 2 << 20) {
          throw const PublicationFailure(PublicationProblem.invalid);
        }
        authorize('第 ${page.pageNumber} 页');
        authorize(body);
        if (!hasText && body.trim().isNotEmpty) hasText = true;
      }
    }
    return (
      title: title,
      author: '',
      chapters: List.generate(document.pages.length, (i) => '第 ${i + 1} 页'),
      hasText: hasText,
      password: offeredPassword,
    );
  } on PdfPasswordException {
    throw const PublicationFailure(PublicationProblem.pdfPassword);
  } on PdfException {
    throw const PublicationFailure(PublicationProblem.invalid);
  } finally {
    await document?.dispose();
  }
}

Book publicationReaderBook(
  String digest,
  PublicationFormat format,
  String title,
  String author,
) => Book(
  'local',
  BookKind.text,
  title,
  author,
  Uri(scheme: 'book', path: digest),
  documentFormat: format.name,
);

List<BookChapter> publicationReaderChapters(Book book, List<String> headings) =>
    [
      for (final (index, title) in headings.indexed)
        BookChapter(title, book.uri.replace(fragment: '$index')),
    ];
