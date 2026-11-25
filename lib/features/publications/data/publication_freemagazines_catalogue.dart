import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';

const freeMagazinesSource = 'panda-freemagazines';
final freeMagazinesHome = Uri.https('freemagazines.top', '/');
final _issuePath = RegExp(r'^/[a-z0-9][a-z0-9-]{1,180}/?$');
final _coverPath = RegExp(
  r'^/wp-content/uploads/[0-9]{4}/[0-9]{2}/[^/]+\.(?:jpe?g|png|webp)$',
);
final _previewPath = RegExp(r'^/[A-Za-z0-9]{8,32}/preview$');
final _easyUploadHome = Uri.https('easyupload.us', '/');

final class FreeMagazinesCatalogue
    implements ProgressivePublicationCatalogue, ResourcePublicationCatalogue {
  const FreeMagazinesCatalogue(this.http);

  final PublicationHttp http;

  PublicListingCatalogue get _listing => PublicListingCatalogue(
    http,
    address: (query, page) => freeMagazinesHome.replace(
      path: page == 1 ? '/' : '/page/$page',
      queryParameters: query.isEmpty ? null : {'s': query},
    ),
    parse: parseFreeMagazinesCatalogue,
  );

  @override
  Future<void> check(CancellationToken token) => _listing.check(token);

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
    Future<void> Function(List<PublicationEdition>)? onProgress,
  }) {
    if (filter?.field == PublicationSearchField.author ||
        filter?.field == PublicationSearchField.isbn) {
      return Future.value(const []);
    }
    return _listing.search(
      query,
      token,
      maxPages: maxPages,
      allowed: allowed,
      filter: filter,
      onProgress: onProgress,
    );
  }

  @override
  Future<List<PublicationResource>> loadResources(
    Uri page,
    CancellationToken token,
  ) async {
    if (publicListingLink(freeMagazinesHome, page.toString(), _issuePath) !=
        page) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    return parseFreeMagazinesResources(
      page,
      await publicListingText(http, page, token),
    );
  }
}

PublicationListingPage parseFreeMagazinesCatalogue(String body) {
  final document = html.parse(body);
  final catalogue = document.querySelector('main#main');
  if (catalogue == null) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final issues = <Uri, PublicationEdition>{};
  for (final card in catalogue.querySelectorAll(
    'article.type-post.status-publish',
  )) {
    final heading = card.querySelector('.entry-title a[rel=bookmark][href]');
    final page = publicListingLink(
      freeMagazinesHome,
      heading?.attributes['href'],
      _issuePath,
    );
    final title = publicationLabel(heading?.text);
    if (page == null || title.isEmpty) continue;
    issues[page] = PublicationEdition(
      id: publicationId('$freeMagazinesSource\n$page'),
      title: title,
      page: page,
      resources: [
        PublicationResource.lookup(source: freeMagazinesSource, link: page),
      ],
      cover: publicationCoverUrl(
        page,
        card.querySelector('.post-image img.wp-post-image')?.attributes['src'],
        (uri) =>
            uri.origin == freeMagazinesHome.origin &&
            _coverPath.hasMatch(uri.path) &&
            !uri.hasQuery,
      ),
    );
  }
  if (issues.isEmpty &&
      catalogue.querySelector('.no-results.not-found') == null) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  return (
    books: issues.values.toList(),
    hasNext:
        catalogue.querySelector(
          '.paging-navigation a.next.page-numbers[href]',
        ) !=
        null,
  );
}

List<PublicationResource> parseFreeMagazinesResources(Uri page, String body) {
  final document = html.parse(body);
  final canonical = publicListingLink(
    freeMagazinesHome,
    document.querySelector('link[rel=canonical]')?.attributes['href'],
    _issuePath,
  );
  if (canonical != page) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final files = <Uri, PublicationResource>{};
  for (final anchor in document.querySelectorAll(
    'main#main article.type-post .entry-content a[href]',
  )) {
    final raw = anchor.attributes['href'];
    if (Uri.tryParse(raw ?? '')?.host != _easyUploadHome.host) continue;
    final resource = publicListingLink(_easyUploadHome, raw, _previewPath);
    if (resource == null) continue;
    files[resource] = PublicationResource(
      source: freeMagazinesSource,
      link: resource,
      label: 'EasyUpload · PDF 预览',
    );
  }
  return files.values.toList();
}
