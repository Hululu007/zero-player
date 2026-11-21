import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../../../core/network/media_http_client.dart';
import '../../../core/persistence/app_database.dart';
import '../../settings/application/settings_controller.dart';
import '../../supervision/application/content_policy.dart';
import '../../supervision/application/supervision_controller.dart';
import '../../supervision/domain/adult_source_evidence.dart';
import '../data/publication_http.dart';
import '../data/publication_share.dart';
import '../data/publication_space.dart';
import '../data/publication_store.dart';
import '../data/publication_transfer.dart';
import '../domain/acquisition_task.dart';
import '../domain/publication.dart';
import 'publication_acquisitions.dart';
import 'publication_discovery.dart';

bool publicationAcquisitionAllowed(ContentPolicy policy, String text) =>
    !policy.supervision.enabled &&
    !policy.supervision.corrupted &&
    policy.textAllowed(text);

PublicationHttp publicationHttp(
  MediaHttpClient transport,
  ContentPolicy policy, {
  bool allowLoopback = false,
}) => PublicationHttp(
  transport,
  allowLoopback: allowLoopback,
  authorize: (uri) {
    if (!publicationAcquisitionAllowed(policy, uri.host) ||
        (policy.filterAdult && knownAdultHost(uri.host))) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
  },
);

Future<void> runPublicationAndroidWorker({bool allowLoopback = false}) async {
  WidgetsFlutterBinding.ensureInitialized();
  const bridge = MethodChannel('zero_player/publications_engine');
  final root = await bridge.invokeMethod<String>('root');
  if (root == null) return;
  final worker = _AndroidWorker(root, bridge, allowLoopback);
  await worker.initialize();
  bridge.setMethodCallHandler(worker.handle);
  await bridge.invokeMethod<void>('ready');
}

final class _AndroidWorker {
  _AndroidWorker(this.root, this.bridge, this.allowLoopback);
  final String root;
  final MethodChannel bridge;
  final bool allowLoopback;
  late final db = AppDatabase(File(p.join(root, 'zero-player.sqlite')));
  late final store = PublicationStore(db);
  late final supervision = SupervisionController(db);
  late final settings = SettingsController(db);
  late final policy = ContentPolicy(settings, supervision);
  late final transport = MediaHttpClient(
    maxConnectionsPerHost: 3,
    allowPrivateNetworks: allowLoopback,
  );
  late final http = publicationHttp(
    transport,
    policy,
    allowLoopback: allowLoopback,
  );
  late final discovery = PublicationDiscovery(
    store,
    http,
    (value) => publicationAcquisitionAllowed(policy, value),
  );
  late final space = PublicationSpace(
    store,
    Directory(p.join(root, 'publications')),
  );
  late final transfer = PublicationTransfer(http, space);
  late final runner = PublicationAcquisitions(
    store,
    discovery,
    PublicationShareResolver(http),
    transfer,
    (value) {
      if (!publicationAcquisitionAllowed(policy, value)) {
        throw const PublicationFailure(PublicationProblem.blocked);
      }
    },
    reloadPolicy: _checkPolicy,
    activity: () => unawaited(_notify()),
  );
  late String _policyFence;
  bool _closed = false;

  Future<void> initialize() async {
    final before = await _fence();
    await supervision.load();
    await settings.load();
    _policyFence = await _fence();
    if (_policyFence != before) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
    await runner.recover(oldHostOnly: false);
  }

  Future<String> _fence() async {
    final rule = (await db.rows('SELECT value FROM app_meta WHERE key=?', [
      SupervisionController.storageKey,
    ])).firstOrNull?['value'];
    final filter = (await db.rows(
      "SELECT value FROM settings WHERE key='filterAdult'",
    )).firstOrNull?['value'];
    // The hash is process-local and never emitted over a channel or to logs.
    return publicationId('$rule\n$filter');
  }

  Future<void> _checkPolicy() async {
    if (await _fence() != _policyFence) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
  }

  Future<Object?> handle(MethodCall call) async {
    if (_closed) return null;
    switch (call.method) {
      case 'idle':
        return !runner.busy;
      case 'start':
        final args = call.arguments as Map;
        runner.start(
          args['id'] as String,
          code: args['code'] as String?,
          codeFor: args['codeFor'] as String?,
        );
        await _notify();
      case 'pause':
        final args = call.arguments as Map;
        await runner.pause(
          args['id'] as String,
          generation: args['generation'] as int?,
        );
        await _notify();
      case 'recheck':
        try {
          await _checkPolicy();
        } on PublicationFailure {
          runner.cancelRunning(reason: PublicationProblem.blocked);
        }
      case 'timeout':
        await _stop(reason: PublicationProblem.systemWait);
      case 'stop':
        await _stop();
      default:
        throw MissingPluginException();
    }
    return null;
  }

  Future<void> _stop({PublicationProblem? reason}) async {
    _closed = true;
    if (reason != null) runner.cancelRunning(reason: reason);
    await runner.close();
    discovery.close();
    transport.close();
    policy.dispose();
    await settings.close();
    await supervision.close();
    await db.close();
  }

  Future<void> _notify() async {
    if (_closed) return;
    final tasks = await store.tasks();
    if (_closed) return;
    await bridge.invokeMethod<void>('progress', {
      'busy': runner.busy,
      'tasks': [
        for (final task in tasks)
          if (task.state == AcquisitionState.resolving ||
              task.state == AcquisitionState.downloading)
            {
              'id': task.id,
              'generation': task.generation,
              'received': task.received,
              'total': task.total,
            },
      ],
    });
  }
}
