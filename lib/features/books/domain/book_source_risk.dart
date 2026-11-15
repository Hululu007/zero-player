import '../../supervision/domain/content_classification.dart';
import 'book.dart';
import 'known_untrusted_book_rules.dart';

// These hosts have specifically adult-labelled entries in the bundled Legado
// snapshot. This is source metadata evidence, not a claim about today's site.
// An ambiguous host used by both general and labelled sources is not added.
const _adultBookHosts = {
  '18mh.cc', // 十八禁漫
  'ikanhm.top', // 爱看韩漫🔞
  'lcmhx.asia', // 乐成漫画🔞
  'roum26.xyz', // 肉漫屋
  'jpxgyw.cc', // 性感美女网
  'nvyoumh01.top', // 嘿咻漫画
  'crxs.me', // 成人小说网
  'rouwennp.club', // 肉文NP，书源分组明确标记 🔞
};

const _adultExactBookHosts = {
  'www.favcomic.xyz', // Homepage explicitly labels itself adult comics
  'sesebooks.com', // Homepage identifies the site as adult novels
  'm.po18wen.xyz', // Homepage describes the site as 18+ only
  'm.xyuzhaiwu.xyz', // Homepage describes adult novels as a primary offering
  'mm.xyuzhaiwu.xyz', // Separately checked sibling host, same description
  'm.rousewu.cc', // Homepage describes adult novels as a primary offering
  'm.3322t.com', // Homepage describes adult novels as a primary offering
  'm.xyuzhaiwu5.com', // Homepage explicitly promotes adult novels
  'm.aaread.club', // Homepage explicitly labels itself an adult-novel site
};

// Same-ID records in the bundled snapshot carry explicit 🔞 metadata, but the
// latest duplicate omits it. Keep that evidence on the precise source ID,
// not every variant hosted by the same domain. See the bundled-source audit.
const _adultBundledSourceIds = {
  'f670f04810ccca4af8ffc8321a4b177747dac12a1a98a3d8162387a48413016c', // 绿竹
  'fd43c18e3b6b2020f3f7823c48ae7691362f156e2c3b3a1523d5a7fb5c1bbfbf', // 肉书屋
  '11880289e42a01f4c52b6dcbea27624ec633b4bea97347d3340bba4b3ac439b7', // 逆鳞
  'fe3bbae11dcbc603cd90368e1e4b21465143215a56b8b70a92def6d7c281fcad', // 龙腾
  '1de6d8be1459bb1df6991b86d63e4dd782ff8bb1806fd6c6f09a5e569bc722cc', // 老王
  'ab6a00f7cfbbb78e58a0922af47eceb3250621464cf7ee5113284dde19f9308c', // 书耽
  '08f7d73d1549f1df13d49bfb0bf99e7a5c1e21e485111ae775b9ce3e70690dbf', // 靠谱
  '7df90d3beaf532252f0021e506f357948791a895ccaf02e1f39b28aa3a824d6c', // 肉肉屋
  'f9ffbe0993c187ab5f33b9616f653318b0fc14c7ba93376aea19430eaff709bc', // 搜小说
  '0c6317e420614be60b383b06e99c8967ed905eb88a604a5c82baf1b25e0d078f', // 鄱阳镇庭
};

bool adultBundledSourceId(String id) => _adultBundledSourceIds.contains(id);

// HEAD / on 2026-11-15 returned off-site redirects to survey, unrelated, or
// domain-parking hosts. These old catalog addresses need re-review before use.
const _quarantinedBookHosts = {
  'jpxgyw.cc', // 302 http://surveymrs.com
  'yeseimg.com', // 302 http://survey-twist.com
  'kukk.net', // 301 https://esp-framework.com/
  'bdido.com', // 302 HugeDomains parking page
};

// These observations concern only the exact host that was checked. Do not
// infer the status of a sibling host under the same registered domain.
const _quarantinedExactBookHosts = {
  '51xs.site', // GET /: Parking Landing (2026-11-15, repeated)
  'm.60ks.com', // Repeated 302 to HugeDomains (2026-11-15)
  'www.350book.com', // Repeated 302 to HugeDomains (2026-11-15)
  'www.8boo.com', // Repeated 302 to HugeDomains (2026-11-15)
  'www.ggdownxs.com', // Repeated 302 to HugeDomains (2026-11-15)
  'book.tiexue.net', // Reading service closed; announcement (2026-11-15)
  'www.wuxia.net.cn', // Homepage changed; previous catalog path is 404
  'www.qingmo.net', // Homepage changed; previous catalog path is 404
  'www.iqb8.cc', // Homepage changed; previous catalog path is 404
  'www.hjgzf.com', // Homepage changed; previous catalog path is 404
};

// These source IDs have a known old rule that fetched and evaluated remote
// code. Only use the IDs to restrict orphaned historical books whose original
// rules are no longer available: another version with the same ID may differ.
const _quarantinedBookHistoryIds = {
  '189005cdc6f87066c066d01d70ff438def72eabd4324fdf6ece078bc40b7150d',
  '5b56c06bef1c17d73dc6417d6367f80c72cbf7d8ce516e58dbefe62a523d7bb9',
  'd549d6282a2b8eeb609ed61376fe93fcaa400a09614a994d0705919738b707c6',
  'b93c0a8a265ceb43b192c5088f8e1f5f66822d7c67f46ac7c1c95ed7d05e0908', // 12
  '932d2ee762eb57c7a883693de8365cc3c8c90d3912e308e9f83a27c1c37be847', // 190
  '7a28639044b5e51d9a10a29af07d3c271f1b6bb669563e76b21b0ea655e08cd0', // 192
  'e76f2b4aab87c5230acd0cdcf5b505ce245028b5dcb7f95118a4826c161862a6', // 1066
  'c5a61aaf895920956daeb6c5d98f359bbbc8e10817d18c8e8dca3be8f5b554de', // 1227
  'c729cacd51b1a7b0206da191860e280572cddc57bb9ce2d5d41447a7b89edc82', // 1794
  '8a0a93a7b076441b2a4fa620b7d3029f8f1e550d1ffdb7ba66b41a39e21fb8d8', // 2176
  '7f363e8297495506f43a5bc548143c69c868dc47d26eef54e35e9c8d315597dc', // 3067
  '87bbe3f9815a4b29df053bed743d3277e3edcb124005d8fe3f03f487db3d0c8e', // 3322
  'e34ec8773a9504c0d2ecd8fd34426aeeb25cfa8862ea602b9315fca4cace1fe9', // 3926
  'ea6552b459b382df81cfb628141fb764bb5c5f3aab07dba59f3ba00eec5eec58', // 3973
  'e0a87815850a94f8d9d43e9bea15de0432d5808f185010532ff13f6dd8a6c8fe', // 4813
  'e4478855eb2b4b0fea080a6ec8db6768baf313d957c15eb2d206e0de2a8855ae', // 4826
  '4b71a54fd5ba1e8077fd5687e123ef0731b8f4baeef8b75d1ac4b93b9906a3b3', // 3836
  'a5c8022ce65de27681d680432f8b01c2b2e09d22ed4633f372f8d98250912e22', // 1228
  '98fcf05ed0532fbc1b454978342e175778dca19487b035e9de343a51db344bde', // 3219
  'b37f63bfa731a939acc214b41916fb8bd0dc4f1c599343f397fc3e779feef2ad', // 2128
  '6925366f12c659540daf91385af2b0d10441116246abd442a2e62417e38d1ae0', // 3760
  'b707317ac37705c041f1a9bdd3fec93bff4200fe80a0ad1687a924e211173e83', // 4156
  'a1e51933faa330fd4664297f43dbfd6cdff594dcf59a1d42bfc2b32a951574c6', // 4159
  'c2ec652cb7d1e3eacdee18897a94f498180ffab56185395df6d099d60f72cc59', // 2136
  'c45aa7e0e9ad3450d57420b320887208945760a777c7fd1c4a63009bab5ebd5e', // 4052
  'a671019d19e09c5e8342a3a199fb865bcd21356b573e38934a92dad76988affa', // 4161
  '76c77d9b49f6e4b12b8f5cebc48bb47e4020eac687bb2ef7eb2252c300f60757', // 4046
  '7c219f964cd8a9189e9d9597243d1f08866f6155fa1cd8d25ca8fd267b67fb85', // 3995
  'c6a680ad8ca5c05ff54d21a1be6295ee51d5f963018d5f366f6685010c5c657e', // 4019
  '8075d0bcb1cc3a709cb3fbaa614deec6852eabf05bff1674bf38e92723c0f0b5', // 662
  '4ba1ee353fc2132f9b0c4e13258c320bd3689f37a6b3a5afc7cc276e8f2522a4', // 1432
  '7426fb7a612a3315369a52e7176803b1bc2987de78c74fb3a6a660d978e3ec9b', // 3460
  '00c58ffd3786544397500cc86d6e718e4ca3b5fd569149dd0aea3452bcaa229a', // 189
  '872cc5219ae17bfbc413644baa65b23c21507d7faa4238f269c6ea3ff9dbb179', // 627
  '0c6317e420614be60b383b06e99c8967ed905eb88a604a5c82baf1b25e0d078f', // 2247
  '75ed9d690c94355f14bafde3be0cbd8c1eda6f03377cea4d226cf3c90359e642', // 4840
  '168853d703930d0ba6a36a98171ef4c8358ba5e11a1edeffec024cc267c4d79b', // 4090
  '81b5e9abb41ac6f954d1463131b8c2eb3dff978ddc8fe41d5576039a8984b493', // 4152
  '9f37dae32a1e887ccd87f99fdd82b03b0f01eaab91a55f39801d3fa645f1d3b3', // 4153
  '05deac0477e3afe63fb2767a1a893a01f7fcc4635a3b22fa11e36e07eb529035', // 4157
  '330b455a1e55345c266e9fd68eb8a0857a686d7df76ddc52616d89a2ea945d85', // 4158
  '31683e41bed33261bc4e6a64b7dd0b256a76bfefc3ea835b39b7e35a596001c4', // 4221
  '4b0ec0be6dad7da09ae3d8b549300a0135032595108ff11c5b6910977ae1a592', // 4559
  'bfc909dad4bafa2c0d84645fae168ffe942e35ac3d7fa55caefb9ed57d236d20', // 4579
  '83842c07ccfa0551e6ecc41f653f7d41339560df994a8d81ccadb48858f92852', // 4665
  '55bae9ff93543b52d278ed88d5935d16bc64b85b915ff6555f4b5179e87901ac', // 4712
  'c7189c3677f1a8769025b6b7fb860965e6062d4d87988829447cb762900023d7', // 4762
  '924ae7d6b668f0e1eb7447fec63defd4ddff4163107b3b56697688add09f1ed6', // 4271
  'd711545a4170d4839f9018c07f9fba452fb131f3d5bf0a9fe9aa0793947f3181', // 4278
  '0165ccae84fe72d64f57b258b38cd2a30b31d3a910f872f920e9b00efa6ceeb1', // 4317
};

// Bundled record 1803: the exact source entry has no DNS answer and its
// search rules require a different, undeclared host. This is an unavailable
// legacy source, not a malware finding about Lofter or its real domains.
const _unavailableLegacySourceId =
    '9671fd3cfe8189b9abdcb097cbff01609ff14c7ab43dcf7aa10d48a34a526a05';
const _unavailableFqxsSourceId =
    'be6ee767dad9892aa5a286ba08866f11c2b8e6b04f580878f753daaea048f61c';

bool quarantinedBookSourceId(String id) =>
    _quarantinedBookHistoryIds.contains(id) ||
    id == _unavailableLegacySourceId ||
    id == _unavailableFqxsSourceId;

bool _unavailableLegacySource(BookSource source) {
  final uri = source.endpoint;
  return source.id == _unavailableLegacySourceId &&
      source.kind == BookKind.text &&
      source.format == BookFormat.html &&
      uri.scheme == 'https' &&
      uri.host == 'newsmiss.lofter.com1' &&
      (uri.path.isEmpty || uri.path == '/') &&
      !uri.hasQuery;
}

// This exact old source now resolves to a movie site and both its novel
// discovery and search paths repeatedly returned soft 404 pages. A revised
// rule is not automatically blocked, and this is not a malware finding.
bool knownUnavailableBookRule(BookSource source) =>
    source.id == _unavailableFqxsSourceId &&
    source.kind == BookKind.text &&
    source.endpoint.host == 'm.fqxs123.com' &&
    source.legado?.search == '/s?q={{key}},{\n  "webView": true\n}' &&
    source.legado?.rules['searchList'] == 'class.item' &&
    source.legado!.categories.any(
      (item) => item.address.contains('/xuanhuan/'),
    );

bool _hasKnownRemoteCodeRule(BookSource source) {
  final legado = source.legado;
  if (legado == null) return false;
  final fragments = [legado.library, ...legado.rules.values];
  return fragments.any(
    (rule) =>
        rule.contains('global.wesrc') &&
        rule.contains('Packages.okhttp3') &&
        rule.contains('yck.hr7t4h.cn/yck/funcs') &&
        rule.contains('Base64.decode') &&
        RegExp(r'\beval\s*\(').hasMatch(rule),
  );
}

String _normalizedHost(String host) =>
    host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');

bool _matchesHost(String host, Set<String> domains) {
  final normalized = _normalizedHost(host);
  return domains.any(
    (domain) => normalized == domain || normalized.endsWith('.$domain'),
  );
}

bool quarantinedBookHost(String host) =>
    _matchesHost(host, _quarantinedBookHosts) ||
    _quarantinedExactBookHosts.contains(_normalizedHost(host));

bool knownUnsafeBookRule(BookSource source) =>
    _hasKnownRemoteCodeRule(source) || knownUntrustedBookRule(source);

bool quarantinedBookSource(BookSource source) =>
    quarantinedBookHost(source.endpoint.host) ||
    _unavailableLegacySource(source) ||
    knownUnavailableBookRule(source) ||
    knownUnsafeBookRule(source);

bool quarantinedComicSource(BookSource source) =>
    source.kind == BookKind.comic && quarantinedComicHost(source.endpoint.host);

bool quarantinedComicHost(String host) => quarantinedBookHost(host);

bool adultBookHost(String host) =>
    _matchesHost(host, _adultBookHosts) ||
    _adultExactBookHosts.contains(_normalizedHost(host));

bool adultComicHost(String host) => adultBookHost(host);

/// Explicit publisher metadata applies to all book kinds. Terms such as BL,
/// romance and Korean comics alone do not classify an entire source as adult.
bool adultBookLabels(String name, String group) =>
    name.contains('🔞') ||
    group.contains('🔞') ||
    RegExp(r'成人小说|成人小說|色情小说|色情小說|肉文|肉漫|性感美女|嘿咻').hasMatch('$name $group') ||
    adultContent(name) ||
    adultContent(group, category: true);

bool adultBookSource(BookSource source) =>
    adultBookHost(source.endpoint.host) ||
    adultBundledSourceId(source.id) ||
    source.adultEvidence ||
    adultBookLabels(source.name, source.group);

bool adultComicSource(BookSource source) {
  if (source.kind != BookKind.comic) return false;
  return adultBookSource(source);
}
