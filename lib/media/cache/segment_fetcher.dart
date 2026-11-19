import 'dart:io';
import '../../core/network/cancellation_token.dart';
import '../../core/network/header_policy.dart';
import '../../core/network/media_http_client.dart';
import '../../core/network/request_scheduler.dart';
import 'resource_identity.dart';
import 'segment_store.dart';

final class SegmentFetcher {
  const SegmentFetcher(this.store, this.http);
  final SegmentStore store;
  final MediaHttpClient http;

  Future<ResourceLease> fetch(
    Uri uri,
    HeaderPolicy policy, {
    String? range,
    bool verify = false,
    String? cachePartition,
    CancellationToken? cancellation,
    RequestPriority priority = RequestPriority.background,
  }) {
    if (cancellation != null && cachePartition == null) {
      throw ArgumentError('Cancellation requires a task-owned cache partition');
    }
    http.targetPolicy.validateAccess(
      uri,
      originalOrigin: policy.containsOrigin(uri),
    );
    final key = resourceIdentity(uri, {
      ...policy.identityHeaders,
      'zero-player-cache-partition': ?cachePartition,
    }, range);
    return store.acquire(key, () async {
      final payload = await http.open(
        uri,
        policy: policy,
        range: range,
        priority: priority,
        cancellation: cancellation,
      );
      final response = payload.response;
      if (response.statusCode != 200 && response.statusCode != 206) {
        await payload.body.take(0).drain<void>();
        throw const HttpException('媒体分片不可用');
      }
      if (range != null && response.statusCode != 206) {
        await payload.body.take(0).drain<void>();
        throw const HttpException('来源不支持请求的字节范围');
      }
      int? rangeLength;
      if (range != null) {
        try {
          rangeLength = _rangeLength(range, response);
        } catch (_) {
          await payload.body.take(0).drain<void>();
          rethrow;
        }
      }
      final headers = <String, String>{};
      for (final name in ['content-type', 'content-range', 'accept-ranges']) {
        final value = response.headers.value(name);
        if (value != null) headers[name] = value;
      }
      return store.write(
        key,
        payload.body,
        statusCode: response.statusCode,
        headers: headers,
        expectedLength:
            rangeLength ??
            (response.contentLength < 0 ? null : response.contentLength),
      );
    }, verify: verify);
  }
}

int _rangeLength(String request, HttpClientResponse response) {
  final wanted = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(request);
  final actual = RegExp(
    r'^bytes (\d+)-(\d+)/(\d+)$',
  ).firstMatch(response.headers.value('content-range') ?? '');
  if (wanted == null ||
      actual == null ||
      (wanted[1]!.isEmpty && wanted[2]!.isEmpty)) {
    throw const HttpException('来源返回无效的字节范围');
  }
  final start = int.parse(actual[1]!);
  final end = int.parse(actual[2]!);
  final total = int.parse(actual[3]!);
  if (total <= 0) throw const HttpException('来源返回无效的字节范围');
  final first = int.tryParse(wanted[1]!);
  final last = int.tryParse(wanted[2]!);
  final expectedStart = first ?? (total - last!).clamp(0, total);
  final expectedEnd = first == null || last == null
      ? total - 1
      : last.clamp(0, total - 1);
  final length = end - start + 1;
  if (total <= 0 ||
      start != expectedStart ||
      end != expectedEnd ||
      start < 0 ||
      end < start ||
      end >= total ||
      (response.contentLength >= 0 && response.contentLength != length)) {
    throw const HttpException('来源返回的字节范围与请求不一致');
  }
  return length;
}
