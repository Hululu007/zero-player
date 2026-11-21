import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'app/application_bootstrap.dart';
import 'app/local_open_startup.dart';
import 'core/diagnostics/local_error_log.dart';
import 'features/publications/application/publication_android_worker.dart';

@pragma('vm:entry-point')
Future<void> publicationBackgroundMain() => runPublicationAndroidWorker();

Future<void> main(List<String> args) async {
  if (args.isNotEmpty) LocalOpenStartup.path = args.first;
  WidgetsFlutterBinding.ensureInitialized();
  final previousFlutterError = FlutterError.onError;
  FlutterError.onError = (details) {
    LocalErrorLog.record('flutter', details.exception, details.stack);
    previousFlutterError?.call(details);
  };
  final dispatcher = PlatformDispatcher.instance;
  final previousUnhandledError = dispatcher.onError;
  dispatcher.onError = (error, stack) {
    LocalErrorLog.record('dart', error, stack);
    return previousUnhandledError?.call(error, stack) ?? false;
  };
  MediaKit.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Xiaolai',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  LicenseRegistry.addLicense(() async* {
    final attribution = await rootBundle.loadString(
      'assets/licenses/CONTENT-FILTER-NOTICE.txt',
    );
    for (final entry in const {
      'SenseVoiceSmall / sherpa-onnx conversion': 'FunASR-MODEL-LICENSE.txt',
      'PP-OCRv4 / RapidOCR': 'RapidOCR-LICENSE.txt',
    }.entries) {
      final license = await rootBundle.loadString(
        'assets/licenses/${entry.value}',
      );
      yield LicenseEntryWithLineBreaks([entry.key], '$attribution\n\n$license');
    }
  });
  runApp(const ApplicationBootstrap());
}
