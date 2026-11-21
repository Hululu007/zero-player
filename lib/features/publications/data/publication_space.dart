import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../domain/acquisition_task.dart';
import '../domain/publication.dart';
import 'publication_releases.dart';
import 'publication_sources.dart';
import 'publication_store.dart';

final class PublicationSpace {
  PublicationSpace(
    this.store,
    this.directory, {
    this.freeBytes = publicationDiskFree,
  });
  final PublicationStore store;
  final Directory directory;
  final Future<int> Function(Directory) freeBytes;
  late final releases = PublicationReleases(store, directory);
  static const defaultLimit = 2 << 30;
  static const growthWindow = 8 << 20;
  static const minFree = 32 << 20;

  Directory taskDirectory(String id) {
    if (!isPublicationDigest(id)) throw const FormatException('图书任务编号无效');
    return Directory(p.join(directory.path, 'tasks', id));
  }

  File managedFile(String digest, PublicationFormat format) {
    if (!isPublicationDigest(digest)) throw const FormatException('文件摘要无效');
    return File(p.join(directory.path, 'files', '$digest.${format.name}'));
  }

  Future<int> limit() async =>
      int.tryParse(await store.preference('quota') ?? '') ?? defaultLimit;

  Future<void> setLimit(int bytes) async {
    if (bytes < 64 << 20 || bytes > 64 << 30) {
      throw const FormatException('图书托管上限须介于 64 MiB 与 64 GiB');
    }
    await store.setPreference('quota', '$bytes');
  }

  Future<({int used, int reserved, int limit})> usage() async {
    await store.initialize();
    final values = await _totals();
    return (
      used: values.$1 + values.$2,
      reserved: values.$3,
      limit: await limit(),
    );
  }

  Future<void> reserve(
    String owner,
    int size, {
    int used = 0,
    void Function()? authorize,
  }) async {
    await store.initialize();
    await directory.create(recursive: true);
    if (!isPublicationDigest(owner) || used < 0 || size < used) {
      throw const FormatException('空间申请无效');
    }
    if (await _allocate(owner, size, used, authorize)) return;
    await releases.recover();
    await releases.release(() async {
      final capacity = await _capacity(owner, size, used);
      final needed = size - capacity.available;
      if (needed <= 0) return const [];
      return _evictionCandidates(needed);
    }, authorize: authorize);
    await _allocate(owner, size, used, authorize, reportShortfall: true);
  }

  Future<bool> _allocate(
    String owner,
    int size,
    int used,
    void Function()? authorize, {
    bool reportShortfall = false,
  }) => store.db.atomic(() async {
    authorize?.call();
    final capacity = await _capacity(owner, size, used);
    if (capacity.available < size) {
      if (!reportShortfall) return false;
      var reclaimable = 0;
      await for (final candidate in _evictableCopies()) {
        reclaimable += candidate.bytes;
      }
      authorize?.call();
      throw PublicationFailure(
        PublicationProblem.space,
        spaceShortfall: (
          requiredBytes: size,
          availableBytes: math.max(0, capacity.available),
          protectedBytes: math.max(0, capacity.bookBytes - reclaimable),
        ),
      );
    }
    if (authorize != null) store.db.beforeCommit(authorize);
    await store.db.write(
      'INSERT OR REPLACE INTO publication_space VALUES(?,?,?)',
      [owner, size, used],
    );
    return true;
  }, tables: {'publication_space'});

  Future<({int available, int bookBytes})> _capacity(
    String owner,
    int size,
    int used,
  ) async {
    final (files, held, remaining) = await _totals(excluding: owner);
    final quota = await limit() - files - held - remaining;
    final available = size == used
        ? quota
        : math.min(
            quota,
            (await freeBytes(directory)) - minFree - remaining + used,
          );
    return (available: available, bookBytes: files);
  }

  Future<(int, int, int)> _totals({String? excluding}) async {
    final file =
        (await store.db.rows(
              """SELECT
              (SELECT COALESCE(SUM(bytes),0) FROM publication_files WHERE placement IN ('managed','retained')) +
              (SELECT COALESCE(SUM(bytes),0) FROM publication_file_releases) AS n""",
            )).single['n']
            as int;
    final record = (await store.db.rows(
      'SELECT COALESCE(SUM(used),0) AS used,COALESCE(SUM(allocated-used),0) AS pending '
      'FROM publication_space WHERE owner<>?',
      [excluding ?? ''],
    )).single;
    return (file, record['used'] as int, record['pending'] as int);
  }

  Future<List<PublicationCopy>?> _evictionCandidates(int needed) async {
    final candidates = <PublicationCopy>[];
    var available = 0;
    await for (final candidate in _evictableCopies()) {
      candidates.add(candidate.copy);
      available += candidate.bytes;
      if (available >= needed) return candidates;
    }
    return null;
  }

  Stream<({PublicationCopy copy, int bytes})> _evictableCopies() async* {
    final now = publicationNow();
    final defaults = [
      'manual',
      for (final source in builtinPublicationSources)
        if (source.enabledByDefault && !source.restricted) source.id,
    ];
    final enabledByDefault = defaults.map((_) => '?').join(',');
    final rows = await store.db.rows(
      '''
      SELECT f.digest,f.format,f.bytes FROM publication_files f
      WHERE f.placement='managed' AND f.downloaded=1 AND f.legacy_id IS NULL
      AND NOT EXISTS(SELECT 1 FROM publication_file_releases r WHERE r.digest=f.digest)
      AND NOT EXISTS(SELECT 1 FROM publication_shelf s WHERE s.digest=f.digest AND s.kept=1)
      AND NOT EXISTS(SELECT 1 FROM publication_notes n WHERE n.digest=f.digest)
      AND NOT EXISTS(SELECT 1 FROM publication_leases l WHERE l.digest=f.digest AND l.process=?
        AND (l.folder IS NULL OR (l.folder='managed' AND l.filename=f.digest||'.'||f.format)))
      AND EXISTS(SELECT 1 FROM publication_tasks t
        LEFT JOIN publication_source_settings ss
          ON ss.id=json_extract(t.candidates,'\$['||t.selected||'].source')
        WHERE t.result=f.digest AND t.state='complete'
        AND (ss.enabled=1 OR (ss.id IS NULL AND
          json_extract(t.candidates,'\$['||t.selected||'].source') IN ($enabledByDefault)))
        AND COALESCE(ss.failure,'') NOT IN ('missing','invalid')
        AND NOT EXISTS(
          SELECT 1 FROM publication_tasks recent
          WHERE recent.state='failed' AND recent.created>t.created
          AND recent.problem IN ('missing','unsupported','guestLimit','login')
          AND json_extract(recent.candidates,'\$['||recent.selected||']')=
              json_extract(t.candidates,'\$['||t.selected||']'))
        AND COALESCE(t.retry_at,0)<=?)
      ORDER BY f.last_read,f.digest''',
      [pid, ...defaults, now],
    );
    for (final row in rows) {
      final digest = row['digest'] as String;
      final path = managedFile(
        digest,
        PublicationFormat.values.byName(row['format'] as String),
      );
      yield (
        copy: (file: path, digest: digest),
        bytes: await path.exists() ? row['bytes'] as int : 0,
      );
    }
  }

  Future<void> checkpoint(String id, int used) => store.db.write(
    'UPDATE publication_space SET used=? WHERE owner=? AND allocated>=?',
    [used, id, used],
  );

  Future<void> release(String id, {int used = 0}) => used == 0
      ? store.db.write('DELETE FROM publication_space WHERE owner=?', [id])
      : store.db.write(
          'INSERT OR REPLACE INTO publication_space VALUES(?,?,?)',
          [id, used, used],
        );

  Future<String> lease(String digest, File file) async {
    final id = newPublicationId();
    final (folder, filename) = releases.location(file);
    await store.db.write(
      'INSERT INTO publication_leases(id,digest,process,folder,filename) VALUES(?,?,?,?,?)',
      [id, digest, pid, folder, filename],
    );
    return id;
  }

  Future<bool> hasLease(String digest, File file) async {
    final (folder, filename) = releases.location(file);
    return (await store.db.rows(
      'SELECT 1 FROM publication_leases WHERE digest=? AND process=? '
      'AND (folder IS NULL OR (folder=? AND filename=?)) LIMIT 1',
      [digest, pid, folder, filename],
    )).isNotEmpty;
  }

  Future<void> unlease(String id) =>
      store.db.write('DELETE FROM publication_leases WHERE id=?', [id]);

  Future<void> removeTemporaries(String id) async {
    final target = taskDirectory(id);
    if (await target.exists()) await target.delete(recursive: true);
    await release(id);
  }

  Future<void> reconcile() async {
    await store.initialize();
    await store.db.atomic(
      () async {
        await store.db.write(
          'DELETE FROM publication_leases WHERE process<>?',
          [pid],
        );
        await _reconcileReservations();
      },
      tables: {
        'publication_space',
        'publication_transfer',
        'publication_leases',
        'publication_tasks',
      },
    );
  }

  Future<void> _reconcileReservations() async {
    final root = Directory(p.join(directory.path, 'tasks'));
    final tasks = {
      for (final row in await store.db.rows(
        'SELECT id,owner,state,archive_kept FROM publication_tasks',
      ))
        row['id']: row,
    };
    final accounted = <String>{};
    if (await root.exists()) {
      await for (final entry in root.list(followLinks: false)) {
        final id = p.basename(entry.path);
        if (entry is! Directory || !isPublicationDigest(id)) continue;
        final task = tasks[id];
        if (task?['owner'] != null) continue;
        final complete = task?['state'] == AcquisitionState.complete.name;
        final archive = File(p.join(entry.path, 'download.part'));
        final keep =
            complete && task?['archive_kept'] == 1 && await archive.exists();
        if (task == null || (complete && !keep)) {
          await removeTemporaries(id);
          await store.db.write(
            'DELETE FROM publication_transfer WHERE task=?',
            [id],
          );
        } else {
          var used = 0;
          await for (final file in entry.list(followLinks: false)) {
            if (file is! File) continue;
            if (keep &&
                const {
                  'book.pdf',
                  'book.epub',
                }.contains(p.basename(file.path))) {
              await file.delete();
            } else {
              used += await file.length();
            }
          }
          await release(id, used: used);
          accounted.add(id);
        }
      }
    }
    final rows = await store.db.rows('SELECT owner FROM publication_space');
    for (final row in rows) {
      final id = row['owner'] as String;
      if (!accounted.contains(id) && tasks[id]?['owner'] == null) {
        await release(id);
      }
    }
    for (final task in tasks.values.where(
      (item) => item['archive_kept'] == 1,
    )) {
      final id = task['id'] as String;
      if (!accounted.contains(id) && task['owner'] == null) {
        await store.db.write(
          'UPDATE publication_tasks SET archive_kept=0 WHERE id=?',
          [id],
        );
      }
    }
  }
}

Future<int> publicationDiskFree(Directory directory) async {
  if (Platform.isAndroid) {
    return await const MethodChannel(
          'zero_player/publications_storage',
        ).invokeMethod<int>('free', directory.path) ??
        0;
  }
  if (Platform.isWindows) return _windowsFree(directory.path);
  final result = await Process.run('df', ['-Pk', directory.path]);
  if (result.exitCode == 0) {
    final line = const LineSplitter().convert(result.stdout as String).last;
    final columns = line.trim().split(RegExp(r'\s+'));
    return (int.tryParse(columns[3]) ?? 0) * 1024;
  }
  throw const PublicationFailure(PublicationProblem.storage);
}

typedef _DiskFreeNative =
    ffi.Int32 Function(
      ffi.Pointer<Utf16>,
      ffi.Pointer<ffi.Uint64>,
      ffi.Pointer<ffi.Uint64>,
      ffi.Pointer<ffi.Uint64>,
    );
typedef _DiskFreeDart =
    int Function(
      ffi.Pointer<Utf16>,
      ffi.Pointer<ffi.Uint64>,
      ffi.Pointer<ffi.Uint64>,
      ffi.Pointer<ffi.Uint64>,
    );

int _windowsFree(String path) {
  final function = ffi.DynamicLibrary.open(
    'kernel32.dll',
  ).lookupFunction<_DiskFreeNative, _DiskFreeDart>('GetDiskFreeSpaceExW');
  final address = path.toNativeUtf16();
  final free = calloc<ffi.Uint64>();
  try {
    if (function(address, free, ffi.nullptr, ffi.nullptr) == 0) {
      throw const PublicationFailure(PublicationProblem.storage);
    }
    return free.value;
  } finally {
    calloc.free(address);
    calloc.free(free);
  }
}
