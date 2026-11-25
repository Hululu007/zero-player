import 'dart:convert';

import 'package:html/parser.dart' as html;

import 'package:html/dom.dart' as dom;
import '../domain/publication.dart';
import '../domain/share_text.dart';
import 'publication_aisixiang_catalogue.dart';
import 'publication_alltool_catalogue.dart';
import 'publication_aozora_catalogue.dart';
import 'publication_archive_catalogue.dart';
import 'publication_cadal_catalogue.dart';
import 'publication_catalogue.dart';
import 'publication_cdstm_catalogue.dart';
import 'publication_cnpereading_catalogue.dart';
import 'publication_dushupai_catalogue.dart';
import 'publication_ebooklist_catalogue.dart';
import 'publication_enjing_catalogue.dart';
import 'publication_freemagazines_catalogue.dart';
import 'publication_gallica_catalogue.dart';
import 'publication_gutenberg_catalogue.dart';
import 'publication_gujiguan_catalogue.dart';
import 'publication_haodoo_catalogue.dart';
import 'publication_hep_catalogue.dart';
import 'publication_http.dart';
import 'publication_huxiang_catalogue.dart';
import 'publication_jb51_catalogue.dart';
import 'publication_kanhaoshu_catalogue.dart';
import 'publication_klib_catalogue.dart';
import 'publication_kgbook_catalogue.dart';
import 'publication_lunarora_catalogue.dart';
import 'publication_mit_catalogue.dart';
import 'publication_modernhistory_catalogue.dart';
import 'publication_oalib_catalogue.dart';
import 'publication_obp_catalogue.dart';
import 'publication_openstax_catalogue.dart';
import 'publication_open_textbooks_catalogue.dart';
import 'publication_panda_book_sites.dart';
import 'publication_panda_book_indexes.dart';
import 'publication_panda_classics.dart';
import 'publication_panda_companions.dart';
import 'publication_panda_html_catalogues.dart';
import 'publication_panda_novel_catalogues.dart';
import 'publication_panda_publishers.dart';
import 'publication_panda_wordpress.dart';
import 'publication_penn_catalogue.dart';
import 'publication_pingshu_catalogue.dart';
import 'publication_planet_catalogue.dart';
import 'publication_qianqiu_catalogue.dart';
import 'publication_sciencereading_catalogue.dart';
import 'publication_shidian_catalogue.dart';
import 'publication_rule_options.dart';
import 'publication_shuge_catalogue.dart';
import 'publication_sobooks_catalogue.dart';
import 'publication_smartedu_catalogue.dart';
import 'publication_standard_ebooks_catalogue.dart';
import 'publication_share_provider.dart';
import 'publication_tadoku_catalogue.dart';
import 'publication_tinynews_catalogue.dart';
import 'publication_tokyo_hong_catalogue.dart';
import 'publication_treasure_catalogue.dart';
import 'publication_tstrs_catalogue.dart';
import 'publication_vorleser_catalogue.dart';
import 'publication_wikisource_catalogue.dart';
import 'publication_zulu_catalogue.dart';

enum PublicationSourceKind {
  catalogue,
  website,
  restrictedDirectory,
  snapshot,
  jsonSearch,
  htmlSearch,
}

final class PublicationSource {
  const PublicationSource({
    required this.id,
    required this.name,
    required this.kind,
    required this.endpoint,
    this.website,
    this.websiteQueryParameter,
    this.catalogue,
    this.license = '',
    this.preferChineseSearch = false,
    this.rows = '',
    this.field = const {},
    this.hosts = const [],
    this.parameter = 'q',
    this.pageParameter = 'page',
    this.rule,
  });

  final String id, name, license, rows, parameter, pageParameter;
  final PublicationSourceKind kind;
  final bool preferChineseSearch;
  final Uri endpoint;
  final Uri? website;
  final String? websiteQueryParameter;
  final PublicationCatalogue Function(PublicationHttp)? catalogue;
  final List<String> hosts;
  final Map<String, String> field;
  final PublicationRuleOptions? rule;
  bool get configurable => const {
    PublicationSourceKind.snapshot,
    PublicationSourceKind.jsonSearch,
    PublicationSourceKind.htmlSearch,
  }.contains(kind);
  bool get restricted => kind == PublicationSourceKind.restrictedDirectory;
  bool get websiteOnly => kind == PublicationSourceKind.website;
  bool get enabledByDefault => !configurable && !restricted;

  factory PublicationSource.configure(Map spec, {String? id}) {
    final name = publicationLabel(spec['name'], max: 100);
    final endpoint = Uri.tryParse(
      publicationLabel(spec['endpoint'], max: 2048),
    );
    final kind = PublicationSourceKind.values
        .where((item) => item.name == spec['kind'])
        .firstOrNull;
    final version = spec['version'];
    if ((version != 1 && version != 2) ||
        name.isEmpty ||
        endpoint == null ||
        endpoint.scheme != 'https' ||
        endpoint.hasFragment ||
        kind == null ||
        !const {
          PublicationSourceKind.snapshot,
          PublicationSourceKind.jsonSearch,
          PublicationSourceKind.htmlSearch,
        }.contains(kind)) {
      throw const FormatException('书源配置的版本、类型或地址无效');
    }
    validatePublicationAddress(endpoint);
    final hosts = spec['hosts'] ?? const [];
    if (hosts is! List ||
        hosts.length > 12 ||
        hosts.any(
          (value) =>
              value is! String ||
              !RegExp(r'^(?:[a-z0-9-]+\.)+[a-z0-9-]+$').hasMatch(value) ||
              value.length > 253,
        )) {
      throw const FormatException('书源允许的域名列表无效');
    }
    final raw = spec['field'];
    final keys = RegExp(r'^[a-zA-Z_][\w-]{0,63}$');
    final selectors = RegExp(
      r'^(?:[a-zA-Z][\w-]*)?(?:[.#][\w-]+)?(?: (?:[a-zA-Z][\w-]*)?(?:[.#][\w-]+)?){0,2}(?:@(href|data-url|data-isbn|content))?$',
    );
    final htmlRule = kind == PublicationSourceKind.htmlSearch;
    final selection = htmlRule ? selectors : keys;
    bool validSelector(String value, {bool rows = false}) => version == 2
        ? publicationRuleSelector(value, html: htmlRule, rows: rows)
        : value.length <= 100 &&
              selection.hasMatch(value) &&
              (!rows || !value.contains('@'));
    final rows = spec['rows'] ?? '';
    final parameter = spec['queryParameter'] ?? 'q';
    final pageParameter = spec['pageParameter'] ?? 'page';
    if (raw is! Map ||
        !_validPublicationFields(raw, version == 2, validSelector) ||
        rows is! String ||
        (rows.isEmpty
            ? kind == PublicationSourceKind.htmlSearch
            : !validSelector(rows, rows: true)) ||
        parameter is! String ||
        !keys.hasMatch(parameter) ||
        pageParameter is! String ||
        !keys.hasMatch(pageParameter) ||
        pageParameter == parameter) {
      throw const FormatException('书源字段、选择器或分页参数无效');
    }
    final rule = version == 2
        ? PublicationRuleOptions.parse(spec, html: htmlRule)
        : null;
    final source = PublicationSource(
      id: id ?? publicationId('source:$endpoint'),
      name: name,
      kind: kind,
      endpoint: endpoint,
      license: publicationLabel(spec['license']),
      rows: rows,
      field: Map<String, String>.from(raw),
      hosts: List<String>.from(hosts),
      parameter: parameter,
      pageParameter: pageParameter,
      rule: rule,
    );
    if (rule?.list case final address?) {
      final list = endpoint.resolve(address);
      validatePublicationAddress(list);
      source.restrict(list);
      if (list.hasFragment) throw const FormatException('发现地址不能包含片段');
    }
    return source;
  }

  Map<String, Object?> toSpec() => {
    'version': rule == null ? 1 : 2,
    'kind': kind.name,
    'name': name,
    'endpoint': endpoint.toString(),
    'license': license,
    'rows': rows,
    'field': field,
    'hosts': hosts,
    'queryParameter': parameter,
    'pageParameter': pageParameter,
    ...?rule?.toSpec(),
  };

  bool sameConfiguration(PublicationSource other) =>
      id == other.id &&
      (!configurable || jsonEncode(toSpec()) == jsonEncode(other.toSpec()));

  void restrict(Uri uri) {
    if (uri.scheme != 'https' ||
        uri.port != 443 ||
        (uri.host != endpoint.host && !hosts.contains(uri.host))) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
  }
}

bool _validPublicationFields(
  Map fields,
  bool versionTwo,
  bool Function(String) valid,
) {
  final keys = {
    'title',
    'author',
    'isbn',
    'language',
    'translator',
    'edition',
    'license',
    'page',
    'epub',
    'pdf',
    'zip',
    if (versionTwo) ...{'cover', ...publicationRuleDownloadFields},
  };
  return fields['title'] is String &&
      fields.length <= keys.length &&
      fields.entries.every(
        (entry) =>
            keys.contains(entry.key) &&
            entry.value is String &&
            (entry.value as String).isNotEmpty &&
            valid(entry.value as String),
      );
}

final builtinPublicationSources = [
  PublicationSource(
    id: openTextbooksSource,
    name: 'Open Textbook Library',
    kind: PublicationSourceKind.catalogue,
    catalogue: OpenTextbooksCatalogue.new,
    endpoint: openTextbooksEndpoint,
    license: '目录 CC0，图书按条目标注',
  ),
  PublicationSource(
    id: archiveGutenbergSource,
    name: 'Internet Archive · 图书',
    kind: PublicationSourceKind.catalogue,
    catalogue: ArchiveGutenbergCatalogue.new,
    endpoint: archiveCatalogueEndpoint,
    website: Uri.https('archive.org'),
    license: '公开图书书目 · 经核实的古登堡公版 EPUB 可下载',
  ),
  PublicationSource(
    id: gutenbergPublicationSource,
    preferChineseSearch: true,
    name: '古登堡计划 · 官方镜像',
    kind: PublicationSourceKind.catalogue,
    catalogue: GutenbergCatalogue.new,
    endpoint: gutenbergCatalogueEndpoint,
    website: gutenbergCataloguePage,
    license: '官方目录和文件镜像 · 逐件验证美国公版 EPUB',
  ),
  PublicationSource(
    id: shugeSource,
    name: '书格 · 开放古籍',
    kind: PublicationSourceKind.catalogue,
    catalogue: ShugeCatalogue.new,
    endpoint: shugeCatalogueEndpoint,
    website: Uri.https('www.shuge.org', '/collections/'),
    license: '官方公开目录 · 按资源许可提供下载',
  ),
  PublicationSource(
    id: openStaxSource,
    name: 'OpenStax · 开放教材',
    kind: PublicationSourceKind.catalogue,
    catalogue: OpenStaxCatalogue.new,
    endpoint: openStaxCatalogueEndpoint,
    website: Uri.https('openstax.org', '/subjects'),
    license: 'OpenStax 官方目录 · 按教材许可提供 PDF',
  ),
  PublicationSource(
    id: tadokuSource,
    name: 'Tadoku · 日语分级读物',
    kind: PublicationSourceKind.catalogue,
    catalogue: TadokuCatalogue.new,
    endpoint: tadokuCatalogueEndpoint,
    license: '官方免费目录 · CC BY-NC-ND 4.0 原版 PDF',
  ),
  PublicationSource(
    id: alltoolSource,
    name: '金屋电子书 · 公开目录',
    kind: PublicationSourceKind.catalogue,
    catalogue: AlltoolCatalogue.new,
    endpoint: alltoolCatalogueEndpoint,
    website: Uri.https('alltool.top'),
    license: '可筛选最新上架条目 · 在原站获取下载地址',
  ),
  PublicationSource(
    id: kgbookSource,
    preferChineseSearch: true,
    name: '苦瓜书盘 · 公开目录',
    kind: PublicationSourceKind.catalogue,
    catalogue: KgbookCatalogue.new,
    endpoint: kgbookCatalogueEndpoint,
    website: Uri.https('kgbook.com'),
    license: '公开分类书目 · 按站方格式下载',
  ),
  PublicationSource(
    id: 'jiumo-book-search',
    name: '鸠摩搜书',
    kind: PublicationSourceKind.website,
    endpoint: jiumoHome,
    website: jiumoHome,
    websiteQueryParameter: 'q',
    license: '原站全文索引 · 在浏览器中搜索',
  ),
  PublicationSource(
    id: enjingSource,
    name: '恩京的书房',
    kind: PublicationSourceKind.catalogue,
    endpoint: enjingHome,
    website: enjingHome,
    websiteQueryParameter: 's',
    catalogue: enjingCatalogue,
    preferChineseSearch: true,
    license: '公开书目 · 下载在原站完成',
  ),
  PublicationSource(
    id: lunaroraSource,
    preferChineseSearch: true,
    name: '鹿鸣川 · 公开书目',
    kind: PublicationSourceKind.catalogue,
    catalogue: LunaroraCatalogue.new,
    endpoint: lunaroraCatalogueEndpoint,
    license: '官方检索与公开分享',
  ),
  PublicationSource(
    id: tstrsSource,
    preferChineseSearch: true,
    name: 'tstrs.me · 公开榜单',
    kind: PublicationSourceKind.catalogue,
    catalogue: TstrsCatalogue.new,
    endpoint: tstrsCatalogueEndpoint,
    website: Uri.https('tstrs.me'),
    license: '仅书目信息 · 检索全部公开榜单',
  ),
  PublicationSource(
    id: dushupaiSource,
    preferChineseSearch: true,
    name: '读书派 · 公开书目',
    kind: PublicationSourceKind.catalogue,
    catalogue: DushupaiCatalogue.new,
    endpoint: dushupaiCatalogueEndpoint,
    license: '小说文学目录与站内检索 · 读取站方公布的网盘入口',
  ),
  PublicationSource(
    id: tokyoHongSource,
    name: '东京大学 · 双红堂文库',
    kind: PublicationSourceKind.catalogue,
    catalogue: TokyoHongCatalogue.new,
    endpoint: tokyoHongCatalogueEndpoint,
    website: Uri.https('hong.ioc.u-tokyo.ac.jp', '/aboutdb_chinese.html'),
    license: '仅书目信息 · 官方古籍目录与检索',
  ),
  PublicationSource(
    id: treasurePublicationSource,
    name: '书目宝库 · 公开书目',
    kind: PublicationSourceKind.catalogue,
    catalogue: TreasureCatalogue.new,
    endpoint: treasureCatalogueEndpoint,
    website: treasureCataloguePage,
    license: '书名、作者和分类筛选 · 打开公开网盘分享',
  ),
  PublicationSource(
    id: haodooPublicationSource,
    name: '好讀二代 · 公開書目',
    kind: PublicationSourceKind.catalogue,
    catalogue: HaodooCatalogue.new,
    endpoint: haodooCatalogueEndpoint,
    website: Uri.https('haodoo.org', '/'),
    license: '仅书目与原站出处 · EPUB 获取按站方流程办理',
  ),
  PublicationSource(
    id: wikisourcePublicationSource,
    name: '维基文库 · 英文书目',
    kind: PublicationSourceKind.catalogue,
    catalogue: WikisourceCatalogue.new,
    endpoint: wikisourceCatalogueEndpoint,
    website: wikisourceCataloguePage,
    license: '官方 OPDS 目录 · 导出 EPUB 标注 CC BY-SA 3.0',
  ),
  PublicationSource(
    id: standardEbooksPublicationSource,
    name: 'Standard Ebooks · 公版 EPUB',
    kind: PublicationSourceKind.catalogue,
    catalogue: StandardEbooksCatalogue.new,
    endpoint: standardEbooksCatalogueEndpoint,
    website: standardEbooksCataloguePage,
    license: '官方新书订阅和公开检索 · 美国公版 EPUB',
  ),
  PublicationSource(
    id: obpPublicationSource,
    name: 'Open Book Publishers · 出版书目',
    kind: PublicationSourceKind.catalogue,
    catalogue: ObpCatalogue.new,
    endpoint: obpCatalogueEndpoint,
    website: obpCataloguePage,
    license: 'Thoth 官方 CC0 目录 · 出版方原页 · Unglue.it 授权 PDF/EPUB',
  ),
  PublicationSource(
    id: sobooksPublicationSource,
    name: 'SoBooks · 公开书目',
    kind: PublicationSourceKind.catalogue,
    catalogue: SobooksCatalogue.new,
    endpoint: sobooksCatalogueEndpoint,
    website: sobooksCatalogueEndpoint,
    license: '可筛选公开目录的最新条目 · 读取站方公布的网盘入口',
  ),
  PublicationSource(
    id: gallicaPublicationSource,
    name: '法国国家图书馆 · Gallica 公开书目',
    kind: PublicationSourceKind.catalogue,
    catalogue: GallicaCatalogue.new,
    endpoint: gallicaCatalogueEndpoint,
    website: gallicaCataloguePage,
    license: '馆方开放书目 · 标记为可公开阅览的数字版本',
  ),
  PublicationSource(
    id: aozoraPublicationSource,
    name: '青空文库',
    kind: PublicationSourceKind.catalogue,
    catalogue: AozoraCatalogue.new,
    endpoint: aozoraCatalogueEndpoint,
    website: aozoraCataloguePage,
    license: '官方离线书目 · 在原站阅读',
  ),
  PublicationSource(
    id: pennPublicationSource,
    name: '宾大 · The Online Books Page',
    kind: PublicationSourceKind.catalogue,
    catalogue: PennCatalogue.new,
    endpoint: pennCatalogueEndpoint,
    website: pennCataloguePage,
    license: '宾大公开书目 · 各版本的阅读链接见原站',
  ),
  PublicationSource(
    id: planetPublicationSource,
    name: 'Planet eBook · 经典文学',
    kind: PublicationSourceKind.catalogue,
    catalogue: PlanetCatalogue.new,
    endpoint: planetCatalogueEndpoint,
    website: planetCataloguePage,
    license: '原站标注澳大利亚公版 · EPUB、PDF、MOBI',
  ),
  PublicationSource(
    id: bookStackSource,
    name: '书栈网 · 开源技术书目',
    kind: PublicationSourceKind.catalogue,
    catalogue: bookStackCatalogue,
    endpoint: bookStackEndpoint,
    website: bookStackHome,
    preferChineseSearch: true,
    license: '公开技术书籍目录 · 在原站阅读',
  ),
  PublicationSource(
    id: taiwanEbookSource,
    name: '台湾华文电子书库',
    kind: PublicationSourceKind.catalogue,
    catalogue: taiwanEbookCatalogue,
    endpoint: taiwanEbookHome,
    website: taiwanEbookHome,
    preferChineseSearch: true,
    license: '公开馆藏检索 · 原站阅读权限按书目',
  ),
  PublicationSource(
    id: saltTigerSource,
    name: 'SaltTiger · 技术书目',
    kind: PublicationSourceKind.catalogue,
    catalogue: saltTigerCatalogue,
    endpoint: saltTigerHome,
    website: saltTigerHome,
    license: '公开技术书目 · 阅读站方公布的百度网盘入口',
  ),
  PublicationSource(
    id: ibooksPublicationSource,
    name: '读书小站 · 作者书目',
    kind: PublicationSourceKind.catalogue,
    catalogue: IBooksCatalogue.new,
    endpoint: ibooksCatalogueHome,
    website: ibooksCatalogueHome,
    preferChineseSearch: true,
    license: '公开书目和作者标签 · 在原站查看',
  ),
  PublicationSource(
    id: zuluPublicationSource,
    name: 'Zulu eBooks · 德语书目',
    kind: PublicationSourceKind.catalogue,
    catalogue: ZuluCatalogue.new,
    endpoint: zuluCatalogueEndpoint,
    website: zuluCatalogueHome,
    license: '站方公开书目 · 逐书复核 PDF、EPUB 和 MOBI 入口',
  ),
  PublicationSource(
    id: shukuiPublicationSource,
    name: '书葵 · 书目检索',
    kind: PublicationSourceKind.catalogue,
    catalogue: ShukuiCatalogue.new,
    endpoint: shukuiEndpoint,
    website: shukuiHome,
    preferChineseSearch: true,
    license: '公开书目、作者和 ISBN · 在原站查看',
  ),
  PublicationSource(
    id: moreReadPublicationSource,
    name: '多阅读 · 公开书目',
    kind: PublicationSourceKind.catalogue,
    catalogue: moreReadCatalogue,
    endpoint: moreReadEndpoint,
    website: moreReadHome,
    preferChineseSearch: true,
    license: '公开书目检索 · 原站详情需要登录',
  ),
  PublicationSource(
    id: cbetaPublicationSource,
    name: '中华电子佛典协会 · CBETA',
    kind: PublicationSourceKind.catalogue,
    catalogue: cbetaCatalogue,
    endpoint: cbetaCataloguePage,
    website: cbetaCataloguePage,
    preferChineseSearch: true,
    license: '公开书目 · 官方线上阅读',
  ),
  PublicationSource(
    id: ctextPublicationSource,
    name: '诸子百家 · 中国哲学书电子化计划',
    kind: PublicationSourceKind.catalogue,
    catalogue: ctextCatalogue,
    endpoint: ctextCataloguePage,
    website: ctextCataloguePage,
    preferChineseSearch: true,
    license: '公开书目 · 按原站页面阅读',
  ),
  PublicationSource(
    id: commercialPressSource,
    name: '商务印书馆 · 出版书目',
    kind: PublicationSourceKind.catalogue,
    catalogue: commercialPressCatalogue,
    endpoint: commercialPressEndpoint,
    website: commercialPressHome,
    preferChineseSearch: true,
    license: '官方出版书目 · 在原站查看',
  ),
  PublicationSource(
    id: imaginistPublicationSource,
    name: '理想国 · 出版书目',
    kind: PublicationSourceKind.catalogue,
    catalogue: imaginistCatalogue,
    endpoint: imaginistEndpoint,
    website: imaginistHome,
    preferChineseSearch: true,
    license: '官方出版书目 · 在原站查看',
  ),
  PublicationSource(
    id: kanhaoshuPublicationSource,
    name: '看好书 · 公开书单',
    kind: PublicationSourceKind.catalogue,
    catalogue: KanhaoshuCatalogue.new,
    endpoint: kanhaoshuEndpoint,
    website: kanhaoshuHome,
    preferChineseSearch: true,
    license: '公开书单 · 显示逐书公布的城通网盘入口',
  ),
  PublicationSource(
    id: taoshudangPublicationSource,
    name: '淘书党 · 公开书目',
    kind: PublicationSourceKind.catalogue,
    catalogue: taoshudangCatalogue,
    endpoint: taoshudangHome,
    website: taoshudangHome,
    preferChineseSearch: true,
    license: '公开检索与书目详情 · 站方处理资源领取',
  ),
  PublicationSource(
    id: huiyankanPublicationSource,
    name: '慧眼看 · 推荐书目',
    kind: PublicationSourceKind.catalogue,
    catalogue: huiyankanCatalogue,
    endpoint: huiyankanEndpoint,
    website: huiyankanHome,
    preferChineseSearch: true,
    license: '原站公开推荐书目 · 在原站查看',
  ),
  PublicationSource(
    id: klibRankingPublicationSource,
    name: 'Klib · 微信读书热门标注榜',
    kind: PublicationSourceKind.catalogue,
    catalogue: KlibRankingCatalogue.new,
    endpoint: klibRankingPage,
    website: klibRankingPage,
    preferChineseSearch: true,
    license: '第三方榜单快照 · 离线搜索快照内书目',
  ),
  PublicationSource(
    id: daizhigePublicationSource,
    name: '殆知阁 · 古典文献',
    kind: PublicationSourceKind.catalogue,
    catalogue: daizhigeCatalogue,
    endpoint: daizhigeCataloguePage,
    website: daizhigeCataloguePage,
    preferChineseSearch: true,
    license: '公开古籍书目 · 离线检索 · 在原站阅读',
  ),
  PublicationSource(
    id: thinkingdomPublicationSource,
    name: '新经典文化 · 精选书目',
    kind: PublicationSourceKind.catalogue,
    catalogue: ThinkingdomCatalogue.new,
    endpoint: thinkingdomCataloguePage,
    website: thinkingdomCataloguePage,
    preferChineseSearch: true,
    license: '官方公开精选书目与作家代表作 · 在原站查看',
  ),
  PublicationSource(
    id: dookbookPublicationSource,
    name: '读客文化 · 精选书目',
    kind: PublicationSourceKind.catalogue,
    catalogue: DookbookCatalogue.new,
    endpoint: dookbookCataloguePage,
    website: dookbookCataloguePage,
    preferChineseSearch: true,
    license: '官方公开精选书目与作家代表作 · 显示站方公布的书目详情链接',
  ),
  PublicationSource(
    id: scienceReadingPublicationSource,
    name: '科学文库 · 出版书目',
    kind: PublicationSourceKind.catalogue,
    catalogue: scienceReadingCatalogue,
    endpoint: scienceReadingEndpoint,
    website: scienceReadingHome,
    preferChineseSearch: true,
    license: '官方公开书目 · 阅读与获取权限由原站提供',
  ),
  PublicationSource(
    id: ebookListPublicationSource,
    name: '书单 · EbookList',
    kind: PublicationSourceKind.catalogue,
    catalogue: EbookListCatalogue.new,
    endpoint: ebookListHome,
    website: ebookListHome,
    preferChineseSearch: true,
    license: '公开电子书目录 · 显示站方公布的公开网盘入口',
  ),
  PublicationSource(
    id: bookLinkPublicationSource,
    name: 'BookLink.Me · 小说索引',
    kind: PublicationSourceKind.catalogue,
    catalogue: BookLinkCatalogue.new,
    endpoint: bookLinkEndpoint,
    website: bookLinkHome,
    preferChineseSearch: true,
    license: '公开小说索引 · 书目与章节入口在原站查看',
  ),
  PublicationSource(
    id: dpdfPublicationSource,
    name: 'D-PDF · 公开书目',
    kind: PublicationSourceKind.catalogue,
    catalogue: dpdfCatalogue,
    endpoint: dpdfEndpoint,
    website: dpdfHome,
    license: '公开书目 · 下载由原站处理',
  ),
  PublicationSource(
    id: shirenPublicationSource,
    name: '中国诗人资料馆 · 中华诗库',
    kind: PublicationSourceKind.catalogue,
    catalogue: ShirenCatalogue.new,
    endpoint: shirenCataloguePage,
    website: shirenCataloguePage,
    preferChineseSearch: true,
    license: '公开诗库目录 · 离线检索 · 原站阅读和 PDF',
  ),
  PublicationSource(
    id: cdstmPublicationSource,
    name: '中国数字科技馆 · 科普阅读荟',
    kind: PublicationSourceKind.catalogue,
    catalogue: CdstmCatalogue.new,
    endpoint: cdstmCataloguePage,
    website: cdstmCataloguePage,
    preferChineseSearch: true,
    license: '官方公开书目 · 离线检索 · 站方公布的 PDF',
  ),
  PublicationSource(
    id: vorleserPublicationSource,
    name: 'Vorleser · 德语有声书与文本',
    kind: PublicationSourceKind.catalogue,
    catalogue: VorleserCatalogue.new,
    endpoint: vorleserEndpoint,
    website: vorleserHome,
    license: '公开有声书目录 · 原站音频与公开 PDF 文本',
  ),
  PublicationSource(
    id: hanjiPublicationSource,
    name: '漢籍全文資料庫 · 年度書目',
    kind: PublicationSourceKind.catalogue,
    catalogue: hanjiCatalogue,
    endpoint: hanjiCataloguePage,
    website: hanjiCataloguePage,
    preferChineseSearch: true,
    license: '中央研究院史語所公开年度书目 · 原站阅读',
  ),
  PublicationSource(
    id: pingshu365PublicationSource,
    name: '天天评书网',
    kind: PublicationSourceKind.catalogue,
    catalogue: pingshu365Catalogue,
    endpoint: pingshu365Endpoint,
    website: pingshu365Home,
    preferChineseSearch: true,
    license: '公开评书与有声小说书目 · 原站收听',
  ),
  PublicationSource(
    id: library361PublicationSource,
    name: '361 图书馆',
    kind: PublicationSourceKind.catalogue,
    catalogue: library361Catalogue,
    endpoint: library361Home,
    website: library361Home,
    preferChineseSearch: true,
    license: '公开图书书目 · 资源由原站提供',
  ),
  PublicationSource(
    id: shidianPublicationSource,
    name: '识典古籍',
    kind: PublicationSourceKind.catalogue,
    catalogue: shidianCatalogue,
    endpoint: shidianEndpoint,
    website: shidianHome,
    preferChineseSearch: true,
    license: '原站公开搜索书目 · 原站阅读',
  ),
  PublicationSource(
    id: hinabookPublicationSource,
    name: '后浪 · 官方商店书目',
    kind: PublicationSourceKind.catalogue,
    catalogue: HinabookCatalogue.new,
    endpoint: hinabookCataloguePage,
    website: hinabookCataloguePage,
    preferChineseSearch: true,
    license: '出版社官方商品书目 · 原站购书',
  ),
  PublicationSource(
    id: qianqiuPublicationSource,
    name: '千秋书在',
    kind: PublicationSourceKind.catalogue,
    catalogue: QianqiuCatalogue.new,
    endpoint: qianqiuEndpoint,
    website: qianqiuHome,
    preferChineseSearch: true,
    license: '公开书目 · 站方公布的游客分享',
  ),
  PublicationSource(
    id: shuzhouPublicationSource,
    name: '书舟搜索',
    kind: PublicationSourceKind.catalogue,
    catalogue: shuzhouCatalogue,
    endpoint: shuzhouEndpoint,
    website: shuzhouHome,
    preferChineseSearch: true,
    license: '公开分享索引 · 资源由网盘提供',
  ),
  PublicationSource(
    id: booklnPublicationSource,
    name: '书链 · 配套资源书目',
    kind: PublicationSourceKind.catalogue,
    catalogue: BooklnCatalogue.new,
    endpoint: booklnEndpoint,
    website: booklnHome,
    preferChineseSearch: true,
    license: '公开书籍元数据 · 配套资源由原站提供',
  ),
  PublicationSource(
    id: oalibPublicationSource,
    name: 'OA 图书馆 · 自有开放期刊',
    kind: PublicationSourceKind.catalogue,
    catalogue: OalibCatalogue.new,
    endpoint: oalibEndpoint,
    website: oalibHome,
    license: '开放期刊书目 · 出版方公开 PDF',
  ),
  PublicationSource(
    id: mitOcwPublicationSource,
    name: 'MIT OpenCourseWare · 课程资料',
    kind: PublicationSourceKind.catalogue,
    catalogue: MitOcwCatalogue.new,
    endpoint: mitOcwEndpoint,
    website: mitOcwHome,
    license: 'MIT 公开课程及讲义 · 依原站逐项授权',
  ),
  PublicationSource(
    id: modernHistoryPublicationSource,
    name: '抗战文献平台',
    kind: PublicationSourceKind.catalogue,
    catalogue: ModernHistoryCatalogue.new,
    endpoint: modernHistoryEndpoint,
    website: modernHistoryHome,
    preferChineseSearch: true,
    license: '公开文献索引 · 由原站管理阅览和获取权限',
  ),
  PublicationSource(
    id: tinynewsPublicationSource,
    name: '静思书屋',
    kind: PublicationSourceKind.catalogue,
    catalogue: TinynewsCatalogue.new,
    endpoint: tinynewsHome,
    preferChineseSearch: true,
    license: '公开图书详情 · 原站获取',
  ),
  PublicationSource(
    id: jb51PublicationSource,
    name: '脚本之家 · 电子书籍',
    kind: PublicationSourceKind.catalogue,
    catalogue: Jb51Catalogue.new,
    endpoint: jb51Home,
    preferChineseSearch: true,
    license: '公开电子书索引 · 原站公布的网盘入口',
  ),
  PublicationSource(
    id: cnpereadingPublicationSource,
    name: '中图易阅通',
    kind: PublicationSourceKind.catalogue,
    catalogue: CnpereadingCatalogue.new,
    endpoint: cnpereadingEndpoint,
    website: cnpereadingHome,
    preferChineseSearch: true,
    license: '公开书目 · 阅览权限由平台管理',
  ),
  PublicationSource(
    id: cadalPublicationSource,
    name: 'CADAL · 大学数字图书馆',
    kind: PublicationSourceKind.catalogue,
    catalogue: CadalCatalogue.new,
    endpoint: cadalEndpoint,
    website: cadalHome,
    preferChineseSearch: true,
    license: '公开馆藏书目 · 原站控制阅览与借阅',
  ),
  PublicationSource(
    id: huxiangPublicationSource,
    name: '湖湘文库',
    kind: PublicationSourceKind.catalogue,
    catalogue: HuxiangCatalogue.new,
    endpoint: huxiangEndpoint,
    website: huxiangHome,
    preferChineseSearch: true,
    license: '公开书目 · 原站控制阅览',
  ),
  PublicationSource(
    id: freeMagazinesSource,
    name: 'Free Magazines · 杂志索引',
    kind: PublicationSourceKind.catalogue,
    catalogue: FreeMagazinesCatalogue.new,
    endpoint: freeMagazinesHome,
    license: '公开期刊索引 · 原站提供获取方式',
  ),
  PublicationSource(
    id: aisixiangSource,
    name: '爱思想 · 学术文章',
    kind: PublicationSourceKind.catalogue,
    catalogue: AisixiangCatalogue.new,
    endpoint: aisixiangEndpoint,
    website: aisixiangHome,
    preferChineseSearch: true,
    license: '公开文章索引 · 原站阅览',
  ),
  PublicationSource(
    id: hepPublicationSource,
    name: '高教书苑',
    kind: PublicationSourceKind.catalogue,
    catalogue: HepCatalogue.new,
    endpoint: hepEndpoint,
    website: hepHome,
    preferChineseSearch: true,
    license: '高等教育出版社公开书目 · 原站控制阅览',
  ),
  PublicationSource(
    id: gujiguanPublicationSource,
    name: '古籍馆 · 古籍资源知识平台',
    kind: PublicationSourceKind.catalogue,
    catalogue: GujiguanCatalogue.new,
    endpoint: gujiguanEndpoint,
    website: gujiguanHome,
    preferChineseSearch: true,
    license: '公开古籍书目 · 原站控制阅览',
  ),
  PublicationSource(
    id: smartEduPublicationSource,
    name: '国家中小学智慧教育平台 · 电子教材',
    kind: PublicationSourceKind.catalogue,
    catalogue: SmartEduCatalogue.new,
    endpoint: smartEduHome,
    preferChineseSearch: true,
    license: '官方公开教材索引 · 原站控制阅览',
  ),
  PublicationSource(
    id: zglibrarySource,
    name: '藏书馆 · 博览群书',
    kind: PublicationSourceKind.catalogue,
    catalogue: zglibraryCatalogue,
    endpoint: zglibraryHome,
    preferChineseSearch: true,
    license: '公开书目 · 原站控制借阅与试读',
  ),
  PublicationSource(
    id: kindleComicsSource,
    name: '知道漫画补档',
    kind: PublicationSourceKind.catalogue,
    catalogue: kindleComicsCatalogue,
    endpoint: kindleComicsHome,
    preferChineseSearch: true,
    license: '公开漫画条目 · 原站控制详情与获取',
  ),
];

List<PublicationEdition> configuredPublicationRows(
  PublicationSource source,
  String data, {
  int maxRows = 5000,
  Uri? base,
}) {
  final origin = base ?? source.endpoint;
  final htmlSearch = source.kind == PublicationSourceKind.htmlSearch;
  final rows = _configuredRows(source, data, origin, maxRows);
  final results = <String, PublicationEdition>{};
  for (final row in rows.take(maxRows)) {
    Object? field(String key) {
      final selector = source.field[key];
      return htmlSearch
          ? row[key]
          : selector == null
          ? null
          : publicationJsonField(row, selector);
    }

    final title = publicationLabel(field('title'));
    if (title.isEmpty) continue;
    final author = publicationLabel(field('author'));
    final isbn = normalizedIsbn(publicationLabel(field('isbn')));
    final language = publicationLabel(field('language'));
    final edition = publicationLabel(field('edition'));
    final translator = publicationLabel(field('translator'));
    final page = _configuredAddress(
      source,
      field('page'),
      base: origin,
      allowQuery: source.rule != null,
    );
    final candidates = [
      for (final format in PublicationFormat.values)
        ?_configuredCandidate(
          source,
          field(format.name),
          format,
          page,
          base: origin,
          code: field('${format.name}Code'),
        ),
    ];
    final id = publicationId(
      [
        source.id,
        title,
        author,
        isbn,
        language,
        edition,
        translator,
        page,
        ...candidates.map((candidate) => candidate.link),
      ].join('\n'),
    );
    final previous = results[id];
    results[id] = previous == null
        ? PublicationEdition(
            id: id,
            title: title,
            author: author,
            isbn: isbn,
            edition: edition,
            language: language,
            translator: translator,
            license: publicationLabel(field('license') ?? source.license),
            cover: publicationCoverUrl(
              origin,
              field('cover'),
              (uri) => _allowedAddress(source, uri),
            ),
            page: page,
            candidates: candidates,
          )
        : previous.withCandidates(
            _mergeSourceCandidates(previous.candidates, candidates),
          );
  }
  if (results.isEmpty && rows.isNotEmpty) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  return results.values.toList(growable: false);
}

Iterable<Map> _configuredRows(
  PublicationSource source,
  String data,
  Uri origin,
  int maxRows,
) {
  if (source.kind == PublicationSourceKind.htmlSearch) {
    final elements = html.parse(data).querySelectorAll(source.rows);
    return elements.map(
      (row) => {
        for (final field in source.field.entries)
          field.key: _htmlValue(
            field.value,
            _rowField(row, source.rows, field.value.split('@').first),
            origin,
            shareText: PublicationFormat.values.any(
              (format) => format.name == field.key,
            ),
          ),
      },
    );
  } else {
    final json = jsonDecode(data);
    final list = source.rows.isEmpty
        ? json
        : publicationJsonField(json, source.rows);
    if (list is! List ||
        list.length > maxRows ||
        list.any((row) => row is! Map)) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    return list.cast<Map>();
  }
}

Uri? configuredNextPage(PublicationSource source, String data, Uri base) {
  final next = source.rule?.next;
  if (next == null) return null;
  final node = source.kind == PublicationSourceKind.htmlSearch
      ? html.parse(data)
      : jsonDecode(data);
  final raw = publicationRuleValue(node, next);
  if (raw is! String || raw.trim().isEmpty || raw.length > 4096) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null) return null;
  final address = base.resolveUri(uri).removeFragment();
  return _allowedAddress(source, address) ? address : null;
}

List<AcquisitionCandidate> configuredDetailCandidates(
  PublicationSource source,
  String data,
  Uri address,
) {
  final fields = source.rule?.detail;
  if (fields == null || fields.isEmpty) return const [];
  final node = source.kind == PublicationSourceKind.htmlSearch
      ? html.parse(data)
      : jsonDecode(data);
  Object? field(String key) {
    final selector = fields[key];
    if (selector == null) return null;
    return node is dom.Document
        ? _htmlValue(
            selector,
            node.querySelector(selector.split('@').first),
            address,
            shareText: PublicationFormat.values.any(
              (format) => format.name == key,
            ),
          )
        : publicationRuleValue(node, selector);
  }

  return [
    for (final format in PublicationFormat.values)
      ?_configuredCandidate(
        source,
        field(format.name),
        format,
        address,
        base: address,
        code: field('${format.name}Code'),
      ),
  ];
}

dom.Element? _rowField(dom.Element row, String rows, String selector) =>
    selector == rows || selector == row.localName
    ? row
    : row.querySelector(selector);

AcquisitionCandidate? _configuredCandidate(
  PublicationSource source,
  Object? raw,
  PublicationFormat format,
  Uri? page, {
  Uri? base,
  Object? code,
}) {
  final origin = base ?? source.endpoint;
  if (raw is! String || raw.trim().isEmpty || raw.length > 4096) return null;
  final text = raw.trim();
  final containsLink = containsPublicationShareLink(text);
  final direct = Uri.tryParse(text);
  final separateCode =
      code is String && RegExp(r'^[A-Za-z0-9]{1,16}$').hasMatch(code.trim())
      ? code.trim()
      : null;
  final plainLink = direct != null && !text.contains(RegExp(r'\s'));
  final access = publicationSourceShareInput(
    plainLink && separateCode != null
        ? '${origin.resolveUri(direct)}\n提取码: $separateCode'
        : plainLink && !containsLink
        ? origin.resolveUri(direct).toString()
        : text,
    (uri) =>
        PublicationShareProvider.of(uri).listsFiles &&
        _allowedAddress(source, uri),
  );
  if (access == null &&
      (text.contains(RegExp(r'[\r\n]')) ||
          (direct?.hasScheme != true && containsLink))) {
    return null;
  }
  final link = access?.link ?? _configuredAddress(source, raw, base: origin);
  if (link == null ||
      (access == null && PublicationShareProvider.of(link).listsFiles)) {
    return null;
  }
  return AcquisitionCandidate(
    source: source.id,
    link: link,
    format: format,
    page: page,
    publishedAccess: access,
  );
}

List<AcquisitionCandidate> _mergeSourceCandidates(
  List<AcquisitionCandidate> old,
  List<AcquisitionCandidate> updated,
) {
  final byId = {for (final candidate in old) candidate.id: candidate};
  for (final candidate in updated) {
    final previous = byId[candidate.id];
    final a = previous?.publishedAccess;
    final b = candidate.publishedAccess;
    if (previous == null || a == b) {
      byId.putIfAbsent(candidate.id, () => candidate);
      continue;
    }
    final confirm =
        a?.needsConfirmation == true ||
        b?.needsConfirmation == true ||
        a?.code != b?.code;
    byId[candidate.id] = AcquisitionCandidate(
      source: previous.source,
      link: previous.link,
      format: previous.format,
      page: previous.page,
      publishedAccess: (
        link: previous.link,
        code: confirm ? null : a?.code,
        zipPassword: a?.zipPassword == b?.zipPassword ? a?.zipPassword : null,
        pdfPassword: a?.pdfPassword == b?.pdfPassword ? a?.pdfPassword : null,
        needsConfirmation: confirm,
      ),
    );
  }
  return byId.values.toList(growable: false);
}

String? _htmlValue(
  String selector,
  dom.Element? element,
  Uri endpoint, {
  required bool shareText,
}) {
  if (element == null) return null;
  final fields = selector.split('@');
  if (fields.length > 1) return element.attributes[fields.last];
  if (!shareText) return element.text;
  final share = element.clone(true);
  Uri? destination;
  for (final anchor in [
    if (share.localName == 'a' && share.attributes.containsKey('href')) share,
    ...share.querySelectorAll('a[href]'),
  ]) {
    final href = anchor.attributes['href']!.trim();
    if (href.isEmpty || href.startsWith('#')) continue;
    final reference = Uri.tryParse(href);
    if (reference == null || href.length > 4096) return null;
    final address = endpoint.resolveUri(reference);
    if (address.hasFragment && address.removeFragment() == endpoint) continue;
    if (address.scheme != 'https' ||
        address.host.isEmpty ||
        address.userInfo.isNotEmpty ||
        (destination != null && destination != address)) {
      return null;
    }
    destination = address;
    if (_anchorDisplaysAddress(anchor.text.trim(), href, address)) {
      anchor.text = '';
    }
  }
  for (final line in share.querySelectorAll('br,p,li,div')) {
    line.nodes.add(dom.Text('\n'));
  }
  final text = share.text;
  if (destination == null) return text;
  if (PublicationShareProvider.of(destination).listsFiles ||
      containsPublicationShareLink(text)) {
    return '$destination\n$text';
  }
  return destination.toString();
}

bool _anchorDisplaysAddress(String label, String href, Uri address) {
  if (label == href) return true;
  final absolute = label.startsWith('${address.host}/')
      ? '${address.scheme}://$label'
      : label;
  final literal = address.toString();
  final stable = literal.split(RegExp(r'[?#]')).first;
  if (absolute == literal || absolute == stable) return true;
  final parts = absolute.split(RegExp(r'\.{3}|…'));
  return parts.length == 2 &&
      parts.first.isNotEmpty &&
      parts.last.isNotEmpty &&
      [literal, stable].any(
        (value) => value.startsWith(parts.first) && value.endsWith(parts.last),
      );
}

Uri? _configuredAddress(
  PublicationSource source,
  Object? raw, {
  Uri? base,
  bool allowQuery = false,
}) {
  final origin = base ?? source.endpoint;
  if (source.rule?.upgradeSameHostHttp == true &&
      raw is String &&
      raw.length <= 4096) {
    final candidate = Uri.tryParse(raw.trim());
    // Some authorized publishers still emit an HTTP link for the same file.
    // Construct the HTTPS URL before authorization or any network request.
    if (candidate != null &&
        candidate.scheme == 'http' &&
        candidate.host == source.endpoint.host &&
        candidate.port == 80 &&
        candidate.userInfo.isEmpty) {
      raw = candidate.replace(scheme: 'https', port: 443).toString();
    }
  }
  final uri = _publicAddress(origin, raw, allowQuery: allowQuery);
  return uri != null && _allowedAddress(source, uri) ? uri : null;
}

bool _allowedAddress(PublicationSource source, Uri uri) {
  try {
    validatePublicationAddress(uri);
    source.restrict(uri);
    return true;
  } on Exception {
    return false;
  }
}

Uri? _publicAddress(Uri origin, Object? raw, {bool allowQuery = false}) {
  if (raw is! String || raw.trim().isEmpty || raw.length > 4096) return null;
  try {
    final uri = origin.resolve(raw).removeFragment();
    validatePublicationAddress(uri);
    return uri.scheme == 'https' && (allowQuery || !uri.hasQuery) ? uri : null;
  } on Exception {
    return null;
  }
}
