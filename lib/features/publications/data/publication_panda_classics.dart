import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart' show rootBundle;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';
import 'publication_search_text.dart';

const cbetaPublicationSource = 'panda-cbeta';
final cbetaCataloguePage = Uri.https('cbetaonline.dila.edu.tw', '/zh/');
final _cbetaId = RegExp(r'^[A-Z]{1,4}[0-9A-Za-z]{4,12}$');
const ctextPublicationSource = 'panda-ctext';
final ctextCataloguePage = Uri.https('ctext.org', '/');
final _ctextId = RegExp(r'^ctp:[a-z0-9-]{1,120}$');
const hanjiPublicationSource = 'panda-hanji';
final hanjiCataloguePage = Uri.https(
  'hanchi.ihp.sinica.edu.tw',
  '/ihp/newtitle.htm',
);
final _hanjiId = RegExp(r'^[A-Za-z0-9]{9,10}$');

PublicationCatalogue cbetaCatalogue(PublicationHttp http) => _ClassicsCatalogue(
  http,
  source: cbetaPublicationSource,
  asset: 'cbeta',
  home: cbetaCataloguePage,
  reader: _cbetaReader,
);

PublicationCatalogue ctextCatalogue(PublicationHttp http) => _ClassicsCatalogue(
  http,
  source: ctextPublicationSource,
  asset: 'ctext',
  home: ctextCataloguePage,
  reader: _ctextReader,
);

PublicationCatalogue hanjiCatalogue(PublicationHttp http) => _ClassicsCatalogue(
  http,
  source: hanjiPublicationSource,
  asset: 'hanji',
  home: hanjiCataloguePage,
  reader: (id) => _hanjiId.hasMatch(id)
      ? hanjiCataloguePage.replace(path: '/ihpc/hanjieb', query: id)
      : null,
);

const daizhigePublicationSource = 'panda-daizhige';
final daizhigeCataloguePage = Uri.https('daizhige.org', '/directory');
const _daizhigeCollections = {
  '儒藏',
  '史藏',
  '子藏',
  '集藏',
  '诗藏',
  '艺藏',
  '易藏',
  '医藏',
  '佛藏',
  '道藏',
  '现代作品',
  '四庫全書',
};
final _invalidPathCharacters = RegExp(r'[\\\x00-\x1f\x7f]');

PublicationCatalogue daizhigeCatalogue(PublicationHttp http) =>
    _ClassicsCatalogue(
      http,
      source: daizhigePublicationSource,
      asset: 'daizhige',
      home: daizhigeCataloguePage,
      reader: daizhigeReader,
      language: 'zh',
    );

Uri? daizhigeReader(String path) {
  final nested = path.endsWith('/');
  if (path.isEmpty ||
      path.length > 400 ||
      (!nested && !path.endsWith('.html'))) {
    return null;
  }
  final segments = (nested ? path.substring(0, path.length - 1) : path).split(
    '/',
  );
  if (segments.length < 2 ||
      !_daizhigeCollections.contains(segments.first) ||
      segments.any(
        (part) =>
            part.isEmpty ||
            part == '.' ||
            part == '..' ||
            _invalidPathCharacters.hasMatch(part),
      )) {
    return null;
  }
  return Uri(
    scheme: 'https',
    host: daizhigeCataloguePage.host,
    pathSegments: [...segments, if (nested) ''],
  );
}

Uri? _cbetaReader(String id) =>
    _cbetaId.hasMatch(id) ? cbetaCataloguePage.resolve(id) : null;

Uri? _ctextReader(String id) => _ctextId.hasMatch(id)
    ? Uri.https('api.ctext.org', '/getlink', {
        'if': 'zh',
        'urn': id,
        'redirect': '1',
      })
    : null;

final class _ClassicsCatalogue implements PublicationCatalogue {
  _ClassicsCatalogue(
    this.http, {
    required this.source,
    required this.asset,
    required this.home,
    required this.reader,
    this.language = 'zh-Hant',
  });

  final PublicationHttp http;
  final String source, asset, language;
  final Uri home;
  final Uri? Function(String) reader;
  Future<List<PublicationEdition>>? _index;

  @override
  Future<void> check(CancellationToken token) async {
    await _books(token);
  }

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
  }) async {
    if (filter?.field == PublicationSearchField.isbn) return const [];
    final books = await _books(token);
    final matcher =
        filter ??
        (query.isNotEmpty && publicationHanText.hasMatch(query)
            ? PublicationFieldSearch(
                PublicationSearchField.all,
                query,
                hanFold: await publicationHanFold(),
              )
            : null);
    token.check();
    return books
        .where(
          (book) =>
              book.matches(query, filter: matcher) &&
              allowed('${book.title} ${book.author}'),
        )
        .take(20 * maxPages.clamp(1, 5))
        .toList();
  }

  Future<List<PublicationEdition>> _books(CancellationToken token) async {
    token.check();
    http.authorize(home);
    final books = await (_index ??= _load());
    token.check();
    return books;
  }

  Future<List<PublicationEdition>> _load() async {
    final bytes = await rootBundle.load(
      'assets/catalogs/books/panda-$asset.json.gz',
    );
    final data = bytes.buffer.asUint8List(
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
    final id = source;
    final bookPage = reader;
    final locale = language;
    return Isolate.run(() => _decode(data, id, locale, bookPage));
  }
}

const shirenPublicationSource = 'panda-shiren';
final shirenCataloguePage = Uri.https('www.shiren.org', '/shiku/index.htm');
final _shirenPath = RegExp(
  r'^/shiku/(?:gs|xs|ws/(?:wg|ww|zg|sy))/(?:[a-zA-Z0-9_-]+/){0,4}[a-zA-Z0-9_-]+\.(?:html?|pdf)$',
);

Uri? _shirenReader(String path) => _shirenPath.hasMatch(path)
    ? Uri.https(shirenCataloguePage.host, path)
    : null;

final class ShirenCatalogue extends _ClassicsCatalogue
    implements DownloadablePublicationCatalogue {
  ShirenCatalogue(super.http)
    : super(
        source: shirenPublicationSource,
        asset: 'shiren',
        home: shirenCataloguePage,
        reader: _shirenReader,
        language: 'zh',
      );

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
  }) async {
    final books = await super.search(
      query,
      token,
      maxPages: maxPages,
      allowed: allowed,
      filter: filter,
    );
    return [
      for (final book in books)
        if (book.page case final page? when page.path.endsWith('.pdf'))
          book.withCandidates([
            AcquisitionCandidate(
              source: shirenPublicationSource,
              link: page,
              page: page,
              format: PublicationFormat.pdf,
            ),
          ])
        else
          book,
    ];
  }

  @override
  Future<PublicationDownload> download(
    AcquisitionCandidate candidate,
    CancellationToken token,
  ) async {
    final link = candidate.link;
    if (candidate.source != shirenPublicationSource ||
        candidate.format != PublicationFormat.pdf ||
        candidate.page != link ||
        !link.path.endsWith('.pdf') ||
        _shirenReader(link.path) != link) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    if (!(await _books(token)).any((book) => book.page == link)) {
      throw const PublicationFailure(PublicationProblem.missing);
    }
    return PublicationDownload(
      link,
      scope: (target) {
        if (target != link) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
    );
  }
}

List<PublicationEdition> _decode(
  List<int> data,
  String source,
  String language,
  Uri? Function(String) reader,
) {
  final rows = jsonDecode(utf8.decode(gzip.decode(data)));
  if (rows is! List || rows.isEmpty || rows.length > 50000) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  return [
    for (final row in rows)
      if (row case [
        String id,
        String title,
        String author,
        String edition,
      ] when title.isNotEmpty)
        if (reader(id) case final page?)
          PublicationEdition(
            id: publicationId('$source\n$id'),
            title: publicationLabel(title),
            author: publicationLabel(author),
            edition: publicationLabel(edition),
            language: language,
            page: page,
          ),
  ];
}
