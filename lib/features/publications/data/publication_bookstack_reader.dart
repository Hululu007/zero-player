import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_http.dart';
import 'publication_panda_html_catalogues.dart';

typedef BookStackChapter = ({String title, Uri page});

String? publicationBookStackId(Uri page) {
  if (page.scheme != 'https' ||
      page.host != bookStackHome.host ||
      page.port != 443 ||
      page.userInfo.isNotEmpty ||
      page.hasQuery ||
      page.hasFragment) {
    return null;
  }
  return RegExp(
    r'^/books/([a-zA-Z0-9_.-]{1,120})/?$',
  ).firstMatch(page.path)?.group(1);
}

Future<List<BookStackChapter>> loadPublicationBookStack(
  PublicationHttp http,
  Uri page,
  CancellationToken token,
) async {
  if (publicationBookStackId(page) == null) {
    throw const PublicationFailure(PublicationProblem.unsupported);
  }
  return parseBookStackChapters(page, await _read(http, page, token));
}

List<BookStackChapter> parseBookStackChapters(Uri page, String body) {
  final id = publicationBookStackId(page);
  if (id == null) return const [];
  final prefix = '/read/$id/';
  final candidates = <Uri, BookStackChapter>{};
  final document = html.parse(body);
  final links = document.querySelector('.wd-tab-content') ?? document;
  for (final anchor in links.querySelectorAll('a[href]')) {
    final href = Uri.tryParse(anchor.attributes['href']!);
    if (href == null) continue;
    final link = page.resolveUri(href).removeFragment();
    final title = publicationLabel(anchor.attributes['title'] ?? anchor.text);
    if (link.scheme != 'https' ||
        link.host != page.host ||
        link.port != 443 ||
        link.userInfo.isNotEmpty ||
        link.hasQuery ||
        !link.path.startsWith(prefix) ||
        link.path.length <= prefix.length ||
        title.isEmpty) {
      continue;
    }
    candidates[link] = (title: title, page: link);
  }
  return candidates.values.take(1000).toList();
}

Future<String> loadPublicationBookStackChapter(
  PublicationHttp http,
  BookStackChapter chapter,
  CancellationToken token,
) async {
  final body = await _read(http, chapter.page, token);
  return parseBookStackChapterText(body);
}

String parseBookStackChapterText(String body) {
  final content = html.parse(body).querySelector('#page-content');
  if (content == null) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final text = StringBuffer();
  void visit(Node node) {
    if (node is Text) {
      text.write(node.data);
      return;
    }
    if (node is! Element ||
        const {
          'script',
          'style',
          'iframe',
          'object',
          'svg',
          'nav',
        }.contains(node.localName) ||
        node.classes.contains('markdown-toc') ||
        node.attributes.containsKey('hidden')) {
      return;
    }
    final block = const {
      'p',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'pre',
      'li',
      'tr',
      'div',
      'blockquote',
      'br',
    }.contains(node.localName);
    if (block) text.writeln();
    if (node.localName == 'img') {
      final alt = publicationLabel(node.attributes['alt']);
      if (alt.isNotEmpty) text.write('[$alt]');
    }
    if (node.localName == 'pre') {
      text.write(node.text);
    } else {
      node.nodes.forEach(visit);
    }
    if (block) text.writeln();
  }

  visit(content);
  final result = text
      .toString()
      .replaceAll(RegExp(r'\n[ \t]*\n(?:[ \t]*\n)+'), '\n\n')
      .trim();
  if (result.isEmpty) {
    throw const PublicationFailure(PublicationProblem.emptyResponse);
  }
  return result;
}

Future<String> _read(PublicationHttp http, Uri page, CancellationToken token) =>
    http.text(
      page,
      token,
      scope: (uri) {
        if (uri != page) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
      maxBytes: 2 << 20,
      deadline: const Duration(seconds: 22),
      allowGzip: true,
    );
