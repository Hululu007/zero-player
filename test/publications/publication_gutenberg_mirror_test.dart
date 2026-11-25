import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/publications/data/publication_gutenberg_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_gutenberg_index.dart';
import 'package:zero_player/features/publications/domain/publication.dart';

void main() {
  test('Gutenberg index decodes bounded, versioned text metadata', () async {
    Uint8List encode(Object value) =>
        Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(value))));

    final rows = [
      [928, 'Alice\r\nHTML Edition', 'Carroll, Lewis', 'en'],
    ];
    final books = await decodeGutenbergIndex(
      encode({'version': 1, 'books': rows}),
    );
    expect(books.single.id, 928);
    expect(books.single.title, 'Alice HTML Edition');
    expect(books.single.author, 'Carroll, Lewis');
    expect(books.single.language, 'en');
    await expectLater(
      decodeGutenbergIndex(encode({'version': 2, 'books': rows})),
      throwsA(isA<PublicationFailure>()),
    );
  });

  test(
    'Gutenberg download requires the right edition, format, and US rights',
    () {
      expect(parseGutenbergRecord(_record(), 928)?.title, 'Alice');
      expect(parseGutenbergRecord(_record(), 929), isNull);
      expect(
        parseGutenbergRecord(_record(rights: 'Copyrighted.'), 928),
        isNull,
      );
      expect(
        parseGutenbergRecord(_record(format: '928.epub3.images'), 928),
        isNull,
      );
      expect(
        parseGutenbergRecord(_record(reference: 'ebooks/929'), 928),
        isNull,
      );
    },
  );
}

String _record({
  String rights = 'Public domain in the USA.',
  String format = '928.epub.images',
  String reference = 'ebooks/928',
}) =>
    '''
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns:dcterms="http://purl.org/dc/terms/"
         xmlns:pgterms="http://www.gutenberg.org/2009/pgterms/">
  <pgterms:ebook rdf:about="ebooks/928">
    <dcterms:publisher>Project Gutenberg</dcterms:publisher><dcterms:title>Alice</dcterms:title>
    <dcterms:rights>$rights</dcterms:rights>
    <dcterms:type><rdf:Description><rdf:value>Text</rdf:value></rdf:Description></dcterms:type>
    <dcterms:hasFormat>
      <pgterms:file rdf:about="https://www.gutenberg.org/ebooks/$format">
        <dcterms:isFormatOf rdf:resource="$reference"/>
        <dcterms:format><rdf:Description><rdf:value>application/epub+zip</rdf:value></rdf:Description></dcterms:format>
      </pgterms:file>
    </dcterms:hasFormat>
  </pgterms:ebook>
</rdf:RDF>
''';
