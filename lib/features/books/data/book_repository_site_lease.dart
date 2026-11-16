part of 'books_repository.dart';

/// One batch owns its samples and commits until it has completely unwound.
/// Different direct callers receive a busy error instead of an unbounded queue.
final class _SiteScanLease {
  _SiteScanLease(this.token, this.unlink);

  final CancellationToken token;
  final void Function() unlink;
  final done = Completer<void>();

  void release(BooksRepository books) {
    if (identical(books._siteScanLease, this)) books._siteScanLease = null;
    unlink();
    if (!done.isCompleted) done.complete();
  }
}

_SiteScanLease _acquireSiteScanLease(
  BooksRepository books,
  CancellationToken cancellation, {
  bool useCallerToken = false,
}) {
  if (books._evidenceClosing) throw StateError('书源服务正在关闭');
  cancellation.check();
  if (books._siteScanLease != null) {
    throw const FormatException('书源网页抽查正在进行，请稍后再试');
  }
  // Manual checks historically cancel the supplied token on policy change or
  // worker failure. Supervised scans retain their isolated, linked token.
  final token = useCallerToken ? cancellation : CancellationToken();
  final unlink = useCallerToken ? () {} : cancellation.listen(token.cancel);
  final lease = _SiteScanLease(token, unlink);
  books._siteScanLease = lease;
  return lease;
}
