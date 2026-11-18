import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../tool/architecture/module_boundaries.dart';

List<ModuleViolation> _check(Map<String, String> sources) =>
    checkModuleBoundaries(sources, legacyDependencies: const {});

void main() {
  _layerTests();
  _domainTests();
  _nonUiTests();
  _directiveTests();
  _legacyTest();
  test('project obeys the declared module boundaries', () {
    final root = Directory('lib');
    expect(root.existsSync(), isTrue, reason: 'Run from the project root');
    final sources = {
      for (final file
          in root
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .where((file) => file.path.endsWith('.dart')))
        p.relative(file.path, from: root.path).replaceAll('\\', '/'): file
            .readAsStringSync(),
    };
    final violations = checkModuleBoundaries(sources);
    expect(
      violations,
      isEmpty,
      reason: violations
          .map((v) => 'lib/${v.path}:${v.line}: ${v.rule} -> ${v.target}')
          .join('\n'),
    );
  });
}

void _layerTests() {
  test('core cannot import media through relative or package URIs', () {
    for (final uri in [
      '../../media/cache/store.dart',
      'package:zero_player/media/cache/store.dart',
    ]) {
      final violations = _check({
        'core/persistence/index.dart': "import '$uri';",
        'media/cache/store.dart': '',
      });
      expect(violations.single.rule, startsWith('core must not depend'));
    }
  });

  test('inactive conditional imports and exports cannot bypass boundaries', () {
    for (final directive in ['import', 'export']) {
      final violations = _check({
        'core/transport.dart':
            "$directive 'stub.dart' if (dart.library.io) "
            "'package:zero_player/features/music/data/client.dart';",
        'core/stub.dart': '',
        'features/music/data/client.dart': '',
      });
      expect(violations.single.rule, startsWith('core must not depend'));
    }
  });
}

void _domainTests() {
  test('domain rejects outer layers in its own and other features', () {
    for (final target in [
      'features/books/data/store.dart',
      'features/music/application/controller.dart',
      'features/books/presentation/page.dart',
      'app/services.dart',
      'media/cache/store.dart',
      'core/persistence/database.dart',
      'core/platform/services.dart',
    ]) {
      final violations = _check({
        'features/books/domain/book.dart':
            "import 'package:zero_player/$target';",
        target: '',
      });
      expect(violations.single.rule, 'domain must not depend on outer layers');
    }
  });

  test('domain rejects UI, persistence and native player package types', () {
    for (final uri in [
      'package:flutter/material.dart',
      'package:flutter_riverpod/flutter_riverpod.dart',
      'package:sqlite3/sqlite3.dart',
      'package:media_kit/media_kit.dart',
      'package:pdfrx/pdfrx.dart',
    ]) {
      expect(
        _check({
          'features/books/domain/book.dart': "import '$uri';",
        }).single.rule,
        startsWith('domain must not depend on UI'),
      );
    }
  });
}

void _nonUiTests() {
  test('non-UI code cannot depend on presentation or app composition', () {
    for (final layer in ['application', 'data']) {
      for (final target in [
        'features/books/presentation/page.dart',
        'app/a.dart',
      ]) {
        final violations = _check({
          'features/books/$layer/service.dart':
              "import 'package:zero_player/$target';",
          target: '',
        });
        expect(violations.single.rule, startsWith('non-UI features'));
      }
    }
  });

  test(
    'media can implement domain ports but cannot call feature use cases',
    () {
      expect(
        _check({
          'media/engine/adapter.dart':
              "import '../../features/playback/domain/engine.dart';",
          'features/playback/domain/engine.dart': '',
        }),
        isEmpty,
      );
      final violations = _check({
        'media/engine/adapter.dart':
            "import '../../features/playback/application/player.dart';",
        'features/playback/application/player.dart': '',
      });
      expect(violations.single.rule, startsWith('media may depend'));
    },
  );
}

void _directiveTests() {
  test('parts cannot share private state across modules or feature layers', () {
    for (final directive in ['part', 'part of']) {
      for (final target in [
        'features/music/data/state.dart',
        'features/books/application/state.dart',
      ]) {
        final violations = _check({
          'features/books/data/repository.dart':
              "$directive 'package:zero_player/$target';",
          target: '',
        });
        expect(violations.single.rule, startsWith('parts must stay'));
      }
    }
  });

  test('missing, escaping and invalid dependencies fail with source lines', () {
    for (final uri in ['missing.dart', '../../outside.dart']) {
      final violations = _check({'core/service.dart': "\nimport '$uri';"});
      expect(violations.single.line, 2);
      expect(violations.single.rule, 'local dependency missing from lib');
    }
    expect(
      _check({'core/service.dart': 'import ;'}).first.rule,
      startsWith('invalid Dart:'),
    );
  });

  test('valid domain sharing and same-layer parts remain available', () {
    expect(
      _check({
        'features/books/domain/book.dart':
            "import 'dart:convert';\n"
            "import 'package:crypto/crypto.dart';\n"
            "import '../../sources/domain/source.dart';",
        'features/sources/domain/source.dart': '',
        'features/books/data/repository.dart': "part 'helper.dart';",
        'features/books/data/helper.dart': "part of 'repository.dart';",
      }),
      isEmpty,
    );
  });
}

void _legacyTest() {
  test(
    'legacy composition exceptions are exact and must shrink after removal',
    () {
      const legacy = {
        'features/playback/application/player.dart': {'app/services.dart'},
      };
      final sources = {
        'features/playback/application/player.dart':
            "import '../../../app/services.dart';",
        'app/services.dart': '',
      };
      expect(
        checkModuleBoundaries(sources, legacyDependencies: legacy),
        isEmpty,
      );
      sources['features/playback/application/other.dart'] =
          "import '../../../app/services.dart';";
      expect(
        checkModuleBoundaries(sources, legacyDependencies: legacy).single.path,
        'features/playback/application/other.dart',
      );
      sources.remove('features/playback/application/other.dart');
      sources['features/playback/application/player.dart'] = '';
      expect(
        checkModuleBoundaries(sources, legacyDependencies: legacy).single.rule,
        'remove stale legacy composition exception',
      );
    },
  );
}
