import 'package:html/parser.dart' as html;

import '../domain/publication.dart';

const kgbookSource = 'kgbook-public-catalogue';
const kgbookCategories = [
  'xiandaiwenxue',
  'gudianwenxue',
  'wuxiaxiaoshuo',
  'wangluoxiaoshuo',
  'yanqingxiaoshuo',
  'zhichangxiaoshuo',
  'kehuanxuanhuan',
  'tuilijingsong',
  'renwensheke',
  'renwuchuanji',
  'waiguowenxue',
  'jinrongtouzi',
  'guanlishuji',
  'lizhichenggong',
  'lishidili',
  'zhanzhengjunshi',
  'zhexuezongjiao',
  'ertongwenxue',
  'shigesanwen',
  'zirankexue',
  'jiaoyuxuexi',
  'diannaowangluo',
  'baojianyangsheng',
  'shenghuoxiuxian',
  'qikanzazhi',
  'gongjushu',
  'dianzishuzhizuo',
];
const kgbookUpdates = 'list';
const kgbookIndexAsset = 'assets/catalogs/books/kgbook-index.json';

Uri kgbookListing(String category, [int page = 1]) => Uri.https(
  'kgbook.com',
  '/$category/${page == 1 ? '' : 'index_$page.html'}',
);

typedef KgbookPage = ({List<PublicationEdition> editions, Uri? next});

KgbookPage parseKgbookCatalogue(String body, Uri address) {
  final category = address.pathSegments.firstOrNull;
  if (category == null ||
      (category != kgbookUpdates && !kgbookCategories.contains(category))) {
    return (editions: [], next: null);
  }
  final document = html.parse(body);
  final editions = <String, PublicationEdition>{};
  for (final row in document.querySelectorAll('h3.list-title')) {
    final anchor = row.querySelector('a[href]');
    final href = anchor?.attributes['href'];
    if (href == null || href.length > 256) continue;
    final reference = Uri.tryParse(href);
    if (reference == null) continue;
    final target = address.resolveUri(reference);
    if (!kgbookPublicAddress(target) ||
        (category != kgbookUpdates &&
            target.pathSegments.firstOrNull != category)) {
      continue;
    }
    final metadata = row.parent?.querySelector('.list-content p')?.text ?? '';
    final format = RegExp(
      r'格式\s*[:：]\s*(?:\d+寸\s*)?(epub|pdf|mobi|azw3?|zip)\s*(?:\||$)',
      caseSensitive: false,
    ).firstMatch(metadata)?[1];
    final edition = kgbookEdition(
      target.path,
      publicationLabel(anchor?.text),
      publicationLabel(row.querySelector('.list-author')?.text),
      format ?? '',
    );
    if (edition != null) editions.putIfAbsent(target.path, () => edition);
  }
  final current = RegExp(r'/index_(\d+)\.html$').firstMatch(address.path)?[1];
  final next = kgbookListing(category, (int.tryParse(current ?? '') ?? 1) + 1);
  final hasNext = document.querySelectorAll('a[href]').any((anchor) {
    final reference = Uri.tryParse(anchor.attributes['href']!);
    if (anchor.text.trim() != '下一页' || reference == null) return false;
    final destination = address.resolveUri(reference);
    return kgbookPublicAddress(destination) && destination.path == next.path;
  });
  return (editions: editions.values.toList(), next: hasNext ? next : null);
}

final _bookPath = RegExp(
  '^/(?:${kgbookCategories.join('|')})/([1-9][0-9]{0,9})\\.html\$',
);

String? kgbookBookNumber(Uri page) => kgbookPublicAddress(page)
    ? _bookPath.firstMatch(page.path)?.group(1)
    : null;

String kgbookEditionId(Uri page) =>
    publicationId('$kgbookSource\n${page.path}');

PublicationEdition? kgbookEdition(
  String path,
  String rawTitle,
  String author,
  String suffix,
) {
  final title = publicationLabel(rawTitle);
  if (!_bookPath.hasMatch(path) || title.isEmpty) return null;
  final page = Uri.https('kgbook.com', path);
  final format = PublicationFormat.fromName('book.$suffix');
  return PublicationEdition(
    id: kgbookEditionId(page),
    title: title,
    author: publicationLabel(author),
    page: page,
    candidates: [
      if (format != null)
        AcquisitionCandidate(
          source: kgbookSource,
          link: page,
          page: page,
          format: format,
        ),
    ],
    resources: [PublicationResource.lookup(source: kgbookSource, link: page)],
  );
}

bool kgbookHost(Uri target) =>
    target.scheme == 'https' &&
    (target.host == 'kgbook.com' || target.host == 'www.kgbook.com') &&
    target.port == 443 &&
    target.userInfo.isEmpty;

bool kgbookPublicAddress(Uri target) =>
    kgbookHost(target) && !target.hasQuery && !target.hasFragment;
