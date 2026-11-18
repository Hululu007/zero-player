import 'dart:convert';
import '../../sources/domain/video_source.dart';
import '../domain/channel_identity.dart';
import '../domain/live_channel.dart';
import 'channel_urls.dart';

String channelHeaderKey(Map<String, String> headers) => jsonEncode({
  for (final key in headers.keys.toList()..sort())
    key.toLowerCase(): headers[key],
});

/// Preserve stored preferences when a publisher changes CCTV display names.
List<LiveChannel> preparePlaylistChannels(
  List<LiveChannel> channels,
  List<Map<String, Object?>> previous,
  Map<String, String> listHeaders,
) {
  final old = <String, String>{};
  final oldNames = <String, Set<String>>{};
  for (final row in previous) {
    try {
      final headers = Map<String, String>.from(
        jsonDecode(row['headers'] as String),
      );
      old.putIfAbsent(
        '${channelIdentity(row['name'] as String)}|${channelHeaderKey(headers)}',
        () => row['id'] as String,
      );
    } on FormatException {
      // A fresh import repairs the damaged payload; retain unique identity.
    } on TypeError {
      // Do not allow one damaged previous header record to block an update.
    }
    oldNames
        .putIfAbsent(channelIdentity(row['name'] as String), () => {})
        .add(row['id'] as String);
  }
  final variants = <String, Set<String>>{};
  for (final channel in channels) {
    variants
        .putIfAbsent(channelIdentity(channel.name), () => {})
        .add(channelHeaderKey({...listHeaders, ...channel.headers}));
  }
  final result = <String, LiveChannel>{};
  for (final channel in channels) {
    final headers = {...listHeaders, ...channel.headers};
    final key = '${channelIdentity(channel.name)}|${channelHeaderKey(headers)}';
    final name = channelIdentity(channel.name);
    // Header variants remain separate. A unique channel can retain its user's
    // identity when its publisher rotates headers; preflight still revalidates.
    final previousIds = oldNames[name];
    final rotatedId = variants[name]?.length == 1 && previousIds?.length == 1
        ? previousIds!.single
        : null;
    final first = result[key];
    final id =
        first?.id ??
        old[key] ??
        rotatedId ??
        (cctvIdentity(channel.name) == null
            ? channel.id
            : stableId('${channel.listId}|$key'));
    result[key] = LiveChannel(
      id: id,
      listId: channel.listId,
      name: channelDisplayName(channel.name),
      group: first?.group ?? channel.group,
      logo: first?.logo.isNotEmpty == true ? first!.logo : channel.logo,
      tvgId: first?.tvgId.isNotEmpty == true ? first!.tvgId : channel.tvgId,
      urls: appendChannelUrls(first?.urls ?? [], channel.urls),
      headers: headers,
      metadata: channel.metadata,
    );
  }
  return result.values.toList();
}
