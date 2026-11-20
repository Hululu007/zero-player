import '../../../core/network/document_client.dart';

const _forbidden = '书源拒绝访问（HTTP 403）';
const _rateLimited = '书源限制请求频率（HTTP 429）';
const _unmatched = '可用书源中没有可核对的对应章节';
const _unknown = '下载失败，请检查来源或网络';

String bookDownloadFailureReason(Object? value) => switch (value) {
  RemoteFailure(status: 403) || _forbidden => _forbidden,
  RemoteFailure(status: 429) || _rateLimited => _rateLimited,
  BookDownloadChapterUnmatched() || _unmatched => _unmatched,
  BookDownloadSourceUnavailable(:final status) =>
    status == 429 ? _rateLimited : _forbidden,
  _ => _unknown,
};

final class BookDownloadChapterUnmatched implements Exception {
  const BookDownloadChapterUnmatched();
}

/// A server refusal that applies to the current batch, rather than an
/// individual missing chapter. The same plan can be resumed later.
final class BookDownloadSourceUnavailable implements Exception {
  const BookDownloadSourceUnavailable(this.status, this.retryAfter);

  final int status;
  final Duration? retryAfter;

  String get message => status == 429 ? _rateLimited : '书源连续拒绝访问（HTTP 403）';

  String get pauseMessage {
    final delay = retryAfter;
    return '$message，下载已暂停'
        '${delay != null && delay > Duration.zero ? '，书源要求等待至少 ${(delay.inMilliseconds + 999) ~/ 1000} 秒' : ''}';
  }
}

/// Share failures across the chapter workers so a rejected source is not
/// requested for every remaining chapter. A single 403 may be chapter-specific.
final class BookDownloadSourceHealth {
  final _refusals = <String, int>{};
  final _unavailable = <String, BookDownloadSourceUnavailable>{};

  BookDownloadSourceUnavailable? unavailable(String sourceId) =>
      _unavailable[sourceId];

  void succeeded(String sourceId) => _refusals.remove(sourceId);

  BookDownloadSourceUnavailable? failed(String sourceId, Object error) {
    if (_unavailable[sourceId] case final existing?) return existing;
    if (error is! RemoteFailure || error.status != 403 && error.status != 429) {
      _refusals.remove(sourceId);
      return null;
    }
    if (error.status == 403 &&
        _refusals.update(sourceId, (count) => count + 1, ifAbsent: () => 1) <
            2) {
      return null;
    }
    return _unavailable[sourceId] = BookDownloadSourceUnavailable(
      error.status!,
      error.retryAfter,
    );
  }
}
