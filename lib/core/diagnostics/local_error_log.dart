import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Keeps a small local ring of failure types and application stack locations.
final class LocalErrorLog {
  LocalErrorLog._();

  static File? _file;
  static final _records = <Map<String, Object>>[];
  static final _frame = RegExp(
    r'package:zero_player/[a-zA-Z0-9_/.]+:[0-9]+(?::[0-9]+)?',
  );
  static const _capacity = 32;

  static void attach(File file) {
    if (_file?.path == file.path) return;
    if (_file != null) _records.clear();
    _file = file;
    try {
      if (file.existsSync() && file.lengthSync() <= 128 * 1024) {
        final contents = jsonDecode(file.readAsStringSync());
        if (contents is List) {
          _records.insertAll(
            0,
            contents.whereType<Map<String, Object?>>().map(
              (entry) => entry.map((key, value) => MapEntry(key, value ?? '')),
            ),
          );
        }
      }
    } on Exception {
      // A damaged prior log never prevents startup.
    }
    _trim();
    if (_records.isNotEmpty) _save();
  }

  static void record(String origin, Object error, StackTrace? stack) {
    final frames = _frame
        .allMatches(stack?.toString() ?? '')
        .take(12)
        .map((match) => match.group(0)!)
        .toList();
    final type = error.runtimeType.toString();
    final last = _records.lastOrNull;
    if (last != null &&
        last['type'] == type &&
        last['origin'] == origin &&
        last['frames'] is List &&
        listEquals(last['frames'] as List, frames) &&
        last['time'] is int &&
        DateTime.now().millisecondsSinceEpoch - (last['time'] as int) < 1000) {
      return;
    }
    _records.add({
      'time': DateTime.now().millisecondsSinceEpoch,
      'origin': origin,
      'type': type,
      'frames': frames,
    });
    _trim();
    _save();
  }

  static String report() =>
      const JsonEncoder.withIndent('  ').convert(_records);

  static void _trim() {
    if (_records.length > _capacity) {
      _records.removeRange(0, _records.length - _capacity);
    }
  }

  static void _save() {
    try {
      _file?.writeAsStringSync(jsonEncode(_records), flush: true);
    } on FileSystemException {
      // Error reporting must remain non-fatal.
    }
  }
}
