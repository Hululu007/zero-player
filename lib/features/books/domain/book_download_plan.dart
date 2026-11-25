import 'book.dart';

final class BookDownloadPlan {
  const BookDownloadPlan(
    this.first,
    this.last,
    this.fallback, {
    this.chapterIds,
    this.fullBook = false,
    this.aggregateLatest = false,
    this.aggregationPending = false,
    this.retryCount = defaultRetryCount,
  });

  static const defaultRetryCount = 3;
  static const maxRetryCount = 5;
  final int first, last;
  final int retryCount;
  final bool fallback, fullBook, aggregateLatest;
  final bool aggregationPending;
  final List<String>? chapterIds;

  BookDownloadPlan withFallback() => BookDownloadPlan(
    first,
    last,
    true,
    chapterIds: chapterIds,
    fullBook: fullBook,
    aggregateLatest: aggregateLatest,
    aggregationPending: aggregationPending,
    retryCount: retryCount,
  );

  static BookDownloadPlan? fromJson(Object? value) {
    if (value case {
      'first': final int first,
      'last': final int last,
      'fallback': final bool fallback,
    }) {
      if (first >= 1 && last >= first) {
        final ids = (value as Map)['chapterIds'];
        return BookDownloadPlan(
          first,
          last,
          fallback,
          fullBook: value['fullBook'] == true,
          aggregateLatest: value['aggregateLatest'] == true,
          aggregationPending: value['aggregationPending'] == true,
          retryCount: switch (value['retryCount']) {
            final int count => count.clamp(0, maxRetryCount),
            _ => defaultRetryCount,
          },
          chapterIds: ids is List
              ? ids.whereType<String>().take(bookChapterCatalogLimit).toList()
              : null,
        );
      }
    }
    return null;
  }

  Map<String, Object> toJson() => {
    'first': first,
    'last': last,
    'fallback': fallback,
    'fullBook': fullBook,
    'aggregateLatest': aggregateLatest,
    'retryCount': retryCount,
    if (aggregationPending) 'aggregationPending': true,
    'chapterIds': ?chapterIds,
  };
}
