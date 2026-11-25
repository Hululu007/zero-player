import 'dart:async';
import 'dart:io';

import '../../../core/network/document_client.dart';
import '../../../core/network/media_http_client.dart';
import '../../../core/network/poster_repository.dart';
import '../../../core/persistence/app_database.dart';
import '../../books/data/book_site_check.dart';
import '../../books/data/book_store.dart';
import '../../books/domain/book.dart';
import '../../supervision/application/content_policy.dart';
import '../data/cloud_drive_accounts.dart';
import '../data/cloud_navhub_catalog.dart';
import '../data/cloud_resource_search.dart';
import '../data/cloud_shared_catalogs.dart';
import '../data/publication_hep_catalogue.dart';
import '../data/publication_reading.dart';
import '../data/publication_http.dart';
import '../data/publication_recommendations.dart';
import '../data/publication_share.dart';
import '../data/publication_space.dart';
import '../data/publication_store.dart';
import '../data/publication_transfer.dart';
import 'cloud_resource_download.dart';
import 'publication_acquisitions.dart';
import 'publication_android_worker.dart';
import 'publication_backup.dart';
import 'publication_collections.dart';
import 'publication_discovery.dart';
import 'publication_library.dart';
import 'publication_output.dart';
import 'publication_workflow.dart';
import 'publication_website_access.dart';

final class PublicationModule {
  PublicationModule(
    AppDatabase db,
    Directory directory,
    this.policy,
    this.legacy,
    Directory legacyDocuments,
    bool Function(Book) bookAllowed,
    MediaHttpClient transport, {
    bool allowLoopback = false,
    bool? android,
    Future<void> Function()? checkDownload,
  }) {
    store = PublicationStore(db);
    space = PublicationSpace(store, directory);
    library = PublicationLibrary(
      store,
      space,
      legacy,
      legacyDocuments,
      policy,
      bookAllowed,
    );
    final http = publicationHttp(
      transport,
      policy,
      allowLoopback: allowLoopback,
    );
    discovery = PublicationDiscovery(
      store,
      http,
      (text) => publicationAcquisitionAllowed(policy, text),
    );
    recommendations = PublicationRecommendations(http, discovery.allowed);
    collections = PublicationCollections(store, discovery.allowed);
    covers = PosterRepository(
      DocumentClient(transport),
      concurrency: 6,
      networkTimeout: const Duration(seconds: 9),
      headers: (uri) => {
        ...posterHeaders(uri),
        if (hostIn(uri, 'doubanio.com')) 'Referer': 'https://book.douban.com/',
        if (isHepCover(uri)) 'Referer': '${hepHome.origin}/',
      },
      validateTarget: (uri) {
        validatePublicationAddress(uri);
        if (uri.scheme != 'https' || uri.port != 443) {
          throw const FormatException('图书封面地址无效');
        }
        http.authorize(uri);
      },
    );
    final transfer = PublicationTransfer(http, space);
    cloudAccounts = CloudDriveAccounts();
    shares = PublicationShareResolver(
      http,
      catalogueFor: discovery.catalogueFor,
      cloudAccounts: cloudAccounts,
    );
    cloudResources = CloudResourceDownload(
      shares,
      library.requireImport,
      checkDownload: checkDownload,
    );
    cloudNavHub = CloudNavHubCatalog(http, directory);
    cloudCatalogs = CloudSharedCatalogs(http, directory);
    cloudSearch = CloudResourceSearch(http, cloudNavHub);
    final runner = PublicationAcquisitions(
      store,
      discovery,
      shares,
      transfer,
      library.requireImport,
      checkDownload: checkDownload,
    );
    workflow = PublicationWorkflow(
      store,
      space,
      library,
      discovery,
      runner,
      transfer,
      android: android ?? Platform.isAndroid,
    );
    websites = PublicationWebsiteAccess(discovery, library, store, shares);
    reading = PublicationReading(store, legacy);
    output = PublicationOutput(library, PublicationBackup(library, reading));
    _policyState = bookSitePolicySnapshot(policy);
    policy.addListener(_policyChanged);
    legacy.vault.addListener(output.revoke);
  }

  final ContentPolicy policy;
  final BookStore legacy;
  late final PublicationStore store;
  late final PublicationSpace space;
  late final PublicationLibrary library;
  late final PublicationDiscovery discovery;
  late final PublicationRecommendations recommendations;
  late final PublicationCollections collections;
  late final PosterRepository covers;
  late final PublicationShareResolver shares;
  late final CloudResourceDownload cloudResources;
  late final CloudDriveAccounts cloudAccounts;
  late final CloudNavHubCatalog cloudNavHub;
  late final CloudSharedCatalogs cloudCatalogs;
  late final CloudResourceSearch cloudSearch;
  late final PublicationWorkflow workflow;
  late final PublicationWebsiteAccess websites;
  late final PublicationReading reading;
  late final PublicationOutput output;
  late String _policyState;

  void _policyChanged() {
    final current = bookSitePolicySnapshot(policy);
    if (_policyState == current) return;
    _policyState = current;
    discovery.cancel();
    recommendations.clear();
    covers.clear();
    workflow.revoke();
    websites.revoke();
    cloudResources.cancel();
    cloudAccounts.clear();
    cloudNavHub.cancel();
    cloudCatalogs.cancel();
    cloudSearch.clearPanHubSession();
    cloudSearch.configureHaiSou(null);
    output.revoke();
  }

  Future<void> close() async {
    legacy.vault.removeListener(output.revoke);
    policy.removeListener(_policyChanged);
    cloudResources.cancel();
    cloudAccounts.clear();
    cloudNavHub.cancel();
    cloudCatalogs.cancel();
    cloudSearch.clearPanHubSession();
    cloudSearch.configureHaiSou(null);
    output.revoke();
    discovery.close();
    recommendations.clear();
    covers.close();
    await websites.close();
    await workflow.close();
  }
}
