import 'dart:io';
import 'package:path/path.dart' as p;
import '../../../media/gateway/offline_server.dart';
import '../../library/data/history_repository.dart';
import '../../../core/platform/video_files.dart';
import '../../catalog/domain/catalog_item.dart';
import '../../sources/domain/video_source.dart';
import 'playback_request.dart';

final class LocalVideo {
  const LocalVideo({
    required this.requireItem,
    required this.latestHistory,
    required this.openFile,
    required this.rememberPath,
  });

  final void Function(CatalogItem) requireItem;
  final Future<WatchEntry?> Function(String) latestHistory;
  final Future<OfflineSession> Function(File) openFile;
  final Future<void> Function(String, String) rememberPath;

  Future<PlaybackRequest> open(
    String path, {
    String? previousId,
    String? documentIdentity,
  }) async {
    if (!isLocalVideo(path)) throw const FormatException('请选择受支持的视频文件');
    final file = File(path);
    if (!await file.exists()) throw const FileSystemException('视频文件不存在或已移动');
    final canonical = await file.resolveSymbolicLinks();
    final id =
        (documentIdentity == null ? previousId : null) ??
        stableId(
          documentIdentity == null
              ? canonical
              : 'android-document:$documentIdentity',
        );
    final item = CatalogItem(
      sourceId: 'local',
      id: id,
      title: p.basename(path),
    );
    // Local files follow the same title and supervision boundary as online items.
    requireItem(item);
    final previous = await latestHistory(id);
    requireItem(item);
    final session = await openFile(File(canonical));
    try {
      requireItem(item);
      await rememberPath(id, canonical);
      requireItem(item);
    } catch (_) {
      session.close();
      rethrow;
    }
    return PlaybackRequest(
      CatalogItem(
        sourceId: 'local',
        id: id,
        title: item.title,
        lines: [
          PlayLine('本地视频', [Episode(item.title, session.uri)]),
        ],
      ),
      position:
          previous != null &&
              previous.position < previous.duration - const Duration(seconds: 5)
          ? previous.position
          : Duration.zero,
      offline: session,
      mediaKind: PlaybackMediaKind.local,
    );
  }
}
