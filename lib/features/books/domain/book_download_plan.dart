final class BookDownloadPlan {
  const BookDownloadPlan(
    this.first,
    this.last,
    this.fallback, {
    this.chapterIds,
    this.fullBook = false,
    this.aggregateLatest = false,
  });

  final int first, last;
  final bool fallback, fullBook, aggregateLatest;
  final List<String>? chapterIds;

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
          chapterIds: ids is List
              ? ids.whereType<String>().take(4000).toList()
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
    'chapterIds': ?chapterIds,
  };
}
