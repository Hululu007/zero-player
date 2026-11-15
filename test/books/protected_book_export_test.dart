import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/platform/protected_book_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('protected-book-test-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  desktopExportTests(() => directory);
  androidExportTests(() => directory);
}

void desktopExportTests(Directory Function() root) {
  test(
    'existing desktop target survives and only owned staging is removed',
    () async {
      final source = File(p.join(root().path, 'source'))
        ..writeAsStringSync('new');
      final target = File(p.join(root().path, 'target'))
        ..writeAsStringSync('original');
      final unrelated = await Directory(
        p.join(root().path, 'unrelated'),
      ).create();
      final transfer = ProtectedBookExport(
        android: false,
        chooseLocation: (_) async => target.path,
      );
      await expectLater(
        transfer.saveFile(
          source,
          'book.txt',
          'text/plain',
          cancellation: CancellationToken(),
          validate: () {},
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('目标可能已存在'),
          ),
        ),
      );
      expect(await target.readAsString(), 'original');
      expect(await unrelated.exists(), isTrue);
      expect(
        root().listSync().whereType<Directory>().map((d) => p.basename(d.path)),
        ['unrelated'],
      );
    },
  );

  test('policy is checked after the desktop selector returns', () async {
    final source = File(p.join(root().path, 'source'))
      ..writeAsStringSync('book');
    final target = File(p.join(root().path, 'target'));
    final choice = Completer<String?>();
    final entered = Completer<void>();
    var allowed = true;
    final transfer = ProtectedBookExport(
      android: false,
      chooseLocation: (_) {
        entered.complete();
        return choice.future;
      },
    );
    final operation = transfer.saveFile(
      source,
      'book.txt',
      'text/plain',
      cancellation: CancellationToken(),
      validate: () {
        if (!allowed) throw StateError('policy changed');
      },
    );
    await entered.future;
    allowed = false;
    choice.complete(target.path);
    await expectLater(operation, throwsStateError);
    expect(await target.exists(), isFalse);
  });

  test(
    'cancellation during chunked copy removes only this staging directory',
    () async {
      final source = File(p.join(root().path, 'source'))
        ..writeAsBytesSync(List.filled(200000, 7));
      final target = File(p.join(root().path, 'target'));
      final token = CancellationToken();
      var checks = 0;
      final transfer = ProtectedBookExport(
        android: false,
        chooseLocation: (_) async => target.path,
      );
      await expectLater(
        transfer.saveFile(
          source,
          'book.txt',
          'text/plain',
          cancellation: token,
          validate: () {
            if (++checks == 4) token.cancel();
          },
        ),
        throwsA(isA<RequestCancelled>()),
      );
      expect(await target.exists(), isFalse);
      expect(root().listSync().whereType<Directory>(), isEmpty);
    },
  );

  test(
    'protected bytes publish and remove both owned temporary directories',
    () async {
      final target = File(p.join(root().path, 'book.zip'));
      final transfer = ProtectedBookExport(
        android: false,
        chooseLocation: (_) async => target.path,
        temporaryDirectory: () async => root(),
      );
      await transfer.saveBytes(
        'book.zip',
        [1, 2, 3],
        'application/zip',
        cancellation: CancellationToken(),
        validate: () {},
      );
      expect(await target.readAsBytes(), [1, 2, 3]);
      expect(root().listSync().whereType<Directory>(), isEmpty);
    },
  );

  test('many export chunks validate all content only once', () async {
    final target = File(p.join(root().path, 'large.txt'));
    final token = CancellationToken();
    var fullChecks = 0;
    var stateChecks = 0;
    final guard = BookExportValidation(
      cancellation: token,
      validateContent: () => fullChecks++,
      validateState: () => stateChecks++,
    );
    final transfer = ProtectedBookExport(
      android: false,
      chooseLocation: (_) async => target.path,
      temporaryDirectory: () async => root(),
    );
    final bytes = Uint8List(1024 * 1024);
    await transfer.saveBytes(
      'large.txt',
      bytes,
      'text/plain',
      cancellation: token,
      validate: guard.check,
    );
    expect(await target.length(), bytes.length);
    expect(fullChecks, 1);
    expect(stateChecks, greaterThan(32));
  });

  test(
    'policy notification during a multi-chunk copy stops publication',
    () async {
      final target = File(p.join(root().path, 'large.txt'));
      final token = CancellationToken();
      final policy = ValueNotifier(0)..addListener(token.cancel);
      addTearDown(policy.dispose);
      var fullChecks = 0;
      var afterSelection = 0;
      var selected = false;
      final guard = BookExportValidation(
        cancellation: token,
        validateContent: () => fullChecks++,
        validateState: () {
          if (selected && ++afterSelection == 6) policy.value++;
        },
      );
      final transfer = ProtectedBookExport(
        android: false,
        chooseLocation: (_) async {
          selected = true;
          return target.path;
        },
        temporaryDirectory: () async => root(),
      );
      await expectLater(
        transfer.saveBytes(
          'large.txt',
          Uint8List(1024 * 1024),
          'text/plain',
          cancellation: token,
          validate: guard.check,
        ),
        throwsA(isA<RequestCancelled>()),
      );
      expect(fullChecks, 1);
      expect(afterSelection, 6);
      expect(await target.exists(), isFalse);
      expect(root().listSync(), isEmpty);
    },
  );

  test(
    'changed risk generation blocks publish even without a notification',
    () async {
      final target = File(p.join(root().path, 'large.txt'));
      final token = CancellationToken();
      var revision = 1;
      final initialRevision = revision;
      final guard = BookExportValidation(
        cancellation: token,
        validateContent: () {},
        validateState: () {
          if (revision != initialRevision) throw StateError('risk changed');
        },
      );
      final transfer = ProtectedBookExport(
        android: false,
        chooseLocation: (_) async {
          revision++;
          return target.path;
        },
        temporaryDirectory: () async => root(),
      );
      await expectLater(
        transfer.saveBytes(
          'large.txt',
          Uint8List(256 * 1024),
          'text/plain',
          cancellation: token,
          validate: guard.check,
        ),
        throwsStateError,
      );
      expect(await target.exists(), isFalse);
      expect(root().listSync(), isEmpty);
    },
  );
}

void androidExportTests(Directory Function() root) {
  const channel = MethodChannel('test/protected-book-export');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'cancelling an open picker never starts writing and requests cleanup',
    () async {
      final source = File(p.join(root().path, 'source'))
        ..writeAsStringSync('book');
      final choice = Completer<bool>();
      final entered = Completer<void>();
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        if (call.method == 'chooseProtectedBookExport') {
          entered.complete();
          return choice.future;
        }
        if (call.method == 'finishProtectedBookExport') {
          expect((call.arguments as Map)['commit'], isFalse);
          return false;
        }
        return null;
      });
      final token = CancellationToken();
      final operation = ProtectedBookExport(android: true, channel: channel)
          .saveFile(
            source,
            'book.txt',
            'text/plain',
            cancellation: token,
            validate: () {},
          );
      await entered.future;
      token.cancel();
      choice.complete(true);
      await expectLater(operation, throwsA(isA<RequestCancelled>()));
      expect(methods, contains('cancelProtectedBookExport'));
      expect(methods, contains('finishProtectedBookExport'));
      expect(methods, isNot(contains('writeProtectedBookExport')));
    },
  );

  test(
    'policy change while writing cancels native work and refuses commit',
    () async {
      final source = File(p.join(root().path, 'source'))
        ..writeAsStringSync('book');
      final writing = Completer<void>();
      final release = Completer<void>();
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        if (call.method == 'chooseProtectedBookExport') return true;
        if (call.method == 'writeProtectedBookExport') {
          writing.complete();
          await release.future;
          return null;
        }
        if (call.method == 'finishProtectedBookExport') {
          expect((call.arguments as Map)['commit'], isFalse);
          return false;
        }
        return null;
      });
      final token = CancellationToken();
      final operation = ProtectedBookExport(android: true, channel: channel)
          .saveFile(
            source,
            'book.txt',
            'text/plain',
            cancellation: token,
            validate: () {},
          );
      await writing.future;
      token.cancel();
      release.complete();
      await expectLater(operation, throwsA(isA<BookExportInterrupted>()));
      expect(methods, contains('cancelProtectedBookExport'));
      expect(methods, contains('finishProtectedBookExport'));
    },
  );

  test('failed cleanup reports a possibly remaining document', () async {
    final source = File(p.join(root().path, 'source'))
      ..writeAsStringSync('book');
    final token = CancellationToken();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'chooseProtectedBookExport') {
        token.cancel();
        return true;
      }
      if (call.method == 'finishProtectedBookExport') {
        throw PlatformException(code: 'protected_cleanup_failed');
      }
      return null;
    });
    await expectLater(
      ProtectedBookExport(android: true, channel: channel).saveFile(
        source,
        'book.txt',
        'text/plain',
        cancellation: token,
        validate: () {},
      ),
      throwsA(isA<BookExportCleanupFailure>()),
    );
  });

  test('post-selection policy failure never starts Android writing', () async {
    final source = File(p.join(root().path, 'source'))
      ..writeAsStringSync('book');
    var allowed = true;
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'chooseProtectedBookExport') {
        allowed = false;
        return true;
      }
      if (call.method == 'finishProtectedBookExport') {
        expect((call.arguments as Map)['commit'], isFalse);
        return false;
      }
      return null;
    });
    await expectLater(
      ProtectedBookExport(android: true, channel: channel).saveFile(
        source,
        'book.txt',
        'text/plain',
        cancellation: CancellationToken(),
        validate: () {
          if (!allowed) throw StateError('policy changed');
        },
      ),
      throwsStateError,
    );
    expect(methods, contains('finishProtectedBookExport'));
    expect(methods, isNot(contains('writeProtectedBookExport')));
  });

  test(
    'Android commits only after the native write and final policy check',
    () async {
      final source = File(p.join(root().path, 'source'))
        ..writeAsStringSync('book');
      var validations = 0;
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        if (call.method == 'chooseProtectedBookExport') return true;
        if (call.method == 'finishProtectedBookExport') {
          expect((call.arguments as Map)['commit'], isTrue);
          expect(validations, greaterThanOrEqualTo(3));
          return true;
        }
        return null;
      });
      await ProtectedBookExport(android: true, channel: channel).saveFile(
        source,
        'book.txt',
        'text/plain',
        cancellation: CancellationToken(),
        validate: () => validations++,
      );
      expect(methods, [
        'chooseProtectedBookExport',
        'writeProtectedBookExport',
        'finishProtectedBookExport',
      ]);
    },
  );
}
