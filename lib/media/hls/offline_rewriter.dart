import 'hls_manifest.dart';

typedef ResourceResolver =
    Future<Uri> Function(Uri uri, {String? range, bool playlist});

/// Converts ranges into independent complete files; their original BYTERANGE
/// declarations must not be retained or offsets would be applied twice.
Future<String> rewriteOffline(
  HlsManifest manifest,
  ResourceResolver resolve,
) async {
  final output = <String>[];
  String? range;
  final ends = <Uri, int>{};
  final playlists = manifest.playlistUris;
  for (final raw in manifest.lines) {
    final line = raw.trim();
    if (line.startsWith('#EXT-X-BYTERANGE:')) {
      range = line.substring(17);
      continue;
    }
    if ((line.startsWith('#EXT-X-KEY:') ||
            line.startsWith('#EXT-X-SESSION-KEY:')) &&
        !line.contains('METHOD=NONE') &&
        !line.contains('METHOD=AES-128')) {
      throw const FormatException('此加密方式暂不支持离线下载');
    }
    if (line.isNotEmpty && !line.startsWith('#')) {
      final uri = manifest.baseUri.resolve(line);
      final target = await resolve(
        uri,
        range: _byteRange(range, uri, ends),
        playlist: playlists.contains(uri),
      );
      output.add(target.toString());
      range = null;
      continue;
    }
    final uriMatch = RegExp(r'([:,]\s*)URI="([^"]+)"').firstMatch(line);
    if (uriMatch == null) {
      output.add(raw);
      continue;
    }
    final key =
        line.startsWith('#EXT-X-KEY:') ||
        line.startsWith('#EXT-X-SESSION-KEY:');
    final uri = manifest.resolveResource(uriMatch[2]!, key: key);
    if (key && uri.scheme == 'data') {
      output.add(raw);
      continue;
    }
    if (key && uri.scheme == 'skd') {
      throw const FormatException('DRM 密钥不支持离线下载');
    }
    final rangeMatch = RegExp(r',\s*BYTERANGE="([^"]+)"').firstMatch(line);
    final target = await resolve(
      uri,
      range: _byteRange(rangeMatch?[1], uri, ends),
      playlist: playlists.contains(uri),
    );
    var rewritten = line.replaceRange(
      uriMatch.start,
      uriMatch.end,
      '${uriMatch[1]}URI="$target"',
    );
    rewritten = rewritten.replaceAll(RegExp(r',\s*BYTERANGE="[^"]+"'), '');
    output.add(rewritten);
  }
  return output.join('\n');
}

String? _byteRange(String? value, Uri uri, Map<Uri, int> ends) {
  if (value == null) return null;
  final match = RegExp(r'^(\d+)(?:@(\d+))?$').firstMatch(value);
  if (match == null) throw const FormatException('无效的 HLS 字节范围');
  final length = int.parse(match[1]!);
  final start = match[2] == null ? ends[uri] : int.parse(match[2]!);
  if (start == null || length <= 0) {
    throw const FormatException('缺少 HLS 字节范围起点');
  }
  ends[uri] = start + length;
  return 'bytes=$start-${start + length - 1}';
}

/// Freeze one variant and one default rendition per group for an offline job.
HlsManifest selectOfflineVariant(HlsManifest manifest) {
  if (!manifest.isMaster) return manifest;
  final output = <String>['#EXTM3U'];
  final groups = <(String, String), List<String>>{};
  String? variant;
  String? address;
  for (final line in manifest.lines) {
    if (line.startsWith('#EXT-X-MEDIA:')) {
      final attributes = _attributes(line);
      final type = attributes['TYPE'];
      final group = attributes['GROUP-ID'];
      if (type != null && group != null) {
        groups.putIfAbsent((type, group), () => []).add(line);
      }
    } else if (line.startsWith('#EXT-X-STREAM-INF:') && variant == null) {
      variant = line;
    } else if (variant != null &&
        address == null &&
        line.isNotEmpty &&
        !line.startsWith('#')) {
      address = line;
    }
  }
  if (variant == null || address == null) {
    throw const FormatException('主清单没有播放变体');
  }
  final references = _attributes(variant);
  for (final group in groups.entries) {
    if (references[group.key.$1] != group.key.$2) continue;
    output.add(
      group.value.firstWhere(
        (line) => _attributes(line)['DEFAULT'] == 'YES',
        orElse: () => group.value.first,
      ),
    );
  }
  output
    ..add(variant)
    ..add(address);
  return HlsManifest.parse(
    output.join('\n'),
    manifest.baseUri,
    variables: manifest.variables,
  );
}

Map<String, String> _attributes(String line) => {
  for (final match in RegExp(
    r'(?:^|[:,])\s*([A-Z0-9-]+)=(?:"([^"]*)"|([^,]*))',
  ).allMatches(line))
    match[1]!: match[2] ?? match[3]!,
};
