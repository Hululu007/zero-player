import 'package:html/parser.dart' as html;

import '../domain/publication.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';

const enjingSource = 'enjing-public-catalogue';
final enjingHome = Uri.https('www.enjing.net', '/');
final jiumoHome = Uri.https('jiumosearch.github.io', '/zhaoshu/');
final _articlePath = RegExp(r'^/[a-z0-9-]{1,60}/([0-9]{1,10})\.htm$');

PublicListingCatalogue enjingCatalogue(PublicationHttp http) =>
    PublicListingCatalogue(
      http,
      address: (query, page) => enjingHome.replace(
        path: page == 1 || query.isNotEmpty ? '/' : '/page/$page/',
        queryParameters: query.isEmpty
            ? null
            : {'s': query.toLowerCase(), if (page > 1) 'paged': '$page'},
      ),
      parse: parseEnjingCatalogue,
      deadline: const Duration(seconds: 16),
    );

PublicationListingPage parseEnjingCatalogue(String body) {
  final document = html.parse(body);
  final books = <Uri, PublicationEdition>{};
  for (final item in document.querySelectorAll('div.hentry, div.post-query')) {
    final anchor = item.querySelector('.post-preview a[rel=bookmark]');
    final page = publicListingLink(
      enjingHome,
      anchor?.attributes['href'],
      _articlePath,
    );
    final title = publicationLabel(anchor?.text);
    if (page == null || title.isEmpty) continue;
    books.putIfAbsent(
      page,
      () => PublicationEdition(
        id: publicationId('$enjingSource\n$page'),
        title: title,
        page: page,
        description: publicationLabel(
          item.querySelectorAll('.post-preview p').elementAtOrNull(1)?.text,
        ),
        cover: publicationCoverUrl(
          enjingHome,
          item.querySelector('.post-img img')?.attributes['src'],
          (uri) =>
              uri.host == enjingHome.host &&
              uri.path.startsWith('/wp-content/uploads/'),
        ),
        resources: [
          PublicationResource(source: enjingSource, link: page, label: '原站下载'),
        ],
      ),
    );
  }
  if (books.isEmpty && document.querySelector('.archive-title') == null) {
    throw const FormatException('恩京的书房目录格式已变更');
  }
  return (
    books: books.values.toList(),
    hasNext: document.querySelector('a.next, a[rel=next]') != null,
  );
}
