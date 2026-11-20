import 'dart:async';
import 'dart:convert';

import '../../core/network/cancellation_token.dart';
import '../../core/network/header_policy.dart';
import '../../core/network/media_http_client.dart';

/// Classifies extensionless media without retaining the probe response.
Future<bool> probeHls(
  MediaHttpClient client,
  Uri uri,
  HeaderPolicy policy,
  CancellationToken cancellation,
) async {
  final probe = CancellationToken();
  final unlink = cancellation.listen(probe.cancel);
  final deadline = Timer(client.timeout, probe.cancel);
  const marker = '#EXTM3U';
  const limit = 512;
  final prefix = <int>[];
  try {
    final response = await client.open(
      uri,
      policy: policy,
      cancellation: probe,
    );
    await for (final chunk in response.body) {
      probe.check();
      prefix.addAll(chunk.take(limit - prefix.length));
      final text = utf8.decode(prefix, allowMalformed: true).trimLeft();
      if (text.startsWith(marker)) return true;
      // The last code point (including an optional BOM) may span chunks.
      final partial = text.endsWith('�')
          ? text.substring(0, text.length - 1)
          : text;
      if (prefix.length >= limit || !marker.startsWith(partial)) return false;
    }
    probe.check();
    return false;
  } on RequestCancelled {
    cancellation.check();
    throw const FormatException('媒体类型探测超时，请重试或切换线路');
  } finally {
    deadline.cancel();
    unlink();
  }
}
