import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../domain/publication.dart';

const gutenbergIndexAsset = 'assets/catalogs/books/gutenberg-index.json.gz';
const _maxCompressed = 5 << 20;
const _maxText = 16 << 20;

typedef GutenbergBook = ({
  int id,
  String title,
  String author,
  String language,
});

Future<List<GutenbergBook>> decodeGutenbergIndex(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > _maxCompressed) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  return Isolate.run(() => _decode(bytes));
}

Future<List<GutenbergBook>> _decode(Uint8List bytes) async {
  var total = 0;
  final expanded = gzip.decoder.bind(Stream<List<int>>.value(bytes));
  final contents = await utf8.decoder
      .bind(
        expanded.map((chunk) {
          total += chunk.length;
          if (total > _maxText) {
            throw const PublicationFailure(PublicationProblem.invalid);
          }
          return chunk;
        }),
      )
      .join();
  final data = jsonDecode(contents);
  if (data case {
    'version': 1,
    'books': final List<Object?> books,
  } when books.isNotEmpty && books.length <= 120000) {
    return books.map(_book).toList(growable: false);
  }
  throw const PublicationFailure(PublicationProblem.invalid);
}

GutenbergBook _book(Object? row) {
  if (row case [
    final int id,
    final String title,
    final String author,
    final String language,
  ] when id > 0 && id <= 9999999 && title.isNotEmpty) {
    return (
      id: id,
      title: publicationLabel(title),
      author: publicationLabel(author),
      language: publicationLabel(language),
    );
  }
  throw const PublicationFailure(PublicationProblem.invalid);
}
