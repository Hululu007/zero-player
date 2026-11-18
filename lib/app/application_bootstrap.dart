import '../core/persistence/local_open_channel.dart';
import 'local_open_startup.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app_services.dart';
import 'startup_failure.dart';
import 'product_app.dart';
import 'installation_introduction.dart';
import '../core/persistence/application_ownership.dart';

/// Retries service construction without registering global bindings again.
final class ApplicationBootstrap extends StatefulWidget {
  const ApplicationBootstrap({
    super.key,
    this.createServices = AppServices.create,
    this.exitApplication = _exitApplication,
  });
  final Future<AppServices> Function() createServices;
  final Future<void> Function() exitApplication;
  @override
  State<ApplicationBootstrap> createState() => _ApplicationBootstrapState();
}

final class _ApplicationBootstrapState extends State<ApplicationBootstrap> {
  late Future<AppServices> _startup = _start();
  AppServices? _services;
  bool _starting = false;
  int _generation = 0;

  Future<AppServices> _start() {
    _starting = true;
    final generation = ++_generation;
    final startup = _create(generation).whenComplete(() {
      if (generation == _generation) _starting = false;
    });
    // A retry can fail before the next frame subscribes its FutureBuilder.
    // Observe it immediately while preserving the error for the error page.
    unawaited(startup.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    return startup;
  }

  Future<AppServices> _create(int generation) async {
    final AppServices services;
    try {
      services = await widget.createServices();
    } on ApplicationAlreadyRunning catch (error) {
      if (!mounted || generation != _generation) rethrow;
      final path = LocalOpenStartup.path;
      if (error.directory != null &&
          path != null &&
          await LocalOpenChannel.forward(error.directory!, path)) {
        LocalOpenStartup.path = null;
        await windowManager.destroy();
      }
      rethrow;
    }
    if (!mounted || generation != _generation) {
      await services.closeSafely();
    } else {
      _services = services;
    }
    return services;
  }

  @override
  void dispose() {
    _generation++;
    final services = _services;
    if (services != null) unawaited(services.closeSafely());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AppServices>(
    future: _startup,
    builder: (context, snapshot) {
      final completed = snapshot.connectionState == ConnectionState.done;
      if (completed && snapshot.hasData) {
        return ProviderScope(
          overrides: [servicesProvider.overrideWithValue(snapshot.data!)],
          child: InstallationIntroduction(
            services: snapshot.data!,
            child: const ProductApp(),
          ),
        );
      }
      return MaterialApp(
        home: Scaffold(
          body: Center(
            child: completed && snapshot.hasError
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        snapshot.error is ApplicationRestartRequired
                            ? '初始化后的资源未能安全关闭，请完全退出播放器后重新打开。'
                            : snapshot.error is ApplicationAlreadyRunning
                            ? '播放器已在运行，请在现有窗口打开视频；关闭后可重试。'
                            : '无法初始化本地数据，请检查可用空间后重试',
                      ),
                      if (snapshot.error is! ApplicationRestartRequired)
                        FilledButton(
                          onPressed: _starting
                              ? null
                              : () {
                                  if (_starting) return;
                                  setState(() {
                                    _startup = _start();
                                  });
                                },
                          child: const Text('重试'),
                        )
                      else
                        FilledButton(
                          onPressed: widget.exitApplication,
                          child: const Text('退出'),
                        ),
                    ],
                  )
                : const CircularProgressIndicator(),
          ),
        ),
      );
    },
  );
}

Future<void> _exitApplication() async {
  if (Platform.isWindows) {
    await windowManager.destroy();
  } else {
    await SystemNavigator.pop();
    // Removing the Android activity alone retains the unsafe service owner.
    exit(0);
  }
}
