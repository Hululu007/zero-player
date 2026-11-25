import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/publications/application/publication_discovery.dart';
import 'package:zero_player/features/publications/data/publication_archive_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_gallica_catalogue.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/data/publication_store.dart';
import 'package:zero_player/features/publications/domain/publication.dart';

import '../../test_support/publication_catalogue_fixture.dart';

void main() {
  test('a large index scan can be cancelled between batches', () async {
    final token = CancellationToken();
    Timer.run(token.cancel);
    await expectLater(
      searchPublicationIndex(
        List.filled(1500, const PublicationEdition(id: 'work', title: '其他')),
        '找不到',
        token,
        limit: 8,
        allowed: (_) => true,
      ),
      throwsA(isA<RequestCancelled>()),
    );
  });

  test('field searches exclude translations, tags and other fields', () {
    const book = PublicationEdition(
      id: 'work',
      title: '紅樓夢',
      author: '曹 雪芹',
      translator: 'John Doe',
      tags: ['ignored word'],
      isbn: '9780141439761',
    );
    final title = PublicationFieldSearch(
      PublicationSearchField.title,
      '红楼梦',
      hanFold: {0x7d05: 0x7ea2, 0x6a13: 0x697c, 0x5922: 0x68a6},
    );
    expect(title.matches(book), isTrue);
    expect(
      PublicationFieldSearch(
        PublicationSearchField.author,
        '曹雪芹',
      ).matches(book),
      isTrue,
    );
    expect(
      PublicationFieldSearch(
        PublicationSearchField.author,
        'John Doe',
      ).matches(book),
      isFalse,
    );
    expect(
      PublicationFieldSearch(
        PublicationSearchField.title,
        'ignored',
      ).matches(book),
      isFalse,
    );
    final isbn = PublicationFieldSearch(
      PublicationSearchField.isbn,
      '0-14-143976-9',
    );
    expect(isbn.matches(book), isTrue);
    expect(
      isbn.matches(
        const PublicationEdition(id: 'title', title: '9780141439761'),
      ),
      isFalse,
    );
  });

  _progressiveSearch();

  _snapshotSearch();

  test('native criteria select the corresponding upstream index', () {
    expect(
      archiveGutenbergSearch(
        'Lewis Carroll',
        wholeCatalogue: true,
        field: PublicationSearchField.author,
      ),
      'mediatype:texts AND (creator:"Lewis Carroll" OR (creator:"Lewis" AND creator:"Carroll"))',
    );
    expect(
      gallicaCatalogueQuery('Victor Hugo', field: PublicationSearchField.title),
      endsWith('and bib.title all "Victor Hugo"'),
    );
    expect(
      gallicaCatalogueQuery(
        '2-07-036373-2',
        field: PublicationSearchField.isbn,
      ),
      endsWith('and bib.fuzzyISBN all "2070363732"'),
    );
  });
}

void _progressiveSearch() {
  test(
    'generic channels filter each progressive batch by the requested field',
    () async {
      await withPublicationCatalogue(
        (fixture) async {
          final discovery = _discovery();
          final id = await _activate(discovery, 'jsonSearch');
          final author = await discovery
              .search(
                'Morgan',
                CancellationToken(),
                sourceId: id,
                field: PublicationSearchField.author,
                progressive: true,
                maxPages: 2,
              )
              .toList();
          expect(author.first.complete, isFalse);
          expect(author.first.editions.map((row) => row.title), [
            'The history',
          ]);
          expect(author.last.complete, isTrue);
          expect(author.last.editions.map((row) => row.title), [
            'The history',
            'Letters',
          ]);

          final title = await discovery
              .search(
                'Morgan',
                CancellationToken(),
                sourceId: id,
                field: PublicationSearchField.title,
              )
              .single;
          expect(title.editions.map((row) => row.title), ['About Morgan']);
          expect(
            fixture.requests.every(
              (uri) => uri.queryParameters['q'] == 'Morgan',
            ),
            isTrue,
          );
        },
        respond: (request) async {
          request.response.write(
            jsonEncode(
              request.uri.queryParameters['page'] == '1'
                  ? [
                      {'title': 'About Morgan', 'author': 'Public Historian'},
                      {'title': 'The history', 'author': 'E. Morgan'},
                    ]
                  : [
                      {'title': 'Letters', 'author': 'E. Morgan'},
                    ],
            ),
          );
          await request.response.close();
        },
      );
    },
  );
}

void _snapshotSearch() {
  test('a snapshot applies the field filter before the result limit', () async {
    await withPublicationCatalogue(
      (fixture) async {
        final discovery = _discovery();
        final id = await _activate(discovery, 'snapshot');
        final result = await discovery
            .search(
              'Morgan',
              CancellationToken(),
              sourceId: id,
              field: PublicationSearchField.title,
            )
            .single;
        expect(result.problem, isNull);
        expect(result.editions.map((row) => row.title), ['About Morgan']);
        expect(fixture.requests, hasLength(1));
      },
      respond: (request) async {
        request.response.write(
          jsonEncode([
            for (var i = 0; i < 110; i++)
              {'title': 'Work $i', 'author': 'Morgan'},
            {'title': 'About Morgan', 'author': 'A. Smith'},
          ]),
        );
        await request.response.close();
      },
    );
  });
}

Future<String> _activate(PublicationDiscovery discovery, String kind) async {
  await discovery.saveConfig(
    jsonEncode({
      'version': 1,
      'kind': kind,
      'name': 'Field search fixture',
      'endpoint': 'https://catalogue.fixture.example/books',
      'field': {'title': 'title', 'author': 'author'},
    }),
  );
  final source = (await discovery.sources())
      .singleWhere((item) => item.source.configurable)
      .source;
  await discovery.setEnabled(source, true);
  return source.id;
}

PublicationDiscovery _discovery() {
  final db = AppDatabase.memory();
  final network = MediaHttpClient();
  final discovery = PublicationDiscovery(
    PublicationStore(db),
    PublicationHttp(network, authorize: (_) {}),
    (_) => true,
  );
  addTearDown(db.close);
  addTearDown(network.close);
  addTearDown(discovery.close);
  return discovery;
}
