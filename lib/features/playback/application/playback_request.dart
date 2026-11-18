import '../../../media/gateway/offline_server.dart';
import '../../catalog/domain/catalog_item.dart';

enum PlaybackMediaKind { online, live, downloaded, local }

final class PlaybackRequest {
  const PlaybackRequest(
    this.item, {
    this.line = 0,
    this.episode = 0,
    this.position = Duration.zero,
    this.live = false,
    this.headers = const {},
    this.headersByUri = const {},
    this.offline,
    this.quality,
    this.mediaKind,
  });
  final CatalogItem item;
  final int line;
  final int episode;
  final Duration position;
  final bool live;
  final Map<String, String> headers;
  final Map<Uri, Map<String, String>> headersByUri;
  final OfflineSession? offline;
  final Uri? quality;
  final PlaybackMediaKind? mediaKind;
  PlaybackMediaKind get kind =>
      mediaKind ??
      (live
          ? PlaybackMediaKind.live
          : offline == null
          ? PlaybackMediaKind.online
          : item.sourceId == 'local'
          ? PlaybackMediaKind.local
          : PlaybackMediaKind.downloaded);
  bool get supportsMarks =>
      kind == PlaybackMediaKind.online && !live && offline == null;
}
