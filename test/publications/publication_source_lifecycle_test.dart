import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/publications/application/publication_discovery.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/data/publication_sources.dart';
import 'package:zero_player/features/publications/data/publication_store.dart';
import 'package:zero_player/features/publications/domain/publication.dart';

import '../../test_support/publication_catalogue_fixture.dart';

void main() {
  test(
    'all current built-in sources start enabled and saved choices persist',
    () async {
      final discovery = _discovery();
      final sources = await discovery.sources();
      expect(sources, isNotEmpty);
      expect(sources.every((item) => item.enabled), isTrue);
      expect(sources.map((item) => item.source.id), isNot(contains('rust-zh')));
      expect(sources.map((item) => item.source.id), isNot(contains('pro-git')));
      final source = sources.first.source;
      await discovery.store.db.write(
        'INSERT INTO publication_source_settings(id,enabled,failure) VALUES(?,?,?)',
        [source.id, 1, PublicationProblem.invalid.name],
      );
      final checked = (await discovery.sources()).first;
      expect(checked.problem, PublicationProblem.invalid);
      expect(checked.paused, isFalse);
      expect(await discovery.isEnabled(source.id), isTrue);
      await discovery.setEnabled(source, false);
      await discovery.store.db.write(
        "INSERT INTO publication_source_settings(id,enabled,spec) VALUES('bad-rule',1,'{')",
      );
      expect(await discovery.isEnabled(source.id), isFalse);
      expect(await discovery.sources(), hasLength(sources.length));
    },
  );

  test(
    'disabling a source stops its search without cancelling other results',
    () => _withDiscovery(_disableDuringSearch),
  );
  test(
    'editing a source discards results from its old configuration',
    () => _withDiscovery(_editDuringSearch),
  );
  test(
    'a due check pauses an unavailable source and a recheck restores it',
    () => _withDiscovery(_checkAndRecover),
  );
  test(
    'batch checks preserve disabled sources and single-channel search stays scoped',
    () => _withDiscovery(_batchManagement),
  );
  test(
    'stale source actions preserve the replacement and other rows',
    () async {
      final discovery = _discovery();
      final first = await _addSource(discovery, '/first');
      final old = await _addSource(discovery, '/old');
      await discovery.saveConfig(
        PublicationCatalogueFixture.configuration('/replacement'),
        id: old.id,
      );

      await expectLater(
        discovery.setEnabledBatch([first, old], false),
        throwsFormatException,
      );
      await expectLater(
        discovery.setFavorite(old, true),
        throwsFormatException,
      );
      await expectLater(discovery.remove(old), throwsFormatException);
      expect(await discovery.isEnabled(first.id), isTrue);
      final replacement = (await discovery.sources()).singleWhere(
        (row) => row.source.id == old.id,
      );
      expect(replacement.source.endpoint.path, '/replacement');
      expect(replacement.enabled, isTrue);
      expect(replacement.favorite, isFalse);

      await discovery.setFavorite(replacement.source, true);
      expect(
        (await discovery.sources())
            .singleWhere((row) => row.source.id == old.id)
            .favorite,
        isTrue,
      );
      await discovery.remove(replacement.source);
      expect(
        (await discovery.sources()).map((row) => row.source.id),
        isNot(contains(old.id)),
      );
    },
  );
  test('first search initializes a newly enabled snapshot', () async {
    await withPublicationCatalogue(
      (fixture) async {
        final discovery = _discovery();
        await discovery.saveConfig('''
          {"version":1,"kind":"snapshot","name":"Snapshot",
           "endpoint":"https://catalogue.fixture.example/catalogue",
           "field":{"title":"title","pdf":"link"}}
        ''');
        final source = (await discovery.sources())
            .singleWhere((item) => item.source.configurable)
            .source;
        await discovery.setEnabled(source, true);
        final result = await discovery
            .search('Reference', CancellationToken(), sourceId: source.id)
            .single;
        expect(result.problem, isNull);
        expect(
          result.editions.single.candidates.single.format,
          PublicationFormat.pdf,
        );
        expect(fixture.requests, hasLength(1));
      },
      respond: (request) async {
        request.response.write('[{"title":"Reference","link":"/book.pdf"}]');
        await request.response.close();
      },
    );
  });
  test(
    'remote search keeps paging when a new page has no local match',
    () async {
      await withPublicationCatalogue(
        (fixture) async {
          final discovery = _discovery();
          final source = await _addSource(discovery, '/reference');
          final result = await discovery
              .search('Reference', CancellationToken(), sourceId: source.id)
              .single;
          expect(result.editions.map((book) => book.title), [
            'Reference one',
            'Reference three',
          ]);
          expect(fixture.pages('/reference'), [1, 2, 3]);
        },
        respond: (request) async {
          final title = switch (request.uri.queryParameters['page']) {
            '1' => 'Reference one',
            '2' => 'Different result',
            _ => 'Reference three',
          };
          request.response.write('[{"title":"$title","link":"/book.pdf"}]');
          await request.response.close();
        },
      );
    },
  );
}

Future<void> _batchManagement(
  PublicationDiscovery discovery,
  PublicationCatalogueFixture fixture,
) async {
  final first = await _addSource(discovery, '/first');
  final second = await _addSource(discovery, '/second');
  await discovery.setEnabledBatch([first, second], false);
  await discovery.checkBatch([first, second]);
  final checked = (await discovery.sources()).where(
    (item) => item.source.configurable,
  );
  expect(checked, hasLength(2));
  expect(
    checked.every(
      (item) => !item.enabled && item.checked != null && item.problem == null,
    ),
    isTrue,
  );
  await discovery.setEnabledBatch([first, second], true);
  final result = await discovery
      .search('reference', CancellationToken(), sourceId: second.id)
      .single;
  expect(result.source.id, second.id);
  expect(result.editions.single.title, 'Reference second');
  expect(fixture.pages('/first'), [1]);
  expect(fixture.pages('/second'), [1, 1, 2]);
}

Future<void> _disableDuringSearch(
  PublicationDiscovery discovery,
  PublicationCatalogueFixture fixture,
) async {
  final source = await _addSource(discovery, '/slow');
  await _addSource(discovery, '/available');
  final results = _titles(discovery);
  await fixture.pending.future.timeout(const Duration(seconds: 5));
  await discovery.setEnabled(source, false);

  expect(await results.timeout(const Duration(seconds: 5)), [
    'Reference available',
  ]);
  expect(fixture.pages('/slow'), [1]);
}

Future<void> _editDuringSearch(
  PublicationDiscovery discovery,
  PublicationCatalogueFixture fixture,
) async {
  final source = await _addSource(discovery, '/slow');
  final results = _titles(discovery);
  await fixture.pending.future.timeout(const Duration(seconds: 5));
  await discovery.saveConfig(
    PublicationCatalogueFixture.configuration('/replacement'),
    id: source.id,
  );

  expect(await results.timeout(const Duration(seconds: 5)), isEmpty);
  expect(fixture.pages('/slow'), [1]);
  expect(await _titles(discovery), ['Reference replacement']);
}

Future<void> _checkAndRecover(
  PublicationDiscovery discovery,
  PublicationCatalogueFixture fixture,
) async {
  final source = await _addSource(discovery, '/slow');
  await discovery.saveConfig(
    PublicationCatalogueFixture.configuration('/disabled'),
  );
  final result = _titles(discovery);
  await fixture.pending.future.timeout(const Duration(seconds: 5));
  fixture.status = HttpStatus.gone;
  await Future.wait([discovery.checkDue(), discovery.checkDue()]);
  expect(await result.timeout(const Duration(seconds: 5)), isEmpty);
  final paused = (await discovery.sources()).singleWhere(
    (item) => item.source.id == source.id,
  );
  expect(paused.enabled, isTrue);
  expect(paused.paused, isTrue);
  expect(paused.problem, PublicationProblem.missing);
  expect(await _titles(discovery), isEmpty);
  expect(fixture.pages('/slow'), [1, 1]);
  expect(fixture.pages('/disabled'), isEmpty);

  fixture.status = HttpStatus.ok;
  await discovery.check(source);
  final recovered = (await discovery.sources()).singleWhere(
    (item) => item.source.id == source.id,
  );
  expect(recovered.enabled, isTrue);
  expect(recovered.paused, isFalse);
  expect(recovered.problem, isNull);
  await discovery.checkDue();
  expect(fixture.pages('/slow'), [1, 1, 1]);
  expect(await _titles(discovery), ['Reference slow']);
}

Future<List<String>> _titles(PublicationDiscovery discovery) => discovery
    .search('reference', CancellationToken())
    .expand((update) => update.editions.map((edition) => edition.title))
    .toList();

Future<PublicationSource> _addSource(
  PublicationDiscovery discovery,
  String path,
) async {
  await discovery.saveConfig(PublicationCatalogueFixture.configuration(path));
  final source = (await discovery.sources())
      .singleWhere((item) => item.source.endpoint.path == path)
      .source;
  await discovery.setEnabled(source, true);
  return source;
}

Future<void> _withDiscovery(
  Future<void> Function(PublicationDiscovery, PublicationCatalogueFixture)
  verify,
) => withPublicationCatalogue((fixture) async {
  fixture.holdSearchAt = '/slow';
  final discovery = _discovery();
  for (final item in (await discovery.sources()).where((e) => e.enabled)) {
    await discovery.setEnabled(item.source, false);
  }
  await verify(discovery, fixture);
});

PublicationDiscovery _discovery() {
  final db = AppDatabase.memory();
  addTearDown(db.close);
  final network = MediaHttpClient();
  addTearDown(network.close);
  final discovery = PublicationDiscovery(
    PublicationStore(db),
    PublicationHttp(network, authorize: (_) {}),
    (_) => true,
  );
  addTearDown(discovery.close);
  return discovery;
}
