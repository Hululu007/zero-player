import 'dart:io';

import 'package:path/path.dart' as p;

import 'architecture/module_boundaries.dart';

/// Run from the project root with `dart run tool/check_module_boundaries.dart`.
void main() {
  final root = Directory('lib');
  if (!root.existsSync()) {
    stderr.writeln('Run this check from the project root (lib is missing).');
    exitCode = 1;
    return;
  }
  final files =
      root
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final sources = {
    for (final file in files)
      p.relative(file.path, from: root.path).replaceAll('\\', '/'): file
          .readAsStringSync(),
  };
  final violations = checkModuleBoundaries(sources);
  for (final violation in violations) {
    stderr.writeln(
      'lib/${violation.path}:${violation.line}: '
      '${violation.rule} -> ${violation.target}',
    );
  }
  if (violations.isNotEmpty) {
    exitCode = 1;
    return;
  }
  final legacy = legacyCompositionDependencies.values.fold(
    0,
    (count, targets) => count + targets.length,
  );
  stdout.writeln(
    'Module boundaries passed (${files.length} files; '
    '$legacy tracked playback composition dependencies).',
  );
}
