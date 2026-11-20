import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_html.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/domain/book.dart';

void main() {
  test('refresh orders surviving chapters by the new catalog', () async {
    final db = AppDatabase.memory();
    final store = BookStore(db);
    addTearDown(() async {
      store.vault.dispose();
      await db.close();
    });
    final base = Uri.parse('https://catalog.test');
    final book = Book('source', BookKind.text, '目录测试', '', base);
    BookChapter chapter(int index) =>
        BookChapter('$index', base.resolve('/$index'));
    final second = chapter(2);
    final retained = chapter(3);
    final fourth = chapter(4);
    await store.saveBook(
      book,
      chapters: [second, retained, fourth],
      last: second,
    );
    await store.saveText(book, retained, '离线正文');
    await store.saveBook(
      book,
      chapters: [chapter(1), second, fourth, chapter(5)],
    );
    final entry = (await store.entry(book))!;
    expect(entry.chapters.map((chapter) => chapter.title), [
      '1',
      '2',
      '3',
      '4',
      '5',
    ]);
    expect(entry.last, second.id);
  });

  test('static pagination preserves nav while text extraction removes it', () {
    const html =
        '<nav><a class="next" href="/page/2">下一页</a></nav>'
        '<script>ignored</script><main>正文</main>';
    final listing = parseBookHtml(html, keepNavigation: true);
    expect(bookField(listing, '.next@href'), '/page/2');
    expect(listing.querySelector('script'), isNull);
    expect(plainBookText(parseBookHtml(html)), '正文');
  });
}
