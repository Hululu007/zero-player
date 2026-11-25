import 'dart:convert';

import 'package:html/parser.dart' as html;

import '../domain/publication.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';

const shidianPublicationSource = 'panda-shidian';
final shidianHome = Uri.https('www.shidianguji.com', '/zh/');
final shidianEndpoint = shidianHome.resolve('search');
const _routeData = 'window._ROUTER_DATA = ';
const _searchRoute = r'__session/(lang$)/search.(query$)/page';
final _bookId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
final _coverHost = RegExp(r'^p[0-9]{1,2}-ancientlib-sign\.byteimg\.com$');

PublicListingCatalogue shidianCatalogue(PublicationHttp http) =>
    PublicListingCatalogue(
      http,
      address: (query, _) => shidianEndpoint.replace(
        pathSegments: ['zh', 'search', query.isEmpty ? '红楼梦' : query],
      ),
      parse: parseShidianCatalogue,
      maxBytes: 900 << 10,
    );

PublicationListingPage parseShidianCatalogue(String body) {
  final scripts = html.parse(body).querySelectorAll('script:not([src])');
  for (final script in scripts) {
    final text = script.text.trim();
    if (!text.startsWith(_routeData)) continue;
    final loader = jsonDecode(text.substring(_routeData.length));
    if (loader case {
      'loaderData': {
        _searchRoute: {
          'data': {
            'recommendBooks': final Object? recommendations,
            'paragraphs': final List passages,
          },
        },
      },
    }) {
      final books = <String, PublicationEdition>{};
      void add(Object? record) {
        final edition = _edition(record);
        if (edition != null) books.putIfAbsent(edition.id, () => edition);
      }

      if (recommendations case {'books': final List featured}) {
        for (final record in featured) {
          add(record);
        }
      }
      for (final passage in passages) {
        if (passage case {'bookInfo': final Object? record}) {
          add(record);
        }
      }
      return (books: books.values.toList(), hasNext: false);
    }
    break;
  }
  throw const PublicationFailure(PublicationProblem.invalid);
}

PublicationEdition? _edition(Object? data) {
  if (data case {
    'bookId': final String id,
    'bookName': final String label,
    'addNames': final List alternateTitles,
    'authors': final List authorRows,
    'edition': final Object? version,
    'beautifulCover': final Object? cover,
  } when _bookId.hasMatch(id)) {
    final name = publicationLabel(label);
    if (name.isEmpty) return null;
    final names = {name, ...alternateTitles.map(publicationLabel)}..remove('');
    final aliases = names.skip(1).join('／');
    final authors = {
      for (final credit in authorRows)
        if (credit case {'persName': final String person})
          publicationLabel(person),
    }..remove('');
    final page = shidianHome.resolve('book/$id');
    return PublicationEdition(
      id: publicationId('$shidianPublicationSource\n$id'),
      title: aliases.isEmpty ? name : '$name（$aliases）',
      author: publicationLabel(authors.join('、')),
      edition: version is Map ? publicationLabel(version['edition']) : '',
      cover: publicationCoverUrl(
        page,
        cover,
        (uri) =>
            _coverHost.hasMatch(uri.host) &&
            uri.path.startsWith('/tos-cn-i-ceu0di7tn2/beautiful-cover/'),
      ),
      page: page,
      language: 'zh',
    );
  }
  return null;
}
