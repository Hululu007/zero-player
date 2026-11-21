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
  for (final item in (await discovery.sources()).where((e) => e.enabled)) {
    await discovery.setEnabled(item.source, false);
  }
  await verify(discovery, fixture);
});
