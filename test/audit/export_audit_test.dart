import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:ffmpeg_kit_flutter_new_min/abstract_session.dart';
import 'package:ffmpeg_kit_flutter_new_min/media_information.dart';
import 'package:ffmpeg_kit_flutter_new_min/src/ffmpeg_kit_factory.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/catalog/domain/catalog_item.dart';
import 'package:zero_player/features/downloads/presentation/downloads_page.dart';
import 'package:zero_player/features/sources/domain/video_source.dart';
import 'package:zero_player/media/export/ffmpeg_exporter.dart';
import 'package:zero_player/media/export/media_exporter.dart';

// Native encoding and the OS picker are controlled; production Dart export code runs.
Future<void> Function()? duringProbe;
void Function(int)? duringCancel;
final messenger =
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
final commands = <int, List<String>>{};
var sequence = 0;
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _configureNative();
  _probeStopTests();
  _cancelTest();
  _raceTest();
  _policyTest();
}

void _configureNative() {
  setUpAll(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter.arthenica.com/ffmpeg_kit_event'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter.arthenica.com/ffmpeg_kit'),
      (call) async {
        switch (call.method) {
          case 'getLogLevel':
            return 16;
          case 'getPlatform':
            return 'windows';
          case 'getArch':
            return 'x86_64';
          case 'getPackageName':
            return 'min';
          case 'isLTSBuild':
            return false;
          case 'ffmpegSession':
            final args = List<String>.from(
              (call.arguments as Map)['arguments'],
            );
            commands[++sequence] = args;
            await File(args.last).writeAsBytes([11, 22, 33, 44]);
            return {'sessionId': sequence, 'command': args.join(' ')};
          case 'mediaInformationSession':
            return {'sessionId': ++sequence};
          case 'asyncFFmpegSessionExecute':
            final id = (call.arguments as Map)['sessionId'] as int;
            scheduleMicrotask(() {
              final session = AbstractSession.createFFmpegSessionFromMap({
                'sessionId': id,
                'command': commands[id]!.join(' '),
              });
              FFmpegKitFactory.getFFmpegSessionCompleteCallback(id)!(session);
            });
            return null;
          case 'abstractSessionGetReturnCode':
            return 0;
          case 'asyncMediaInformationSessionExecute':
            final id = (call.arguments as Map)['sessionId'] as int;
            scheduleMicrotask(() async {
              await duringProbe?.call();
              final session =
                  AbstractSession.createMediaInformationSessionFromMap({
                    'sessionId': id,
                    'command': 'probe',
                  });
              session.setMediaInformation(
                MediaInformation({
                  'format': {'duration': '1'},
                  'streams': [
                    {'codec_type': 'video'},
                  ],
                }),
              );
              FFmpegKitFactory.getMediaInformationSessionCompleteCallback(id)!(
                session,
              );
            });
            return null;
          case 'cancelSession':
            duringCancel?.call((call.arguments as Map)['sessionId'] as int);
            return null;
          case 'getMediaInformation':
            return {
              'format': {'duration': '1'},
              'streams': [
                {'codec_type': 'video'},
              ],
            };
          default:
            return null;
        }
      },
    );
  });
}

void _probeStopTests() {
  for (final timeout in [false, true]) {
    test(
      'AUD-10 ${timeout ? 'deadline' : 'cancellation'} stops and joins a slow native probe',
      () async {
        final root = await Directory.systemTemp.createTemp('audit-slow-probe-');
        final entered = Completer<void>();
        final stopped = Completer<void>();
        final token = CancellationToken();
        int? cancelledId;
        duringProbe = () async {
          entered.complete();
          await stopped.future;
        };
        duringCancel = (id) {
          cancelledId = id;
          if (!stopped.isCompleted) stopped.complete();
        };
        try {
          final output = File('${root.path}/output.mp4');
          final operation =
              FfmpegExporter(
                probeTimeout: timeout
                    ? const Duration(milliseconds: 30)
                    : const Duration(seconds: 5),
              ).export(
                Uri.file('${root.path}/input.mp4'),
                output.path,
                ExportFormat.mp4,
                cancellation: token,
              );
          final check = expectLater(
            operation,
            throwsA(
              timeout ? isA<TimeoutException>() : isA<RequestCancelled>(),
            ),
          );
          await entered.future;
          if (!timeout) token.cancel();
          await check;
          expect(cancelledId, isNotNull);
          expect(stopped.isCompleted, isTrue);
          expect(await output.exists(), isFalse);
          expect(await root.list().toList(), isEmpty);
        } finally {
          duringProbe = null;
          duringCancel = null;
          if (!stopped.isCompleted) stopped.complete();
          await root.delete(recursive: true);
        }
      },
    );
  }
}

void _cancelTest() {
  test(
    'AUD-10 cancellation during probe prevents exporter publication',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'audit-export-cancel-',
      );
      addTearDown(() async {
        duringProbe = null;
        await root.delete(recursive: true);
      });
      final token = CancellationToken();
      duringProbe = () async {
        token.cancel();
      };
      final output = File('${root.path}/output.mp4');
      final result = FfmpegExporter().export(
        Uri.file('${root.path}/input.mp4'),
        output.path,
        ExportFormat.mp4,
        cancellation: token,
      );
      await expectLater(result, throwsA(isA<RequestCancelled>()));
      expect(await output.exists(), isFalse);
    },
  );
}

void _raceTest() {
  test(
    'AUD-12 exporter publication cannot replace a file created after existence check',
    () async {
      final root = await Directory.systemTemp.createTemp('audit-export-race-');
      addTearDown(() async {
        duringProbe = null;
        await root.delete(recursive: true);
      });
      duringProbe = null;
      final target = File('${root.path}/output.mp4').absolute;
      final guarded = _RaceTarget(target);
      final parentZone = Zone.current;
      await IOOverrides.runZoned(
        () async {
          await expectLater(
            FfmpegExporter().export(
              Uri.file('${root.path}/input.mp4'),
              target.path,
              ExportFormat.mp4,
            ),
            throwsA(isA<FileSystemException>()),
          );
        },
        createFile: (path) =>
            path == target.path ? guarded : parentZone.run(() => File(path)),
      );
      expect(await target.readAsString(), 'COMPETING EXISTING FILE');
    },
  );
}

void _policyTest() {
  testWidgets(
    'AUD-11 policy revocation during export save picker prevents writing',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('audit-export-policy-'),
      ))!;
      final services = AppServices.scoped(root, AppDatabase.memory());
      final previousPicker = FileSelectorPlatform.instance;
      final picker = _SavePicker();
      FileSelectorPlatform.instance = picker;
      addTearDown(() async {
        FileSelectorPlatform.instance = previousPicker;
        duringProbe = null;
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await services.close();
          await root.delete(recursive: true);
        });
      });
      duringProbe = null;
      late String taskId;
      await tester.runAsync(() async {
        await services.settings.load();
        await services.supervision.load();
        services.contentPolicy.rememberSource(
          VideoSource(
            id: 'audit-source',
            name: 'Normal',
            endpoint: Uri.parse('https://example.com'),
          ),
        );
        final episode = Episode('EP1', Uri.parse('https://media.test/1.mp4'));
        final line = PlayLine('Line', [episode]);
        final item = CatalogItem(
          sourceId: 'audit-source',
          id: 'work',
          title: 'Movie',
          lines: [line],
        );
        taskId = await services.downloads.create(item, line, episode, {});
        final task = (await services.downloads.find(taskId))!;
        final bytes = [1, 2, 3, 4];
        await File('${task.directory}/video.mp4').writeAsBytes(bytes);
        await File('${task.directory}/integrity.json').writeAsString(
          jsonEncode({'bytes': 4, 'digest': sha256.convert(bytes).toString()}),
        );
        await services.downloads.complete(taskId, 'video.mp4');
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DownloadsPage(services: services)),
        ),
      );
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.runAsync(() => tester.tap(find.text('导出 MP4')));
      for (var i = 0; i < 30 && !picker.entered.isCompleted; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(picker.entered.isCompleted, isTrue);
      services.contentPolicy.rememberSource(
        VideoSource(
          id: 'audit-source',
          name: 'Classified',
          endpoint: Uri.parse('https://example.com'),
          classification: 'adult',
        ),
      );
      final allowed = await tester.runAsync(
        () async => services.downloads.allowed(
          (await services.downloads.find(taskId))!,
        ),
      );
      expect(allowed, isFalse);
      final destination = File('${root.path}/external-saved.mp4');
      picker.selection.complete(FileSaveLocation(destination.path));
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(await tester.runAsync(destination.exists), isFalse);
    },
  );
}

class _SavePicker extends FileSelectorPlatform {
  final entered = Completer<void>();
  final selection = Completer<FileSaveLocation?>();
  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) {
    entered.complete();
    return selection.future;
  }
}

class _RaceTarget implements File {
  _RaceTarget(this.file);
  final File file;
  int checks = 0;
  @override
  File get absolute => this;
  @override
  String get path => file.path;
  @override
  Directory get parent => file.parent;
  @override
  Future<int> length() => file.length();
  @override
  Future<bool> exists() async {
    final observed = await file.exists();
    if (++checks == 2 && !observed) {
      // Schedule the competing creation after observing absence and before rename.
      await file.writeAsString('COMPETING EXISTING FILE');
    }
    return observed;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
