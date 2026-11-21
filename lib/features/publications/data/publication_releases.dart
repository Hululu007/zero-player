import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/publication.dart';
import 'publication_store.dart';

typedef PublicationCopy = ({String digest, File file});

/// A renamed copy remains recoverable until its database change commits.
final class PublicationReleases {
  PublicationReleases(this.store, this.root);
  final PublicationStore store;
  final Directory root;

  Future<bool> release(
    Future<List<PublicationCopy>?> Function() select, {
    void Function()? authorize,
  }) async {
    final moved = <(File, File)>[];
    final recorded = <String>[];
    final bool committed;
    try {
      committed = await store.db.atomic(() async {
        authorize?.call();
        final copies = await select();
        if (copies == null) return false;
        for (final copy in copies) {
          authorize?.call();
          final backup = await _stage(copy);
          if (backup != null) {
            moved.add((copy.file, backup));
            recorded.add(copy.digest);
          }
          await store.db.write(
            'UPDATE publication_files SET placement=NULL,admitted=NULL WHERE digest=?',
            [copy.digest],
          );
        }
        if (authorize != null) store.db.beforeCommit(authorize);
        return true;
      }, tables: {'publication_files', 'publication_file_releases'});
    } catch (_) {
      for (final (file, backup) in moved.reversed) {
        if (!await file.exists() && await backup.exists()) {
          await backup.rename(file.path);
        }
      }
      rethrow;
    }
    for (final digest in recorded) {
      await _finish(digest);
    }
    return committed;
  }

  Future<File?> _stage(PublicationCopy copy) async {
    if (!await copy.file.exists()) return null;
    final (folder, name) = location(copy.file);
    final next = _temporary(copy.file);
    if (await next.exists()) {
      throw const PublicationFailure(PublicationProblem.storage);
    }
    final bytes = await copy.file.length();
    await store.db.write(
      'INSERT INTO publication_file_releases(digest,folder,filename,bytes) '
      'VALUES(?,?,?,?)',
      [copy.digest, folder, name, bytes],
    );
    return copy.file.rename(next.path);
  }

  Future<void> recover() async {
    final rows = await store.db.rows(
      'SELECT digest FROM publication_file_releases',
    );
    for (final row in rows) {
      try {
        await _finish(row['digest'] as String);
      } on FileSystemException {
        // A file locked by the operating system stays charged to the quota.
      }
    }
  }

  Future<void> _finish(String digest) => store.db.atomic(() async {
    final row = (await store.db.rows(
      'SELECT folder,filename FROM publication_file_releases WHERE digest=?',
      [digest],
    )).firstOrNull;
    if (row == null) return;
    final file = _temporary(
      _original(row['folder'] as String, row['filename'] as String),
    );
    if (await file.exists()) await file.delete();
    await store.db.write(
      'DELETE FROM publication_file_releases WHERE digest=?',
      [digest],
    );
  }, tables: {'publication_file_releases'});

  Future<void> restoreUncommitted(String digest, File original) async {
    if (await original.exists()) return;
    final backup = _temporary(original);
    if (!await backup.exists()) return;
    final (folder, name) = location(original);
    final committed = await store.db.rows(
      'SELECT 1 FROM publication_file_releases WHERE digest=? AND folder=? AND filename=?',
      [digest, folder, name],
    );
    if (committed.isEmpty) await backup.rename(original.path);
  }

  (String, String) location(File file) {
    final name = p.basename(file.path);
    final folder = p.equals(file.parent.absolute.path, _root('managed'))
        ? 'managed'
        : 'legacy';
    if (!p.equals(file.absolute.path, _original(folder, name).path)) {
      throw const PublicationFailure(PublicationProblem.storage);
    }
    return (folder, name);
  }

  File _temporary(File file) => File('${file.path}.releasing');

  String _root(String folder) => switch (folder) {
    'managed' => p.join(root.absolute.path, 'files'),
    'legacy' => p.join(root.absolute.parent.path, 'book_documents'),
    _ => throw const PublicationFailure(PublicationProblem.storage),
  };

  File _original(String folder, String name) {
    if (!RegExp(r'^[a-f0-9]{64}\.(pdf|epub)$').hasMatch(name)) {
      throw const PublicationFailure(PublicationProblem.storage);
    }
    return File(p.join(_root(folder), name));
  }
}
