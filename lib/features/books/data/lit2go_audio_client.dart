import '../../../core/network/cancellation_token.dart';
import '../../../core/network/document_client.dart';
import '../domain/book.dart';
import '../domain/legado_source.dart';
import 'book_html.dart';

/// Bounded static HTML adapter for the public Lit2Go catalog in english.jar.
final class Lit2GoAudioClient {
  const Lit2GoAudioClient(this.network);
  final DocumentClient network;

  static const categories = <LegadoCategory>[
    LegadoCategory('全部作品', '/lit2go/books/'),
  ];

  Future<Document> _get(BookSource source, Uri uri, CancellationToken token) =>
      network.get(
        source.requestTarget(uri),
        cancellation: token,
        networkTimeout: const Duration(seconds: 30),
        validateTarget: source.requestTarget,
      );

  Future<BookDiscoveryPage> discover(
    BookSource source,
    CancellationToken token, {
    int page = 1,
  }) async => (
    books: page == 1 ? await books(source, '', token) : <Book>[],
    next: null,
  );

  Future<List<Book>> books(
    BookSource source,
    String query,
    CancellationToken token, {
    int page = 1,
  }) async {
    if (page != 1) return const [];
    final response = await _get(source, source.endpoint, token);
    final document = parseBookHtml(response.text);
    final needle = bookIdentity(query);
    final books = <Book>[];
    for (final row
        in document.querySelectorAll('#results > figure').take(500)) {
      final link = row.querySelector('.title > a');
      final title = bookLabel(link?.text);
      final author = bookLabel(row.querySelector('.author')?.text);
      if (title.isEmpty ||
          (needle.isNotEmpty &&
              !bookIdentity('$title $author').contains(needle))) {
        continue;
      }
      final address = link?.attributes['href'];
      if (address == null) continue;
      try {
        final uri = source.resolve(response.uri, address);
        if (!RegExp(r'^/lit2go/\d+/[^/]+/$').hasMatch(uri.path)) continue;
        final coverAddress = row
            .querySelector('.book_icon img')
            ?.attributes['data-src'];
        final cover = coverAddress == null
            ? ''
            : source.resolve(response.uri, coverAddress).toString();
        books.add(
          Book(
            source.id,
            BookKind.audio,
            title,
            author,
            uri,
            cover: cover,
            description: bookLabel(row.querySelector('.abstract')?.text, 600),
          ),
        );
      } on FormatException {
        continue;
      }
    }
    return books;
  }

  Future<List<BookChapter>> chapters(
    BookSource source,
    Book book,
    CancellationToken token,
  ) async {
    if (!RegExp(r'^/lit2go/\d+/[^/]+/$').hasMatch(book.uri.path)) {
      throw const FormatException('Lit2Go 作品地址无效');
    }
    final response = await _get(source, book.uri, token);
    final chapters = <BookChapter>[];
    for (final link in parseBookHtml(
      response.text,
    ).querySelectorAll('#column_primary > dl > dt > a').take(4000)) {
      final raw = link.attributes['href'];
      final title = bookLabel(link.text);
      if (raw == null || title.isEmpty) continue;
      try {
        final uri = source.resolve(response.uri, raw);
        if (uri.path.startsWith(book.uri.path)) {
          chapters.add(BookChapter(title, uri));
        }
      } on FormatException {
        continue;
      }
    }
    return chapters;
  }

  Future<Uri> audio(
    BookSource source,
    BookChapter chapter,
    CancellationToken token,
  ) async {
    if (!RegExp(r'^/lit2go/\d+/[^/]+/\d+/[^/]+/$').hasMatch(chapter.uri.path)) {
      throw const FormatException('Lit2Go 章节地址无效');
    }
    final response = await _get(source, chapter.uri, token);
    final raw = parseBookHtml(
      response.text,
    ).querySelector('audio source[type="audio/mpeg"]')?.attributes['src'];
    if (raw == null) throw const FormatException('Lit2Go 章节没有 MP3 音频');
    final uri = source.resolve(response.uri, raw, media: true);
    if (!uri.path.startsWith('/lit2go/audio/mp3/') ||
        !uri.path.endsWith('.mp3')) {
      throw const FormatException('Lit2Go 音频地址无效');
    }
    return uri;
  }
}
