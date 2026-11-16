import 'dart:io';

import 'package:path/path.dart' as p;

/// A test-owned temporary directory, verified again before recursive removal.
final class VerifiedTempDirectory {
  const VerifiedTempDirectory._(
    this.directory,
    this._originalPath,
    this._parent,
    this._name,
    this._prefix,
  );

  final Directory directory;
  final String _originalPath, _parent, _name, _prefix;

  static Future<VerifiedTempDirectory> create(String prefix) async {
    final parent = p.normalize(
      await Directory.systemTemp.resolveSymbolicLinks(),
    );
    final directory = await Directory.systemTemp.createTemp(prefix);
    final originalPath = p.normalize(p.absolute(directory.path));
    final name = p.basename(originalPath);
    final resolved = p.normalize(await directory.resolveSymbolicLinks());
    if (!name.startsWith(prefix) ||
        !p.equals(p.dirname(resolved), parent) ||
        !p.equals(resolved, p.join(parent, name))) {
      throw StateError('unexpected temporary directory location');
    }
    return VerifiedTempDirectory._(
      directory,
      originalPath,
      parent,
      name,
      prefix,
    );
  }

  Future<void> delete() async {
    final current = p.normalize(p.absolute(directory.path));
    final parent = p.normalize(
      await Directory.systemTemp.resolveSymbolicLinks(),
    );
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (!p.equals(current, _originalPath) ||
        !p.equals(parent, _parent) ||
        !_name.startsWith(_prefix) ||
        type != FileSystemEntityType.directory) {
      throw StateError('refusing to remove an unexpected temporary directory');
    }
    final resolved = p.normalize(await directory.resolveSymbolicLinks());
    if (!p.isWithin(parent, resolved) ||
        !p.equals(p.dirname(resolved), parent) ||
        !p.equals(resolved, p.join(parent, _name))) {
      throw StateError('refusing to remove an unexpected temporary directory');
    }
    await directory.delete(recursive: true);
  }
}
