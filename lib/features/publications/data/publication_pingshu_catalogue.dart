import 'package:enough_convert/gbk.dart';
import 'package:html/parser.dart' as html;

import '../../../core/network/document_encoding.dart';
import '../domain/publication.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';

const pingshu365PublicationSource = 'panda-pingshu365';
final pingshu365Home = Uri.https('www.pingshu365.com', '/');
final pingshu365Endpoint = pingshu365Home.resolve('/search/1.asp');
final _audioPage = RegExp(r'^/ps/[1-9][0-9]{0,8}\.html$');
final _cover = RegExp(r'^/pic/[A-Za-z0-9_-]{1,96}\.(?:jpg|jpeg|png|gif)$');

PublicListingCatalogue pingshu365Catalogue(PublicationHttp http) =>
    PublicListingCatalogue(
      http,
      address: (query, page) {
        if (query.isEmpty) return pingshu365Home;
        final encoded = encodeDocumentComponent(query, gbk);
        return pingshu365Endpoint.replace(
          query: 'keyword=$encoded${page > 1 ? '&page=$page' : ''}',
        );
      },
      parse: parsePingshu365Catalogue,
      encoding: gbk,
      legacyQueryEncoding: true,
    );

PublicationListingPage parsePingshu365Catalogue(String body) {
  final document = html.parse(body);
  if (document.querySelector('form[name="searchform"] input[name="keyword"]') ==
      null) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <Uri, PublicationEdition>{};
  for (final item in document.querySelectorAll('div.book')) {
    final anchor = item.querySelector('.text p span a[href]');
    final page = publicListingLink(
      pingshu365Home,
      anchor?.attributes['href'],
      _audioPage,
    );
    final title = publicationLabel(anchor?.text);
    if (page == null || title.isEmpty) continue;
    var author = '';
    var narrator = '';
    for (final field in item.querySelectorAll('.text ul > li')) {
      final text = field.text.trim();
      if (text.startsWith('作者：')) {
        author = publicationLabel(text.substring(3));
      } else if (text.startsWith('播讲：')) {
        narrator = publicationLabel(text.substring(3));
      }
    }
    books[page] = PublicationEdition(
      id: publicationId('$pingshu365PublicationSource\n$page'),
      title: title,
      author: author,
      description: narrator.isEmpty ? '' : '播讲 $narrator',
      cover: publicationCoverUrl(
        pingshu365Home,
        item.querySelector('.pic img[src]')?.attributes['src'],
        (url) =>
            url.origin == pingshu365Home.origin &&
            !url.hasQuery &&
            _cover.hasMatch(url.path),
      ),
      language: 'zh',
      page: page,
    );
  }
  if (books.isEmpty) {
    for (final anchor in document.querySelectorAll('#layout a[href]')) {
      final page = publicListingLink(
        pingshu365Home,
        anchor.attributes['href'],
        _audioPage,
      );
      final title = publicationLabel(anchor.text);
      if (page == null || title.isEmpty) continue;
      books[page] = PublicationEdition(
        id: publicationId('$pingshu365PublicationSource\n$page'),
        title: title,
        language: 'zh',
        page: page,
      );
    }
  }
  return (
    books: books.values.toList(),
    hasNext: document
        .querySelectorAll('a[href^="1.asp?page="]')
        .any((link) => link.text.trim() == '下一页'),
  );
}
