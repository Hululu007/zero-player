import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Two bounded snapshots survive a native crash / system kill. A missed close
/// is evidence of an unclean exit, not a diagnosis of its cause.
final class PlaybackJournal {
  PlaybackJournal(Directory root)
    : current = File('${root.path}/playback-diagnostics/current.json'),
      previous = File('${root.path}/playback-diagnostics/previous.json');
  final File current, previous;
  String? previousReport;
  Future<void> _queue = Future.value();
  static final _owner =
      '$pid-${Random.secure().nextInt(1 << 32)}-${DateTime.now().microsecondsSinceEpoch}';

  bool _unclean(Map<String, dynamic>? snapshot) =>
      snapshot?['status'] == 'running' && snapshot?['owner'] != _owner;

  static const limit = 64 * 1024;

  Future<void> initialize() async {
    await current.parent.create(recursive: true);
    final old = await _read(current);
    if (_unclean(old)) {
      await previous.writeAsString(jsonEncode(old), flush: true);
    }
    final saved = await _read(previous);
    previousReport = saved?['report'] as String?;
  }

  Future<String?> latestUnclosedReport() async {
    final latest = await _read(current);
    if (_unclean(latest)) return latest?['report'] as String?;
    return (await _read(previous))?['report'] as String?;
  }

  Future<Map<String, dynamic>?> _read(File file) async {
    try {
      if (!await file.exists() || await file.length() > limit) return null;
      final value = jsonDecode(await file.readAsString());
      if (value is Map<String, dynamic> && value['report'] is String) {
        return value;
      }
    } catch (_) {
      /* An interrupted write or old diagnostic is expendable. */
    }
    return null;
  }

  Future<void> write(String report, {bool closed = false}) {
    // Reports contain at most 60 short events. Apply a final byte bound too.
    final snapshot = jsonEncode({
      'status': closed ? 'closed' : 'running',
      'owner': _owner,
      'savedAt': DateTime.now().toUtc().toIso8601String(),
      'report': report.length > 8000 ? report.substring(0, 8000) : report,
    });
    final operation = _queue.then((_) async {
      if (utf8.encode(snapshot).length > limit) return;
      final temporary = File('${current.path}.tmp');
      await temporary.writeAsString(snapshot, flush: true);
      await temporary.rename(current.path);
    });
    _queue = operation.catchError((Object _) {});
    return operation;
  }
}
