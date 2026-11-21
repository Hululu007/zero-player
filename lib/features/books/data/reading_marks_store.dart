import '../../../core/persistence/metadata_domain.dart';
import '../domain/book.dart';
import '../domain/reading_mark.dart';
import 'book_store.dart';

final class ReadingMarksStore {
  const ReadingMarksStore(this.store, this.book, this.allowed);
  final BookStore store;
  final Book book;
  final bool Function() allowed;

  String get _key => 'books_marks:${book.id}';

  void _require() {
    if (!allowed()) throw const FormatException('当前内容策略限制访问');
  }

  Future<List<ReadingMark>> load({String? digest}) async {
    _require();
    final raw = await store.readBookValue(book, _key);
    _require();
    return ReadingMark.decode(raw, digest: digest);
  }

  Future<void> save(ReadingMark mark) => _mutate(
    (current) => [
      mark,
      ...current.where((item) => item.identity != mark.identity),
    ],
  );

  Future<void> delete(ReadingMark mark) => _mutate(
    (current) => [...current.where((item) => item.identity != mark.identity)],
  );

  Future<void> merge(List<ReadingMark> marks) => _mutate((current) {
    final existing = {for (final mark in current) mark.identity};
    return [...current, ...marks.where((mark) => existing.add(mark.identity))];
  });

  Future<void> _mutate(
    List<ReadingMark> Function(List<ReadingMark>) update,
  ) async {
    await store.db.atomic(
      () async {
        final next = update(await load());
        if (next.length > 1000) throw const FormatException('每本书最多保存 1000 条标注');
        store.db.beforeCommit(_require);
        await store.writeBookValue(book, _key, [
          for (final mark in next) mark.toJson(),
        ]);
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }
}
