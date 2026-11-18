import 'dart:convert';
import 'dart:io';
import '../../../core/network/cancellation_token.dart';
import '../../../core/network/header_policy.dart';
import '../../../core/network/media_http_client.dart';
import '../../../media/cache/segment_fetcher.dart';
import '../data/download_repository.dart';
import '../domain/download_task.dart';
import 'download_format.dart';
import 'hls_download.dart';
import 'mp4_download.dart';

Future<void> transferDownload({
  required DownloadTask task,
  required CancellationToken token,
  required DownloadRepository repository,
  required SegmentFetcher fetcher,
  required MediaHttpClient http,
  required int limit,
  required void Function(int) reserve,
  required Future<void> Function(File, CancellationToken) validate,
}) async {
  final Map<String, String> headers;
  try {
    headers = Map<String, String>.from(
      jsonDecode(task.row['headers'] as String),
    );
  } on Object {
    // Missing credentials must not silently turn into an unauthenticated retry.
    throw const FormatException('下载请求头记录损坏，请删除任务后重新添加');
  }
  final policy = HeaderPolicy({task.uri: headers});
  final directory = Directory(task.directory);
  await directory.create(recursive: true);
  String local;
  if (await isMp4Download(task.uri, http, policy, token)) {
    await downloadMp4(
      uri: task.uri,
      directory: directory,
      http: http,
      policy: policy,
      cancellation: token,
      maxBytes: limit,
      reserveBytes: reserve,
      progress: (c, t, b) => repository.progress(task.id, c, t, b),
      validate: validate,
    );
    local = 'video.mp4';
  } else {
    final job = HlsDownload(
      id: task.id,
      directory: directory,
      fetcher: fetcher,
      http: http,
      policy: policy,
      cancellation: token,
      maxBytes: limit,
      reserveBytes: reserve,
      onProgress: (c, t, b) => repository.progress(task.id, c, t, b),
    );
    local = await job.run(task.uri);
    await repository.progress(task.id, job.completed, job.completed, job.bytes);
  }
  token.check();
  await repository.cacheComplete(task.id, local);
}
