import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/features/publications/data/publication_archive_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/domain/publication.dart';

import '../../test_support/publication_catalogue_fixture.dart';

const _item = 'alicesadventures00928gut';

void main() {
  test(
    'archive search preserves title phrases and escapes query operators',
    () {
      final query = archiveGutenbergSearch('Alice’s Adventures in Wonderland');
      expect(query, contains('collection:gutenberg'));
      expect(query, contains('title:"Alice\'s Adventures in Wonderland"'));
      final unsafe = archiveGutenbergSearch('") OR collection:inlibrary *');
      expect(unsafe, isNot(contains('collection:inlibrary')));
      expect(unsafe, isNot(contains('*')));
      expect(
        archiveGutenbergSearch('9781491939369'),
        contains('isbn:"9781491939369"'),
      );
    },
  );

  test(
    'keyword search lists texts across the archive while download stays verified',
    () async {
      await withPublicationCatalogue(
        (fixture) async {
          final transport = MediaHttpClient();
          try {
            final catalog = ArchiveGutenbergCatalogue(
              PublicationHttp(transport, authorize: (_) {}),
            );
            final editions = await catalog.search(
              'Physics',
              CancellationToken(),
              maxPages: 1,
              allowed: (_) => true,
            );
            expect(editions.single.title, 'Physics Library');
            expect(editions.single.candidates, isEmpty);
            final q = fixture.requests.single.queryParameters['q'];
            expect(q, contains('mediatype:texts'));
            expect(q, isNot(contains('collection:')));
          } finally {
            transport.close();
          }
        },
        host: 'archive.org',
        respond: (request) async {
          expect(request.uri.path, '/advancedsearch.php');
          request.response.write(
            jsonEncode({
              'response': {
                'docs': [
                  {'identifier': 'physics-record', 'title': 'Physics Library'},
                ],
              },
            }),
          );
          await request.response.close();
        },
      );
    },
  );

  test('only the public original Gutenberg EPUB is offered', () {
    final edition = archiveGutenbergEdition(_item, _metadata());
    expect(edition?.title, startsWith('Alice'));
    expect(
      edition?.candidates.single.link.toString(),
      'https://archive.org/download/alicesadventures00928gut/pg928.epub',
    );
    expect(edition?.candidates.single.bytes, 75834);
    for (final overrides in [
      {'access-restricted-item': 'true'},
      {
        'collection': ['gutenberg', 'inlibrary'],
      },
      {'uploader': 'unverified@example.org'},
      {'rights': 'No recorded rights'},
      {'is_dark': '1'},
    ]) {
      expect(archiveGutenbergEdition(_item, _metadata(overrides)), isNull);
    }
  });

  test('archive storage redirects are bound to the same item and file', () {
    for (final url in [
      'https://archive.org/download/$_item/pg928.epub',
      'https://dn760001.eu.archive.org/0/items/$_item/pg928.epub',
      'https://ia903104.us.archive.org/23/items/$_item/pg928.epub',
    ]) {
      expect(
        () =>
            restrictArchivePublicationFile(Uri.parse(url), _item, 'pg928.epub'),
        returnsNormally,
      );
    }
    for (final url in [
      'https://ia903104.us.archive.org/23/items/wrong/pg928.epub',
      'https://ia903104.us.archive.org/23/items/$_item/wrong.epub',
      'https://foo.archive.org/23/items/$_item/pg928.epub',
      'https://archive.org/download/$_item/pg928.epub?token=x',
      'http://archive.org/download/$_item/pg928.epub',
    ]) {
      expect(
        () =>
            restrictArchivePublicationFile(Uri.parse(url), _item, 'pg928.epub'),
        throwsA(isA<PublicationFailure>()),
      );
    }
  });
}

Map<String, Object?> _metadata([Map<String, Object?> overrides = const {}]) => {
  'metadata': {
    'identifier': _item,
    'mediatype': 'texts',
    'collection': 'gutenberg',
    'title': "Alice's Adventures in Wonderland",
    'contributor': 'Project Gutenberg',
    'uploader': 'ximm@archive.org',
    'rights': 'Public domain in the USA.',
    ...overrides,
  },
  'files': [
    {
      'name': 'pg928.epub',
      'source': 'original',
      'format': 'EPUB',
      'size': '75834',
    },
    {
      'name': 'pg929.epub',
      'source': 'original',
      'format': 'EPUB',
      'size': '3000',
      'private': 'true',
    },
    {
      'name': 'pg930.epub',
      'source': 'derivative',
      'format': 'EPUB',
      'size': '3000',
    },
    {
      'name': '../pg931.epub',
      'source': 'original',
      'format': 'EPUB',
      'size': '3000',
    },
  ],
};
