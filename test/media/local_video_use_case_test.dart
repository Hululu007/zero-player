import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/catalog/domain/catalog_item.dart';
import 'package:zero_player/features/library/data/history_repository.dart';
import 'package:zero_player/features/playback/application/local_video.dart';
import 'package:zero_player/features/playback/application/playback_request.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';
import 'package:zero_player/media/gateway/offline_server.dart';

void main() {
  _successTests();
  _failureTests();
}

void _successTests() {
  test(
    'local use case needs only four capabilities and transfers session ownership',
    () async {
      final f = await _Fixture.create();
      final request = await f.useCase().open(f.file.path);
      expect(request.kind, PlaybackMediaKind.local);
      expect(request.supportsMarks, isFalse);
      expect(request.position, const Duration(seconds: 12));
      expect(f.rememberedPath, await f.file.resolveSymbolicLinks());
      expect(request.item.lines.single.episodes.single.uri, f.uri);
      expect(f.closed, 0);
      request.offline!.close();
      expect(f.closed, 1);
    },
  );
  test(
    'last five seconds restart at zero and relocation retains explicit identity',
    () async {
      final f = await _Fixture.create();
      f.position = 56;
      final request = await f.useCase().open(
        f.file.path,
        previousId: 'relocated',
      );
      expect(request.item.id, 'relocated');
      expect(request.position, Duration.zero);
      request.offline!.close();
    },
  );
}

void _failureTests() {
  test(
    'revocation while reading history prevents opening a local session',
    () async {
      final f = await _Fixture.create();
      await expectLater(
        f
            .useCase(
              history: (_) async {
                f.allowed = false;
                return null;
              },
            )
            .open(f.file.path),
        throwsA(isA<ContentBlocked>()),
      );
      expect(f.opened, 0);
      expect(f.rememberedPath, isNull);
    },
  );
  test(
    'revocation while opening closes the session before recording its path',
    () async {
      final f = await _Fixture.create();
      await expectLater(
        f
            .useCase(
              open: (_) async {
                f.allowed = false;
                return OfflineSession(f.uri, () => f.closed++);
              },
            )
            .open(f.file.path),
        throwsA(isA<ContentBlocked>()),
      );
      expect(f.closed, 1);
      expect(f.rememberedPath, isNull);
    },
  );
  test(
    'failed path persistence closes the session and preserves the failure',
    () async {
      final f = await _Fixture.create();
      final error = StateError('persistence failed');
      await expectLater(
        f.useCase(remember: (_, _) async => throw error).open(f.file.path),
        throwsA(same(error)),
      );
      expect(f.closed, 1);
    },
  );
  test(
    'revocation while persisting never returns an authorized playback request',
    () async {
      final f = await _Fixture.create();
      await expectLater(
        f
            .useCase(remember: (_, _) async => f.allowed = false)
            .open(f.file.path),
        throwsA(isA<ContentBlocked>()),
      );
      expect(f.closed, 1);
    },
  );
}

final class _Fixture {
  _Fixture(this.file);
  final File file;
  final uri = Uri.parse('http://127.0.0.1:1234/session/movie.mp4');
  bool allowed = true;
  int opened = 0, closed = 0, position = 12;
  String? rememberedPath;

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('local-use-case-');
    addTearDown(() => root.delete(recursive: true));
    return _Fixture(await File('${root.path}/movie.mp4').writeAsBytes([1, 2]));
  }

  LocalVideo useCase({
    Future<WatchEntry?> Function(String)? history,
    Future<OfflineSession> Function(File)? open,
    Future<void> Function(String, String)? remember,
  }) => LocalVideo(
    requireItem: (CatalogItem _) {
      if (!allowed) throw const ContentBlocked();
    },
    latestHistory:
        history ??
        (_) async =>
            WatchEntry({'position_ms': position * 1000, 'duration_ms': 60000}),
    openFile:
        open ??
        (_) async {
          opened++;
          return OfflineSession(uri, () => closed++);
        },
    rememberPath: remember ?? (_, path) async => rememberedPath = path,
  );
}
