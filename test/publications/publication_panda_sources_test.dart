import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/features/publications/data/publication_aozora_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/data/publication_panda_directory.dart';
import 'package:zero_player/features/publications/data/publication_penn_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_planet_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_sources.dart';
import 'package:zero_player/features/publications/domain/publication.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the reviewed directory retains all groups and links native channels',
    () async {
      final directory = await loadPublicationPandaDirectory();
      final entries = directory.groups
          .expand((group) => group.entries)
          .toList();
      final native = entries.where(
        (entry) => entry.status == PublicationPandaStatus.native,
      );
      expect(directory.groups, hasLength(16));
      expect(entries, hasLength(389));
      final enabled = builtinPublicationSources
          .where((item) => item.enabledByDefault)
          .map((item) => item.id);
      expect(
        native.map((entry) => entry.sourceId).toSet(),
        everyElement(isIn(enabled)),
      );
      expect(
        native.map((entry) => entry.sourceId).toSet(),
        containsAll([
          aozoraPublicationSource,
          pennPublicationSource,
          planetPublicationSource,
        ]),
      );
      expect(entries.where((entry) => entry.website != null), isNotEmpty);
      expect(
        entries
            .where((entry) => entry.website != null)
            .every(
              (entry) =>
                  entry.website!.scheme == 'https' &&
                  entry.website!.host == entry.host,
            ),
        isTrue,
      );
    },
  );

  test('directory rows cannot turn alternate or private hosts into links', () {
    final directory = parsePublicationPandaDirectory(
      jsonEncode({
        'version': 1,
        'reviewed': '2026-11-23',
        'groups': [
          {
            'id': 'books',
            'name': '图书',
            'entries': [
              for (final url in [
                'https://other.example/',
                'http://books.example/',
                'https://127.0.0.1/',
              ])
                {
                  'name': 'Book host',
                  'original': 'https://books.example/',
                  'status': 'website',
                  'website': url,
                },
            ],
          },
        ],
      }),
    );
    expect(
      directory.groups.single.entries.map((entry) => entry.status),
      everyElement(PublicationPandaStatus.invalid),
    );
    expect(
      directory.groups.single.entries.map((entry) => entry.website),
      everyElement(isNull),
    );
  });

  _aozoraSearch();

  test('Penn reads author credits and keeps the stable library URL', () {
    final row = parsePennCatalogue('''
        <ul><li><a href="/webbin/book//lookupid?key=olbp42"><img class="info"></a>
       Carroll, Lewis, 1832-1898: <a href="https://outside.example/">
       <cite>Alice's Adventures in Wonderland</cite></a>, illust. by John Tenniel
      </li></ul>
    ''').single;
    expect(row.title, "Alice's Adventures in Wonderland");
    expect(row.author, 'Carroll, Lewis, 1832-1898');
    expect(
      row.page.toString(),
      'https://onlinebooks.library.upenn.edu/webbin/book/lookupid?key=olbp42',
    );
    expect(row.candidates, isEmpty);
  });

  _planetFiles();
}

void _aozoraSearch() {
  test('Aozora searches real offline bibliographic metadata', () async {
    final network = MediaHttpClient();
    addTearDown(network.close);
    final source = AozoraCatalogue(PublicationHttp(network, authorize: (_) {}));
    final books = await source.search(
      '吾輩は猫である',
      CancellationToken(),
      maxPages: 1,
      allowed: (_) => true,
      filter: PublicationFieldSearch(PublicationSearchField.title, '吾輩は猫である'),
    );
    expect(books.any((book) => book.author == '夏目漱石'), isTrue);
    final works = await source.search(
      '夏目 漱石',
      CancellationToken(),
      maxPages: 1,
      allowed: (_) => true,
      filter: PublicationFieldSearch(PublicationSearchField.author, '夏目 漱石'),
    );
    expect(works, isNotEmpty);
    expect(works.map((book) => book.author), everyElement(contains('夏目漱石')));
  });
}

void _planetFiles() {
  test(
    'Planet captures only files listed for the current book on its origin',
    () {
      final book = parsePlanetCatalogue({
        'id': 12072,
        'link': 'https://www.planetebook.com/authors/',
        'content': {
          'rendered': '''
        <h6 class="peauthor">Carroll, Lewis</h6>
        <p class="pelistlinks"><a href="/alice/">Alice</a>
        <a href="https://elsewhere.example/">Unrelated</a></p>
      ''',
        },
      }).single;
      expect(book.author, 'Carroll, Lewis');
      final links = parsePlanetDownloads({
        'link': book.page.toString(),
        'content': {
          'rendered': '''
        <a class="buttonpe" href="/free-ebooks/alice.epub">Download</a>
        <a class="buttonpe" href="/free-ebooks/alice.mobi">Download</a>
        <a class="buttonpe" href="/free-ebooks/unrelated.pdf">Download</a>
        <a class="buttonpe" href="https://elsewhere.example/free-ebooks/alice.pdf">Off-site</a>
      ''',
        },
      }, book.page!);
      expect(links.map((link) => link.format), [
        PublicationFormat.epub,
        PublicationFormat.mobi,
      ]);
    },
  );
}
