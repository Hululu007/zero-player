import 'dart:convert';

import 'package:html/parser.dart' as html;

import 'package:html/dom.dart' as dom;
import '../domain/publication.dart';
import '../domain/share_text.dart';
import 'publication_http.dart';
import 'publication_rule_options.dart';
import 'publication_share_provider.dart';

enum PublicationSourceKind {
  releases,
  openTextbooks,
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
    this.license = '',
    this.enabledByDefault = false,
    this.rows = '',
    this.field = const {},
    this.hosts = const [],
    this.parameter = 'q',
    this.pageParameter = 'page',
    this.rule,
  });

  final String id, name, license, rows, parameter, pageParameter;
  final PublicationSourceKind kind;
  final bool enabledByDefault;
  final Uri endpoint;
  final List<String> hosts;
  final Map<String, String> field;
  final PublicationRuleOptions? rule;
  bool get configurable => const {
    PublicationSourceKind.snapshot,
    PublicationSourceKind.jsonSearch,
    PublicationSourceKind.htmlSearch,
  }.contains(kind);
  bool get restricted => kind == PublicationSourceKind.restrictedDirectory;

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
        raw['title'] is! String ||
        raw.length > (version == 2 ? 15 : 12) ||
        raw.entries.any(
          (entry) =>
              !{
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
                if (version == 2) ...{'epubCode', 'pdfCode', 'zipCode'},
              }.contains(entry.key) ||
              entry.value is! String ||
              (entry.value as String).isEmpty ||
              !validSelector(entry.value as String),
        ) ||
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

final builtinPublicationSources = [
  PublicationSource(
    id: 'rust-zh',
    name: 'Rust 简体中文社区',
    kind: PublicationSourceKind.releases,
    endpoint: Uri.parse(
      'https://github.com/KaiserY/trpl-zh-cn/tree/2a9740644f678cafbc48786d00b67927fc0e1b3c',
    ),
    license: 'MIT',
    enabledByDefault: true,
  ),
  PublicationSource(
    id: 'pro-git',
    name: 'Pro Git 官方版本',
    kind: PublicationSourceKind.releases,
    endpoint: Uri.parse(
      'https://github.com/progit/progit2-zh/releases/tag/2.1.79',
    ),
    license: 'CC BY-NC-SA 3.0',
    enabledByDefault: true,
  ),
  PublicationSource(
    id: 'open-textbooks',
    name: 'Open Textbook Library',
    kind: PublicationSourceKind.openTextbooks,
    endpoint: Uri.parse('https://open.umn.edu/opentextbooks/textbooks.json'),
    license: '目录 CC0，图书按条目标注',
    enabledByDefault: true,
  ),
  PublicationSource(
    id: 'ebook-treasure-chest',
    name: '书目宝库',
    kind: PublicationSourceKind.restrictedDirectory,
    endpoint: Uri.parse(
      'https://github.com/jbiaojerry/ebook-treasure-chest/tree/93cf3ffcf5a2e6814644d1747a101272557d7eac',
    ),
    license: '公开目录，获取及使用条件待确认。图书授权以原发布方为准。',
  ),
];

PublicationEdition pinnedPublication(PublicationSource source) =>
    source.id == 'rust-zh' ? _rustChinese(source) : _proGitChinese(source);

void restrictPinnedPublication(PublicationSource source, Uri target) {
  final hosts = source.id == 'rust-zh'
      ? const {'raw.githubusercontent.com'}
      : const {'github.com', 'release-assets.githubusercontent.com'};
  if (target.scheme != 'https' ||
      target.port != 443 ||
      !hosts.contains(target.host)) {
    throw const PublicationFailure(PublicationProblem.unsupported);
  }
}

PublicationEdition _rustChinese(PublicationSource source) => PublicationEdition(
  id: publicationId('trpl:2a9740644f678cafbc48786d00b67927fc0e1b3c:zh-Hans'),
  title: 'Rust 程序设计语言',
  author: 'Steve Klabnik、Carol Nichols、Chris Krycho',
  translator: 'Rust 中文社区',
  language: '简体中文',
  edition: '2024 Edition',
  tags: const ['Rust', '系统编程'],
  license: source.license,
  page: source.endpoint,
  candidates: [
    AcquisitionCandidate(
      source: source.id,
      page: source.endpoint,
      format: PublicationFormat.epub,
      bytes: 1115434,
      digest:
          'c7b1f9d5abaf7cca57d7f0ce28823734fa8ebd5de5d516db127bf0145b8cf132',
      link: Uri.parse(
        'https://raw.githubusercontent.com/KaiserY/trpl-zh-cn/2a9740644f678cafbc48786d00b67927fc0e1b3c/rust_programming_language.epub',
      ),
    ),
  ],
);

PublicationEdition _proGitChinese(
  PublicationSource source,
) => PublicationEdition(
  id: publicationId('progit:2.1.79:zh-Hans'),
  title: 'Pro Git（Git 权威指南）',
  author: 'Scott Chacon、Ben Straub',
  language: '简体中文',
  edition: '第 2 版 · 2.1.79',
  license: source.license,
  tags: const ['Git', '版本控制', '编程'],
  page: source.endpoint,
  candidates: [
    for (final (format, bytes, hash) in const [
      (
        PublicationFormat.epub,
        13946296,
        'f3688b93dac8a97790fe46504d05d4592abf5c4abc4b63b34157efa098d82206',
      ),
      (
        PublicationFormat.pdf,
        20131418,
        '14a7ca742aeb3327a11eb7b19e3f62c321f091b71fe119ee562bce7197588eaa',
      ),
    ])
      AcquisitionCandidate(
        source: source.id,
        format: format,
        bytes: bytes,
        digest: hash,
        page: source.endpoint,
        link: Uri.parse(
          'https://github.com/progit/progit2-zh/releases/download/2.1.79/progit.${format.name}',
        ),
      ),
  ],
);

List<PublicationEdition> openTextbookRows(
  PublicationSource source,
  String document,
) {
  final payload = jsonDecode(document);
  if (payload is! Map || payload['data'] is! List) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  return [
    for (final row in (payload['data'] as List).take(60))
      if (row is Map &&
          row['id'] is int &&
          publicationLabel(row['title']).isNotEmpty)
        _openTextbook(source, row),
  ];
}

PublicationEdition _openTextbook(PublicationSource source, Map row) {
  final page = _publicAddress(source.endpoint, row['url']);
  final authors = <String>[];
  final translators = <String>[];
  for (final person
      in (row['contributors'] as List? ?? const []).take(32).whereType<Map>()) {
    final contribution = person['contribution'];
    if (contribution != 'Author' && contribution != 'Translator') continue;
    final name = ['first_name', 'middle_name', 'last_name']
        .map((key) => publicationLabel(person[key], max: 80))
        .where((value) => value.isNotEmpty)
        .join(' ');
    if (name.isEmpty) continue;
    (contribution == 'Translator' ? translators : authors).add(name);
  }
  final link = switch (row['id']) {
    43 => Uri.parse('https://greenteapress.com/thinkpython2/thinkpython2.pdf'),
    677 => Uri.parse('https://inventwithpython.com/makinggames.pdf'),
    _ => null,
  };
  return PublicationEdition(
    id: publicationId('${source.id}:${row['id']}'),
    title: publicationLabel(row['title']),
    author: publicationLabel(authors.join('、')),
    translator: publicationLabel(translators.join('、')),
    isbn: normalizedIsbn(publicationLabel(row['isbn13'] ?? row['isbn10'])),
    license: publicationLabel(row['license']),
    language: publicationLabel(row['language']),
    edition: publicationLabel(row['edition_statement']),
    page: page,
    candidates: [
      if (link != null)
        AcquisitionCandidate(
          source: source.id,
          link: link,
          page: page,
          format: PublicationFormat.pdf,
        ),
    ],
  );
}

List<PublicationEdition> configuredPublicationRows(
  PublicationSource source,
  String data, {
  int maxRows = 5000,
  Uri? base,
}) {
  final origin = base ?? source.endpoint;
  final Iterable<Map> rows;
  final htmlSearch = source.kind == PublicationSourceKind.htmlSearch;
  if (htmlSearch) {
    final elements = html.parse(data).querySelectorAll(source.rows);
    rows = elements.map(
      (row) => {
        for (final field in source.field.entries)
          field.key: _htmlValue(
            field.value,
            row.querySelector(field.value.split('@').first),
            origin,
            shareText: const {'epub', 'pdf', 'zip'}.contains(field.key),
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
    rows = list.cast<Map>();
  }
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
    final page = _configuredAddress(source, field('page'), base: origin);
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
  Object? field(String key) =>
      fields[key] == null ? null : publicationRuleValue(node, fields[key]!);
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

Uri? _configuredAddress(PublicationSource source, Object? raw, {Uri? base}) {
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
  final uri = _publicAddress(origin, raw);
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

Uri? _publicAddress(Uri origin, Object? raw) {
  if (raw is! String || raw.trim().isEmpty || raw.length > 4096) return null;
  try {
    final uri = origin.resolve(raw).removeFragment();
    validatePublicationAddress(uri);
    return uri.scheme == 'https' && !uri.hasQuery ? uri : null;
  } on Exception {
    return null;
  }
}
