import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;

typedef ModuleViolation = ({String path, int line, String target, String rule});

/// Existing playback composition dependencies; additions require extraction,
/// not a directory-wide exemption. Removed dependencies must leave this set.
const legacyCompositionDependencies = {
  'features/playback/application/playback_controller.dart': {
    'app/app_services.dart',
    'app/app_version.dart',
  },
};

/// Paths are relative to lib and use forward slashes. All import/export
/// branches are checked, including inactive conditional imports and parts.
List<ModuleViolation> checkModuleBoundaries(
  Map<String, String> sources, {
  Map<String, Set<String>> legacyDependencies = legacyCompositionDependencies,
}) {
  final violations = <ModuleViolation>[];
  final usedLegacy = <String>{};
  for (final MapEntry(key: path, value: content) in sources.entries) {
    final parsed = parseString(
      content: content,
      featureSet: FeatureSet.latestLanguageVersion(),
      throwIfDiagnostics: false,
    );
    for (final error in parsed.errors) {
      violations.add((
        path: path,
        line: parsed.lineInfo.getLocation(error.offset).lineNumber,
        target: '',
        rule: 'invalid Dart: ${error.message}',
      ));
    }
    for (final directive in parsed.unit.directives) {
      final line = parsed.lineInfo.getLocation(directive.offset).lineNumber;
      for (final uri in _uris(directive)) {
        final target = _localTarget(path, uri);
        final isPart =
            directive is PartDirective || directive is PartOfDirective;
        final rule = _violation(path, uri, target, isPart, sources);
        if (rule == null) continue;
        if (rule == 'non-UI features must not depend on app' &&
            (legacyDependencies[path]?.contains(target) ?? false)) {
          usedLegacy.add('$path -> $target');
          continue;
        }
        violations.add((path: path, line: line, target: uri, rule: rule));
      }
    }
  }
  for (final entry in legacyDependencies.entries) {
    for (final target in entry.value) {
      if (!usedLegacy.contains('${entry.key} -> $target')) {
        violations.add((
          path: entry.key,
          line: 1,
          target: target,
          rule: 'remove stale legacy composition exception',
        ));
      }
    }
  }
  return violations;
}

Iterable<String> _uris(Directive directive) sync* {
  if (directive is UriBasedDirective) {
    final uri = directive.uri.stringValue;
    if (uri != null) yield uri;
  }
  if (directive is ImportDirective) {
    for (final config in directive.configurations) {
      final uri = config.uri.stringValue;
      if (uri != null) yield uri;
    }
  } else if (directive is ExportDirective) {
    for (final config in directive.configurations) {
      final uri = config.uri.stringValue;
      if (uri != null) yield uri;
    }
  } else if (directive is PartOfDirective) {
    final uri = directive.uri?.stringValue;
    if (uri != null) yield uri;
  }
}

String? _localTarget(String path, String uri) {
  final parsed = Uri.tryParse(uri);
  if (parsed == null) return null;
  if (parsed.scheme == 'package') {
    return parsed.path.startsWith('zero_player/')
        ? p.posix.normalize(parsed.path.substring('zero_player/'.length))
        : null;
  }
  if (parsed.hasScheme) return null;
  return p.posix.normalize(p.posix.join(p.posix.dirname(path), parsed.path));
}

String? _violation(
  String path,
  String uri,
  String? target,
  bool isPart,
  Map<String, String> sources,
) {
  final layer = _featureLayer(path);
  if (target == null) {
    if (layer == 'domain' && _platformPackage(uri)) {
      return 'domain must not depend on UI, persistence or player packages';
    }
    return null;
  }
  if (!sources.containsKey(target)) return 'local dependency missing from lib';
  if (isPart && _owner(path) != _owner(target)) {
    return 'parts must stay within the same module and layer';
  }
  if (path.startsWith('core/') && !target.startsWith('core/')) {
    return 'core must not depend on app, features or media';
  }
  if (layer == 'domain' &&
      (target.startsWith('app/') ||
          target.startsWith('media/') ||
          target.startsWith('core/platform/') ||
          target.startsWith('core/persistence/') ||
          (target.startsWith('features/') &&
              _featureLayer(target) != 'domain'))) {
    return 'domain must not depend on outer layers';
  }
  if (layer != null && layer != 'presentation') {
    if (_featureLayer(target) == 'presentation') {
      return 'non-UI features must not depend on presentation';
    }
    if (target.startsWith('app/')) {
      return 'non-UI features must not depend on app';
    }
  }
  if (path.startsWith('media/') &&
      (target.startsWith('app/') ||
          (target.startsWith('features/') &&
              _featureLayer(target) != 'domain'))) {
    return 'media may depend on feature domain ports only';
  }
  return null;
}

String? _featureLayer(String path) {
  final segments = p.posix.split(path);
  return segments.length >= 4 && segments.first == 'features'
      ? segments[2]
      : null;
}

String _owner(String path) {
  final segments = p.posix.split(path);
  return segments.take(segments.first == 'features' ? 3 : 1).join('/');
}

bool _platformPackage(String uri) {
  if (!uri.startsWith('package:')) return false;
  final package = Uri.parse(uri).path.split('/').first;
  return package == 'flutter' ||
      package.startsWith('flutter_') ||
      package.startsWith('riverpod') ||
      package.startsWith('media_kit') ||
      const {
        'drift',
        'sqlite3',
        'path_provider',
        'window_manager',
        'pdfrx',
        'file_selector',
        'ffmpeg_kit_flutter_new_min',
        'sherpa_onnx',
        'onnxruntime_v2',
      }.contains(package);
}
