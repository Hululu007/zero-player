import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../../../core/network/cancellation_token.dart';
import '../../../core/network/document_client.dart';
import '../../../core/network/request_scheduler.dart';
import '../domain/book_download_plan.dart';
import 'book_download_source_health.dart';

final _jitter = Random();

Future<void> retryBookChapter(
  CancellationToken token,
  int retryCount,
  Future<void> Function() download,
) => withoutDocumentRetries(() async {
  final limit = retryCount.clamp(0, BookDownloadPlan.maxRetryCount);
  for (var attempt = 0; ; attempt++) {
    token.check();
    try {
      await withRequestPriority(RequestPriority.background, download);
      return;
    } on Exception catch (error) {
      token.check();
      if (attempt >= limit || !_transient(error)) rethrow;
      final requested = error is RemoteFailure ? error.retryAfter : null;
      if (requested != null && requested > const Duration(seconds: 30)) rethrow;
      final backoff = Duration(
        milliseconds: (250 << attempt) + _jitter.nextInt(150),
      );
      await _wait(
        requested != null && requested > backoff ? requested : backoff,
        token,
      );
    }
  }
});

bool _transient(Exception error) => switch (error) {
  RemoteFailure(:final kind, :final status) =>
    kind == FailureKind.network ||
        kind == FailureKind.timeout ||
        retryableBookThrottle(error) ||
        status == 408 ||
        status == 425 ||
        status != null &&
            status >= 500 &&
            status <= 599 &&
            status != 501 &&
            status != 505,
  SocketException() || TimeoutException() => true,
  _ => false,
};

Future<void> _wait(Duration duration, CancellationToken token) async {
  final done = Completer<void>();
  final timer = Timer(duration, done.complete);
  final unlink = token.listen(() {
    if (!done.isCompleted) done.completeError(const RequestCancelled());
  });
  try {
    await done.future;
  } finally {
    timer.cancel();
    unlink();
  }
}
