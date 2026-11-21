import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../../core/network/cancellation_token.dart';
import '../data/publication_share.dart';
import '../data/publication_space.dart';
import '../data/publication_store.dart';
import '../data/publication_transfer.dart';
import '../data/publication_zip.dart';
import '../domain/acquisition_task.dart';
import '../domain/publication.dart';
import 'publication_acquisitions.dart';
import 'publication_backup.dart';
import 'publication_discovery.dart';
import 'publication_library.dart';

typedef PublicationFileSelection = ({PublicationSharedFile file, String? code});

final class PublicationLocalDocument {
  PublicationLocalDocument.external(File file)
    : this._(file, p.basename(file.path), null);

  const PublicationLocalDocument._(this.file, this.name, this._owner);

  final File file;
  final String name;
  final String? _owner;
}

final class PublicationWorkflow {
  PublicationWorkflow(
    this.store,
    this.space,
    this.library,
    this.discovery,
    this.runner,
    this.transfer, {
    required this.android,
  }) {
    _sourceSubscription = store.db
        .changesFor({'publication_source_settings'})
        .listen((_) => unawaited(_checkImportSources()));
  }
  final PublicationStore store;
  final PublicationSpace space;
  final PublicationLibrary library;
  final PublicationDiscovery discovery;
  final PublicationAcquisitions runner;
  final PublicationTransfer transfer;
  final bool android;
  static const channel = MethodChannel('zero_player/publications_worker');
  static const _filePicker = MethodChannel('zero_player/publications_files');
  late final StreamSubscription<void> _sourceSubscription;
  final _imports = <String, CancellationToken>{};
  final _archivesInUse = <String>{};
  final _importSources = <String, String>{};
  final _importFinished = <String, Completer<void>>{};
  Future<void>? _initialization;
  bool _disposed = false;

  Future<void> initialize() => _initialization ??= _recover();

  Future<void> _checkImportSources() async {
    if (_disposed) return;
    for (final entry in _importSources.entries.toList()) {
      try {
        if (!await discovery.isEnabled(entry.value)) {
          _imports[entry.key]?.cancel();
        }
      } on Exception {
        _imports[entry.key]?.cancel();
      }
    }
  }

  Future<void> _recover() async {
    try {
      await store.initialize();
      await runner.recover();
      await library.reconcile();
      await space.reconcile();
      await store.db.write(
        "UPDATE publication_tasks SET state='downloaded' WHERE state='importing'",
      );
    } catch (_) {
      _initialization = null;
      rethrow;
    }
  }

  Future<String> add(
    PublicationEdition edition,
    PublicationFormat format, {
    String? shareCode,
    List<PublicationEdition> alternatives = const [],
  }) async {
    final candidates = await _candidates(edition, format, alternatives);
    return _enqueue(edition, candidates, code: shareCode);
  }

  Future<String?> acquireFromCatalog(
    PublicationEdition edition,
    PublicationFormat format,
    Future<PublicationFileSelection?> Function(AcquisitionCandidate) select, {
    List<PublicationEdition> alternatives = const [],
  }) async {
    final candidates = await _candidates(edition, format, alternatives);
    final first = candidates.first;
    if (!requiresPublicationFileChoice(first)) {
      return _enqueue(edition, candidates);
    }
    PublicationFileSelection? selection;
    try {
      selection = await select(first);
    } on RequestCancelled {
      rethrow;
    } catch (error) {
      final failure = runner.classify(error);
      if (failure.problem == PublicationProblem.blocked) rethrow;
      return _enqueue(edition, candidates, preflightFailure: failure);
    }
    if (selection == null) return null;
    library.requireImport(selection.file.name);
    await _confirmCandidate(first);
    candidates[0] = first.withSharedFile(selection.file);
    return _enqueue(edition, candidates, code: selection.code);
  }

  Future<List<AcquisitionCandidate>> _candidates(
    PublicationEdition edition,
    PublicationFormat format,
    List<PublicationEdition> alternatives,
  ) async {
    await initialize();
    library.requireImport('${edition.title} ${edition.author}');
    final candidates = <String, AcquisitionCandidate>{};
    for (final version in [
      edition,
      ...alternatives.where(edition.confirmsSameEdition),
    ]) {
      for (final candidate in version.candidates.where(
        (candidate) => candidate.format == format,
      )) {
        if (await discovery.isEnabled(candidate.source)) {
          candidates.putIfAbsent(candidate.id, () => candidate);
        }
      }
    }
    if (candidates.isEmpty || candidates.length > 32) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    return candidates.values.toList();
  }

  Future<String> _enqueue(
    PublicationEdition edition,
    List<AcquisitionCandidate> candidates, {
    String? code,
    PublicationFailure? preflightFailure,
  }) async {
    library.requireImport('${edition.title} ${edition.author}');
    final id = await store.addTask(
      edition,
      candidates,
      preflightFailure: preflightFailure,
    );
    if (preflightFailure == null || candidates.length > 1) {
      await start(id, code: code, codeFor: candidates.first.id);
    }
    return id;
  }

  Future<List<PublicationSharedFile>> inspectSourceShare(
    AcquisitionCandidate candidate,
    String? code,
    CancellationToken token,
  ) async {
    library.requireImport(candidate.link.host);
    await _confirmCandidate(candidate);
    final files = await runner.resolver.inspect(candidate.link, code, token);
    library.requireImport(candidate.link.host);
    await _confirmCandidate(candidate);
    return files;
  }

  Future<void> start(String id, {String? code, String? codeFor}) async {
    await initialize();
    library.requireImport('');
    final task = await store.task(id);
    if (task == null ||
        task.state == AcquisitionState.complete ||
        task.state == AcquisitionState.downloaded) {
      return;
    }
    if (task.retryAt?.isAfter(DateTime.now()) == true) {
      throw PublicationFailure(
        PublicationProblem.rateLimit,
        retryAt: task.retryAt,
      );
    }
    final bound = code == null ? null : codeFor ?? task.candidate.id;
    if (!android) {
      runner.start(id, code: code, codeFor: bound);
      return;
    }
    try {
      await channel.invokeMethod<void>('start', {
        'id': id,
        'code': ?code,
        'codeFor': ?bound,
        'root': space.directory.parent.path,
      });
    } on PlatformException catch (error) {
      final problem = error.code == 'system_wait'
          ? PublicationProblem.systemWait
          : PublicationProblem.storage;
      await store.updateTask(
        task,
        AcquisitionState.failed,
        failure: PublicationFailure(problem),
      );
      throw PublicationFailure(problem);
    }
  }

  Future<void> pause(AcquisitionTask task) async {
    if (android) {
      await channel.invokeMethod<void>('pause', {
        'id': task.id,
        'generation': task.generation,
      });
    } else {
      await runner.pause(task.id, generation: task.generation);
    }
  }

  Future<void> removeTask(AcquisitionTask task) async {
    if (_imports.containsKey(task.id) || _archivesInUse.contains(task.id)) {
      throw const PublicationFailure(PublicationProblem.inUse);
    }
    await pause(task);
    await store.db.atomic(
      () async {
        final owner = (await store.db.rows(
          'SELECT owner,state,archive_kept FROM publication_tasks WHERE id=?',
          [task.id],
        )).firstOrNull;
        if (owner?['owner'] != null ||
            owner?['state'] == AcquisitionState.importing.name ||
            owner?['archive_kept'] == 1 ||
            _imports.containsKey(task.id) ||
            _archivesInUse.contains(task.id)) {
          throw const PublicationFailure(PublicationProblem.inUse);
        }
        await space.removeTemporaries(task.id);
        await store.db.write('DELETE FROM publication_transfer WHERE task=?', [
          task.id,
        ]);
        await store.db.write('DELETE FROM publication_tasks WHERE id=?', [
          task.id,
        ]);
      },
      tables: {
        'publication_tasks',
        'publication_transfer',
        'publication_space',
      },
    );
  }

  Future<List<PublicationZipEntry>> downloadedEntries(
    AcquisitionTask task,
  ) async {
    library.requireImport(task.edition.title);
    await _confirmCandidate(task.candidate);
    final entries = await PublicationZip.inspect(transfer.part(task.id));
    library.requireImport(task.edition.title);
    await _confirmCandidate(task.candidate);
    return entries;
  }

  Future<String> importRetainedArchive(
    AcquisitionTask task,
    PublicationZipEntry entry, {
    String? zipPassword,
    String? pdfPassword,
  }) => _withArchive(task, (current) async {
    library.requireImport(current.edition.title);
    return _importLocal(
      transfer.part(current.id),
      entry: entry,
      zipPassword: zipPassword,
      pdfPassword: pdfPassword,
      source: current.candidate,
    );
  });

  Future<void> deleteRetainedArchive(AcquisitionTask task) =>
      _withArchive(task, (current) async {
        await space.removeTemporaries(current.id);
        await store.db.write(
          'UPDATE publication_tasks SET archive_kept=0 WHERE id=?',
          [current.id],
        );
      });

  Future<T> _withArchive<T>(
    AcquisitionTask task,
    Future<T> Function(AcquisitionTask) use,
  ) async {
    await initialize();
    if (!_archivesInUse.add(task.id)) {
      throw const PublicationFailure(PublicationProblem.inUse);
    }
    try {
      final current = await store.task(task.id);
      if (current == null ||
          !current.retainedArchive ||
          current.state != AcquisitionState.complete) {
        throw const PublicationFailure(PublicationProblem.missing);
      }
      return await use(current);
    } finally {
      _archivesInUse.remove(task.id);
    }
  }

  Future<void> _confirmCandidate(AcquisitionCandidate candidate) async {
    if (candidate.source == 'manual') return;
    final source = await discovery.enabledSource(candidate.source);
    if (source == null) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
    if (source.configurable) source.restrict(candidate.link);
  }

  Future<void> finish(
    AcquisitionTask task, {
    PublicationZipEntry? entry,
    String? zipPassword,
    String? pdfPassword,
    bool retainArchive = false,
  }) async {
    await initialize();
    if (_imports.containsKey(task.id)) return;
    final current = await store.task(task.id);
    if (current == null ||
        current.generation != task.generation ||
        current.state != AcquisitionState.downloaded ||
        _imports.containsKey(task.id)) {
      return;
    }
    final token = _imports[task.id] = CancellationToken();
    _importFinished[task.id] = Completer<void>();
    _importSources[task.id] = task.candidate.source;
    final keep =
        retainArchive &&
        entry != null &&
        task.candidate.format == PublicationFormat.zip;
    try {
      library.requireImport(task.edition.title);
      await _confirmCandidate(task.candidate);
      token.check();
      await store.updateTask(task, AcquisitionState.importing);
      final archive = transfer.part(task.id);
      final file = entry == null
          ? archive
          : await _extract(archive, entry, task.id, token, zipPassword);
      final format = entry?.format ?? task.candidate.format;
      final edition = entry == null
          ? task.edition
          : PublicationEdition(
              id: publicationId('${task.edition.id}:${entry.path}'),
              title: p.basenameWithoutExtension(entry.path),
              author: task.edition.author,
              page: task.edition.page,
              license: task.edition.license,
            );
      await library.importStaged(
        file,
        '${edition.title}.${format.name}',
        format,
        task.id,
        token,
        edition: edition,
        pdfPassword: pdfPassword,
        downloaded: true,
        task: task,
        confirmSource: () => _confirmCandidate(task.candidate),
        retainArchive: keep,
      );
      if (keep) {
        await _releaseExtracted(task.id, entry);
      } else {
        await space.removeTemporaries(task.id);
      }
      await store.db.write('DELETE FROM publication_transfer WHERE task=?', [
        task.id,
      ]);
    } catch (error) {
      final current = await store.task(task.id);
      if (current?.state != AcquisitionState.complete) {
        await _releaseExtracted(task.id, entry);
        await store.updateTask(
          task,
          AcquisitionState.downloaded,
          failure: error is PublicationFailure
              ? error
              : PublicationFailure(
                  error is RequestCancelled
                      ? PublicationProblem.blocked
                      : PublicationProblem.invalid,
                ),
        );
      }
      rethrow;
    } finally {
      _imports.remove(task.id);
      _importSources.remove(task.id);
      _importFinished.remove(task.id)?.complete();
    }
  }

  Future<String> importLocal(
    File file, {
    PublicationZipEntry? entry,
    String? zipPassword,
    String? pdfPassword,
  }) => _importLocal(
    file,
    entry: entry,
    zipPassword: zipPassword,
    pdfPassword: pdfPassword,
  );

  Future<T?> withAndroidDocument<T>(
    Future<T?> Function(PublicationLocalDocument document) action, {
    bool backup = false,
  }) => _withLocalImport((owner, token) async {
    final document = await _selectAndroidDocument(owner, token, backup: backup);
    if (document == null) return null;
    token.check();
    return action(document);
  });

  Future<PublicationLocalDocument?> _selectAndroidDocument(
    String owner,
    CancellationToken token, {
    required bool backup,
  }) async {
    Future<void> release() => _filePicker
        .invokeMethod<void>('release', owner)
        .catchError((Object _) {});
    final unlisten = token.listen(() => unawaited(release()));
    try {
      library.requireImport('');
      final picked = await _filePicker.invokeMapMethod<String, Object?>(
        'choose',
        {'id': owner, 'backup': backup},
      );
      token.check();
      if (picked == null) return null;
      final rawName = picked['name'] as String? ?? '';
      final name = p.posix.basename(rawName.replaceAll('\\', '/'));
      final limit = backup
          ? (name.toLowerCase().endsWith('.json')
                ? PublicationBackup.maxBytes
                : null)
          : PublicationFormat.fromName(name)?.maxBytes;
      if (limit == null) {
        throw const PublicationFailure(PublicationProblem.unsupported);
      }
      library.requireImport(name);
      final staged = await _stageAndroidDocument(
        owner,
        token,
        name,
        limit,
        picked['size'] as int?,
      );
      return PublicationLocalDocument._(staged, name, owner);
    } on PlatformException catch (error) {
      token.check();
      throw PublicationFailure(
        error.code == 'busy'
            ? PublicationProblem.inUse
            : PublicationProblem.missing,
      );
    } finally {
      unlisten();
      await release();
    }
  }

  Future<File> _stageAndroidDocument(
    String owner,
    CancellationToken token,
    String name,
    int limit,
    int? expected,
  ) async {
    if (expected != null && (expected < 1 || expected > limit)) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    void authorize() {
      token.check();
      library.requireImport(name);
    }

    var reserved = expected ?? math.min(limit, PublicationSpace.growthWindow);
    await space.reserve(owner, reserved, authorize: authorize);
    final target = transfer.part(owner);
    await target.parent.create(recursive: true);
    final sink = await target.open(mode: FileMode.write);
    var written = 0;
    var nextCheckpoint = PublicationSpace.growthWindow;
    try {
      while (true) {
        authorize();
        final block = await _filePicker.invokeMethod<Uint8List>('read', owner);
        authorize();
        if (block == null) {
          throw const PublicationFailure(PublicationProblem.missing);
        }
        if (block.isEmpty) break;
        final next = written + block.length;
        if (next > (expected ?? limit)) {
          throw const PublicationFailure(PublicationProblem.invalid);
        }
        if (next > reserved) {
          reserved = math.min(
            limit,
            math.max(next, reserved + PublicationSpace.growthWindow),
          );
          await space.reserve(
            owner,
            reserved,
            used: written,
            authorize: authorize,
          );
        }
        authorize();
        await sink.writeFrom(block);
        written = next;
        if (written >= nextCheckpoint) {
          await space.checkpoint(owner, written);
          nextCheckpoint = written + PublicationSpace.growthWindow;
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (written == 0 || (expected != null && written != expected)) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    authorize();
    await space.release(owner, used: written);
    return target;
  }

  Future<String> importDocument(
    PublicationLocalDocument document, {
    PublicationZipEntry? entry,
    String? zipPassword,
    String? pdfPassword,
  }) {
    final owner = document._owner;
    if (owner == null) {
      return importLocal(
        document.file,
        entry: entry,
        zipPassword: zipPassword,
        pdfPassword: pdfPassword,
      );
    }
    final token = _imports[owner];
    if (token == null) {
      throw const PublicationFailure(PublicationProblem.missing);
    }
    return _finishLocalImport(
      document,
      owner,
      token,
      entry: entry,
      zipPassword: zipPassword,
      pdfPassword: pdfPassword,
    );
  }

  Future<String> _importLocal(
    File file, {
    PublicationZipEntry? entry,
    String? zipPassword,
    String? pdfPassword,
    AcquisitionCandidate? source,
  }) => _withLocalImport(
    (owner, token) => _finishLocalImport(
      PublicationLocalDocument.external(file),
      owner,
      token,
      entry: entry,
      zipPassword: zipPassword,
      pdfPassword: pdfPassword,
      source: source,
    ),
    source: source?.source,
  );

  Future<String> _finishLocalImport(
    PublicationLocalDocument document,
    String owner,
    CancellationToken token, {
    PublicationZipEntry? entry,
    String? zipPassword,
    String? pdfPassword,
    AcquisitionCandidate? source,
  }) async {
    token.check();
    library.requireImport(document.name);
    if (source != null) await _confirmCandidate(source);
    final type = entry?.format ?? PublicationFormat.fromName(document.name);
    if (type == null || type == PublicationFormat.zip) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final file = document.file;
    final alreadyStaged = document._owner != null;
    final File stage;
    if (entry != null) {
      stage = await _extract(
        file,
        entry,
        owner,
        token,
        zipPassword,
        external: !alreadyStaged,
      );
    } else {
      stage = alreadyStaged
          ? file
          : await _copyToStage(file, type, owner, token);
    }
    return library.importStaged(
      stage,
      entry?.path ?? document.name,
      type,
      owner,
      token,
      pdfPassword: pdfPassword,
      confirmSource: source == null ? null : () => _confirmCandidate(source),
    );
  }

  Future<T> _withLocalImport<T>(
    Future<T> Function(String owner, CancellationToken token) action, {
    String? source,
  }) async {
    await initialize();
    final id = newPublicationId();
    final token = _imports[id] = CancellationToken();
    _importFinished[id] = Completer<void>();
    if (source != null) _importSources[id] = source;
    try {
      return await action(id, token);
    } finally {
      try {
        await space.removeTemporaries(id);
      } finally {
        _imports.remove(id);
        _importSources.remove(id);
        _importFinished.remove(id)?.complete();
      }
    }
  }

  Future<File> _copyToStage(
    File file,
    PublicationFormat type,
    String id,
    CancellationToken token,
  ) async {
    final size = await file.length();
    if (size < 1 || size > type.maxBytes) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    final target = transfer.part(id);
    await target.parent.create(recursive: true);
    await space.reserve(id, size, authorize: () => library.requireImport(''));
    final output = await target.open(mode: FileMode.write);
    var copied = 0;
    try {
      await for (final chunk in file.openRead(0, size)) {
        token.check();
        library.requireImport('');
        await output.writeFrom(chunk);
        copied += chunk.length;
      }
      await output.flush();
    } finally {
      await output.close();
    }
    if (copied != size || await file.length() != size) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    await space.checkpoint(id, size);
    return target;
  }

  Future<File> _extract(
    File source,
    PublicationZipEntry entry,
    String id,
    CancellationToken token,
    String? key, {
    bool external = false,
  }) async {
    await _releaseExtracted(id, entry);
    final staged = File(
      p.join(space.taskDirectory(id).path, 'book.${entry.format.name}'),
    );
    await staged.parent.create(recursive: true);
    final occupied = external ? 0 : await source.length();
    await space.reserve(
      id,
      occupied + entry.bytes,
      used: occupied,
      authorize: () => library.requireImport(''),
    );
    await PublicationZip.extract(source, entry, staged, token, password: key);
    await space.checkpoint(id, occupied + entry.bytes);
    return staged;
  }

  Future<void> _releaseExtracted(String id, PublicationZipEntry? entry) async {
    if (entry == null) return;
    final staged = File(
      p.join(space.taskDirectory(id).path, 'book.${entry.format.name}'),
    );
    if (await staged.exists()) await staged.delete();
    final archive = transfer.part(id);
    await space.release(
      id,
      used: await archive.exists() ? await archive.length() : 0,
    );
  }

  void revoke() {
    if (_disposed) return;
    for (final token in _imports.values) {
      token.cancel();
    }
    if (android) {
      unawaited(
        channel.invokeMethod<void>('recheck').catchError((Object _) {}),
      );
    } else {
      runner.cancelRunning();
    }
  }

  Future<void> close() async {
    _disposed = true;
    await _sourceSubscription.cancel();
    for (final token in _imports.values) {
      token.cancel();
    }
    await runner.close();
    await Future.wait(_importFinished.values.map((pending) => pending.future));
  }
}
