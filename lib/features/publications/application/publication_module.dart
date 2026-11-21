import 'dart:async';
import 'dart:io';

import '../../../core/network/media_http_client.dart';
import '../../../core/persistence/app_database.dart';
import '../../books/data/book_site_check.dart';
import '../../books/data/book_store.dart';
import '../../books/domain/book.dart';
import '../../supervision/application/content_policy.dart';
import '../data/publication_reading.dart';
import '../data/publication_share.dart';
import '../data/publication_space.dart';
import '../data/publication_store.dart';
import '../data/publication_transfer.dart';
import 'publication_acquisitions.dart';
import 'publication_android_worker.dart';
import 'publication_backup.dart';
import 'publication_discovery.dart';
import 'publication_library.dart';
import 'publication_output.dart';
import 'publication_workflow.dart';

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
    final transfer = PublicationTransfer(http, space);
    shares = PublicationShareResolver(http);
    final runner = PublicationAcquisitions(
      store,
      discovery,
      shares,
      transfer,
      library.requireImport,
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
  late final PublicationShareResolver shares;
  late final PublicationWorkflow workflow;
  late final PublicationReading reading;
  late final PublicationOutput output;
  late String _policyState;

  void _policyChanged() {
    final current = bookSitePolicySnapshot(policy);
    if (_policyState == current) return;
    _policyState = current;
    discovery.cancel();
    workflow.revoke();
    output.revoke();
  }

  Future<void> close() async {
    legacy.vault.removeListener(output.revoke);
    policy.removeListener(_policyChanged);
    output.revoke();
    discovery.close();
    await workflow.close();
  }
}
