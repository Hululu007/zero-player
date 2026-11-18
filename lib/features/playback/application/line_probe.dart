import '../../../core/network/cancellation_token.dart';
import '../../../core/network/document_client.dart';
import '../../../core/network/header_policy.dart';
import '../../../core/network/media_http_client.dart';
import '../../../media/network/media_probe.dart';
import '../../catalog/domain/catalog_item.dart';
import '../../catalog/data/provider_factory.dart';
import '../../sources/domain/video_source.dart';
import '../../supervision/application/content_policy.dart';
import '../../supervision/domain/supervision_rules.dart';

/// Resolves and checks an episode using the shared controlled network clients.
/// The caller owns those clients; each invocation owns only its cancellation.
final class EpisodeProbe {
  const EpisodeProbe({
    required this.findSource,
    required this.network,
    required this.http,
    required this.policy,
  });

  final Future<VideoSource?> Function(String) findSource;
  final DocumentClient network;
  final MediaHttpClient http;
  final ContentPolicy policy;

  Future<ProbeResult> probe(
    CatalogItem item,
    Episode episode,
    CancellationToken token,
  ) async {
    final local = CancellationToken();
    final unlink = token.listen(local.cancel);
    VideoSource? source;
    bool allowed() =>
        policy.itemAllowed(item) &&
        (source == null || policy.sourceAllowed(source));
    void requireAllowed() {
      token.check();
      if (!allowed()) throw const ContentBlocked();
      local.check();
    }

    void policyChanged() {
      if (!allowed()) local.cancel();
    }

    policy.addListener(policyChanged);
    try {
      requireAllowed();
      if (!episode.playable) throw const FormatException('此地址无法直接播放');
      source = await findSource(item.sourceId);
      requireAllowed();
      final active = source;
      if (active == null || !active.available) {
        throw const FormatException('来源不可用');
      }
      var uri = episode.uri;
      var headers = HeaderPolicy.scopedHeaders(
        active.endpoint,
        uri,
        active.headers,
      );
      if (episode.requiresResolution) {
        final media = await createVodProvider(
          active,
          network,
          cancellation: local,
          policy: policy,
        ).resolve(episode);
        uri = media.uri;
        headers = media.headers;
      }
      requireAllowed();
      final result = await probeMedia(
        http,
        uri,
        HeaderPolicy({uri: headers}),
        local,
        maxBytes: 256 * 1024,
        availabilityOnly: true,
      );
      requireAllowed();
      return result;
    } on RequestCancelled {
      token.check();
      if (!allowed()) throw const ContentBlocked();
      rethrow;
    } finally {
      policy.removeListener(policyChanged);
      unlink();
    }
  }
}
