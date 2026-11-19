import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../network/cancellation_token.dart';
import 'publish_file.dart';

typedef BookExportLocation = Future<String?> Function(String name);

/// Validate immutable content once, then check only the live policy lease.
final class BookExportValidation {
  BookExportValidation({
    required this.cancellation,
    required void Function() validateContent,
    required this.validateState,
  }) {
    cancellation.check();
    validateContent();
    check();
  }

  final CancellationToken cancellation;
  final void Function() validateState;

  void check() {
    cancellation.check();
    validateState();
    cancellation.check();
  }
}

/// A failed cleanup may leave a partially written document at the destination.
final class BookExportCleanupFailure implements Exception {
  const BookExportCleanupFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A document provider may have already received or buffered bytes.
final class BookExportInterrupted implements Exception {
  const BookExportInterrupted();
  String get message => '导出已中止；已写出的数据和文档服务商缓存无法撤回';
}

/// Cancellable two-phase saving for policy-sensitive book and video exports.
final class ProtectedBookExport {
  ProtectedBookExport({
    bool? android,
    BookExportLocation? chooseLocation,
    Future<Directory> Function()? temporaryDirectory,
    MethodChannel? channel,
  }) : _android = android ?? Platform.isAndroid,
       _chooseLocation = chooseLocation ?? _defaultLocation,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _channel = channel ?? const MethodChannel('zero_player/platform');

  final bool _android;
  final BookExportLocation _chooseLocation;
  final Future<Directory> Function() _temporaryDirectory;
  final MethodChannel _channel;
  static const _chunkSize = 64 * 1024;
  static int _serial = 0;

  static Future<String?> _defaultLocation(String name) async =>
      (await getSaveLocation(suggestedName: name))?.path;

  void _check(CancellationToken token, void Function() validate) {
    token.check();
    validate();
    token.check();
  }

  Future<void> saveText(
    String name,
    String text, {
    required CancellationToken cancellation,
    required void Function() validate,
  }) async {
    _check(cancellation, validate);
    final bytes = utf8.encode(text);
    _check(cancellation, validate);
    await saveBytes(
      name,
      bytes,
      'text/plain',
      cancellation: cancellation,
      validate: validate,
    );
  }

  Future<void> saveBytes(
    String name,
    List<int> bytes,
    String mime, {
    required CancellationToken cancellation,
    required void Function() validate,
  }) async {
    _check(cancellation, validate);
    final directory = await (await _temporaryDirectory()).createTemp(
      'zero-book-export-',
    );
    try {
      final file = File(p.join(directory.path, 'source'));
      final output = await file.open(mode: FileMode.writeOnly);
      try {
        for (var start = 0; start < bytes.length; start += _chunkSize) {
          _check(cancellation, validate);
          final end = (start + _chunkSize).clamp(0, bytes.length);
          await output.writeFrom(bytes, start, end);
        }
        _check(cancellation, validate);
        await output.flush();
      } finally {
        await output.close();
      }
      _check(cancellation, validate);
      await saveFile(
        file,
        name,
        mime,
        cancellation: cancellation,
        validate: validate,
      );
    } finally {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        throw BookExportCleanupFailure(
          _android
              ? '导出清理失败，应用缓存或目标位置可能有残留；服务商已接收的数据无法撤回'
              : '导出临时文件清理失败，应用缓存中可能有残留',
        );
      }
    }
  }

  Future<void> saveFile(
    File file,
    String name,
    String mime, {
    required CancellationToken cancellation,
    required void Function() validate,
  }) async {
    _check(cancellation, validate);
    if (_android) {
      await _saveAndroid(file, name, mime, cancellation, validate);
    } else {
      if (!Platform.isWindows) {
        throw UnsupportedError('受保护的导出仅支持 Windows 和 Android');
      }
      await _saveDesktop(file, name, cancellation, validate);
    }
  }

  Future<void> _saveDesktop(
    File file,
    String name,
    CancellationToken token,
    void Function() validate,
  ) async {
    final destination = await _chooseLocation(name);
    _check(token, validate);
    if (destination == null) throw StateError('已取消保存');
    final target = File(destination);
    final directory = await target.parent.createTemp('.zero-book-export-');
    try {
      final temporary = File(p.join(directory.path, 'content'));
      await _copyChecked(file, temporary, token, validate);
      _check(token, validate);
      try {
        await publishFile(temporary, target);
      } on FileSystemException {
        throw const FormatException('无法保存，目标可能已存在或目录不可写；请选择其他名称');
      }
    } finally {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        throw const BookExportCleanupFailure('导出临时文件清理失败，目标文件夹中可能有残留');
      }
    }
  }

  Future<void> _copyChecked(
    File source,
    File target,
    CancellationToken token,
    void Function() validate,
  ) async {
    final input = await source.open();
    try {
      final output = await target.open(mode: FileMode.writeOnly);
      try {
        while (true) {
          _check(token, validate);
          final chunk = await input.read(_chunkSize);
          _check(token, validate);
          if (chunk.isEmpty) break;
          await output.writeFrom(chunk);
        }
        _check(token, validate);
        await output.flush();
      } finally {
        await output.close();
      }
    } finally {
      await input.close();
    }
  }

  Future<void> _saveAndroid(
    File file,
    String name,
    String mime,
    CancellationToken token,
    void Function() validate,
  ) async {
    final id = '${DateTime.now().microsecondsSinceEpoch}-${_serial++}';
    Future<void>? cancellation;
    Object? cancellationError;
    final unlisten = token.listen(() {
      cancellation = _channel
          .invokeMethod<void>('cancelProtectedBookExport', {'id': id})
          .catchError((Object error) {
            cancellationError = error;
          });
    });
    var prepared = false;
    var committed = false;
    var writeStarted = false;
    try {
      _check(token, validate);
      prepared = true;
      final bool? selected;
      try {
        selected = await _channel.invokeMethod<bool>(
          'chooseProtectedBookExport',
          {'id': id, 'name': name, 'mime': mime},
        );
      } on PlatformException catch (error) {
        if (error.code == 'protected_busy' ||
            error.code == 'protected_picker_failed') {
          prepared = false;
        }
        rethrow;
      }
      _check(token, validate);
      if (selected != true) throw StateError('已取消保存');
      writeStarted = true;
      await _channel.invokeMethod<void>('writeProtectedBookExport', {
        'id': id,
        'path': file.path,
      });
      _check(token, validate);
      committed = true;
    } catch (_) {
      if (writeStarted) throw const BookExportInterrupted();
      rethrow;
    } finally {
      try {
        if (prepared) {
          try {
            if (cancellation != null) await cancellation;
            final kept = await _channel.invokeMethod<bool>(
              'finishProtectedBookExport',
              {'id': id, 'commit': committed},
            );
            if (committed && kept != true) throw const BookExportInterrupted();
            if (cancellationError != null) throw cancellationError!;
          } on PlatformException catch (error) {
            if (error.code == 'protected_cleanup_failed') {
              throw const BookExportCleanupFailure(
                '导出已中止，目标位置可能有残留；已写出的数据和文档服务商缓存无法撤回',
              );
            }
            rethrow;
          }
        }
      } finally {
        unlisten();
      }
    }
  }
}
