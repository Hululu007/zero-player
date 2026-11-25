import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'share_text.dart';

enum PublicationFormat {
  epub('EPUB', 128 << 20),
  pdf('PDF', 512 << 20),
  zip('ZIP', 512 << 20),
  mobi('MOBI', 64 << 20),
  azw('AZW', 64 << 20),
  azw3('AZW3', 64 << 20);

  const PublicationFormat(this.label, this.maxBytes);
  final String label;
  final int maxBytes;

  bool get isKindle => this == mobi || this == azw || this == azw3;

  bool accepts(PublicationFormat? actual) =>
      actual == this || (isKindle && actual?.isKindle == true);

  String get mimeType => switch (this) {
    epub => 'application/epub+zip',
    pdf => 'application/pdf',
    zip => 'application/zip',
    mobi => 'application/x-mobipocket-ebook',
    azw => 'application/vnd.amazon.ebook',
    azw3 => 'application/vnd.amazon.mobi8-ebook',
  };

  static PublicationFormat? fromName(String name) => values
      .where((format) => name.toLowerCase().endsWith('.${format.name}'))
      .firstOrNull;
}

typedef PublicationSharedFile = ({
  String name,
  String? id,
  PublicationFormat format,
  int? bytes,
});

enum PublicationProblem {
  blocked('当前内容策略限制此操作'),
  missing('文件或分享已失效'),
  noPublishedResources('来源暂未公布可用下载入口'),
  emptyResponse('来源未返回下载文件'),
  unsupported('暂不支持此领取方式或文件格式'),
  tooManyCandidates('可用下载来源超过 32 个，请缩小渠道范围后重试'),
  shareFile('需要选择网盘文件'),
  shareCode('需要确认分享提取码'),
  zipPassword('需要正确的 ZIP 密码'),
  pdfPassword('需要正确的 PDF 密码'),
  ebookProtection('此 Kindle 文件有 DRM 保护'),
  challenge('来源要求网页验证'),
  login('来源要求登录'),
  guestLimit('文件超过来源的游客下载限制'),
  rateLimit('来源限流，请稍后重试'),
  timeout('来源响应超时，请稍后重试'),
  network('暂时无法访问来源'),
  metered('当前为计费网络，请在设置中允许下载后重试'),
  invalid('文件不完整或与所选格式/版本不符'),
  space('托管空间或设备可用空间不足'),
  systemWait('等待系统允许后台下载'),
  inUse('其他书目或阅读会话正在使用文件'),
  downloadSlotsBusy('下载任务繁忙，请等待当前任务完成或暂停后重试'),
  cloudOperationBusy('上一次网盘操作尚未结束'),
  taskUpdateFailed('无法更新下载任务，请重试'),
  directoryPermission('保存目录授权已失效，请重新选择目录'),
  directoryUnavailable('保存目录暂不可用，请检查或重新选择目录'),
  destinationConflict('同名文件已存在，请选择其他保存目录'),
  diskFull('磁盘空间不足，无法保存到指定目录'),
  storage('无法保存文件，请检查目录授权和磁盘空间');

  const PublicationProblem(this.label);
  final String label;
}

typedef PublicationSpaceShortfall = ({
  int requiredBytes,
  int availableBytes,
  int protectedBytes,
});

/// A published entry point. Its actual file and format may only be known
/// after the user opens it or lists the contents of a public share.
final class PublicationResource {
  const PublicationResource({
    required this.source,
    required this.link,
    required this.label,
    this.format,
    this.code,
    this.canListFiles = false,
  }) : lookupRequired = false;

  const PublicationResource.lookup({required this.source, required this.link})
    : label = '查看下载入口',
      format = null,
      code = null,
      canListFiles = false,
      lookupRequired = true;

  final String source, label;
  final Uri link;
  final PublicationFormat? format;
  final String? code;
  final bool canListFiles, lookupRequired;
}

final class PublicationFailure implements Exception {
  const PublicationFailure(this.problem, {this.retryAt, this.spaceShortfall});
  final PublicationProblem problem;
  final DateTime? retryAt;
  final PublicationSpaceShortfall? spaceShortfall;
  @override
  String toString() => problem.label;
}

String publicationId(String value) =>
    sha256.convert(utf8.encode(value)).toString();

bool isPublicationDigest(String value) =>
    RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

String normalizedIsbn(String raw) {
  final value = raw.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
  if (RegExp(r'^\d{9}[0-9X]$').hasMatch(value)) {
    var sum = 0;
    for (var i = 0; i < 10; i++) {
      sum += (value[i] == 'X' ? 10 : int.parse(value[i])) * (10 - i);
    }
    return sum % 11 == 0 ? value : '';
  }
  if (!RegExp(r'^97[89]\d{10}$').hasMatch(value)) return '';
  var sum = 0;
  for (var i = 0; i < 13; i++) {
    sum += int.parse(value[i]) * (i.isEven ? 1 : 3);
  }
  return sum % 10 == 0 ? value : '';
}

String publicationLabel(Object? value, {int max = 256}) {
  if (value is! String) return '';
  final label = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]+'), ' ').trim();
  return label.length <= max
      ? label
      : String.fromCharCodes(label.runes.take(max));
}

String publicationSearchQuery(String raw) => publicationLabel(raw, max: 160)
    .replaceFirstMapped(RegExp(r'^[《〈「『](.+)[》〉」』]$'), (match) => match[1]!)
    .trim();

enum PublicationSearchField { all, title, author, isbn }

final _searchWord = RegExp(r'[\p{L}\p{M}\p{N}]+', unicode: true);
final _nonAscii = RegExp(r'[^\x00-\x7f]');
final _hanSpacing = RegExp(
  r'(\p{Script=Han})\s+(?=\p{Script=Han})',
  unicode: true,
);

/// Field matching for a nonempty search across a remote or local catalogue.
final class PublicationFieldSearch {
  PublicationFieldSearch(this.field, String query, {this.hanFold = const {}})
    : isbn = field == PublicationSearchField.isbn ? normalizedIsbn(query) : '' {
    _terms = _searchWord
        .allMatches(_normalize(query))
        .map((match) => match[0]!)
        .toList(growable: false);
  }

  final PublicationSearchField field;
  final String isbn;
  final Map<int, int> hanFold;
  late final List<String> _terms;

  bool get valid => field == PublicationSearchField.isbn
      ? isbn.isNotEmpty
      : _terms.isNotEmpty;

  bool matches(PublicationEdition book) => matchesFields(
    title: book.title,
    author: book.author,
    isbn: book.isbn,
    alternateIsbns: book.alternateIsbns,
  );

  bool matchesFields({
    String title = '',
    String author = '',
    String isbn = '',
    Iterable<String> alternateIsbns = const [],
  }) {
    if (!valid) return false;
    if (field == PublicationSearchField.isbn) {
      // Compare the ten- and thirteen-digit forms of the same ISBN.
      final key = _isbnKey(this.isbn);
      bool same(String value) => _isbnKey(normalizedIsbn(value)) == key;
      return same(isbn) || alternateIsbns.any(same);
    }
    final text = switch (field) {
      PublicationSearchField.title => title,
      PublicationSearchField.author => author,
      PublicationSearchField.isbn => '',
      PublicationSearchField.all => '$title $author $isbn',
    };
    return _terms.every(_normalize(text).contains);
  }

  String _normalize(String text) {
    if (!_nonAscii.hasMatch(text)) return text.toLowerCase();
    final folded = String.fromCharCodes(
      text.runes.map((rune) {
        if (rune >= 0xFF01 && rune <= 0xFF5E) return rune - 0xFEE0;
        return hanFold[rune] ?? rune;
      }),
    ).toLowerCase();
    return folded.replaceAllMapped(_hanSpacing, (match) => match[1]!);
  }

  static String _isbnKey(String value) => switch (value.length) {
    10 => '978${value.substring(0, 9)}',
    13 => value.substring(0, 12),
    _ => '',
  };
}

/// This is the stable catalogue/link reference, never a negotiated download URL.
final class AcquisitionCandidate {
  const AcquisitionCandidate({
    required this.source,
    required this.link,
    required this.format,
    this.page,
    this.digest,
    this.bytes,
    this.fileId,
    this.sharedFileName,
    this.publishedAccess,
  });

  final String source;
  final Uri link;
  final PublicationFormat format;
  final Uri? page;
  final String? digest;
  final int? bytes;
  final String? fileId;
  final String? sharedFileName;

  /// Access text published by the configured source for this link.
  final PublicationShareInput? publishedAccess;

  String get id => publicationId('$source\n$link\n${format.name}\n$fileId');

  bool matchesSharedFile(PublicationSharedFile file) =>
      format == file.format &&
      (bytes == null || file.bytes == bytes) &&
      (sharedFileName == null || sharedFileName == file.name);

  AcquisitionCandidate withSharedFile(PublicationSharedFile file) {
    if (!matchesSharedFile(file)) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    return AcquisitionCandidate(
      source: source,
      link: link,
      format: format,
      page: page,
      digest: digest,
      bytes: file.bytes ?? bytes,
      fileId: file.id,
      sharedFileName: file.name,
      publishedAccess: publishedAccess,
    );
  }

  Map<String, Object?> toJson({bool includePublishedAccess = false}) => {
    'source': source,
    'link': link.toString(),
    'format': format.name,
    if (page != null) 'page': page.toString(),
    if (digest != null) 'digest': digest,
    if (bytes != null) 'bytes': bytes,
    if (fileId != null) 'file': fileId,
    if (sharedFileName != null) 'sharedFileName': sharedFileName,
    if (publishedAccess case final value?
        when includePublishedAccess && source != 'manual' && value.link == link)
      'publishedAccess': {
        if (value.code != null) 'code': value.code,
        if (value.zipPassword != null) 'zip': value.zipPassword,
        if (value.pdfPassword != null) 'pdf': value.pdfPassword,
        if (value.needsConfirmation) 'confirm': true,
      },
  };

  factory AcquisitionCandidate.fromJson(
    Map json, {
    bool includePublishedAccess = false,
  }) {
    final link = Uri.parse(json['link'] as String);
    final source = json['source'] as String;
    return AcquisitionCandidate(
      source: source,
      link: link,
      format: PublicationFormat.values.byName(json['format'] as String),
      page: json['page'] == null ? null : Uri.parse(json['page'] as String),
      digest: json['digest'] as String?,
      bytes: json['bytes'] as int?,
      fileId: json['file'] as String?,
      sharedFileName: json['sharedFileName'] as String?,
      publishedAccess: includePublishedAccess && source != 'manual'
          ? _publishedAccess(link, json['publishedAccess'])
          : null,
    );
  }
}

PublicationShareInput? _publishedAccess(Uri link, Object? value) {
  if (value is! Map) return null;
  final code = value['code'];
  final confirmation = value['confirm'] == true;
  String? password(String key) {
    final text = value[key];
    return text is String && text.length <= 256 && text.isNotEmpty
        ? text
        : null;
  }

  return (
    link: link,
    code:
        !confirmation &&
            code is String &&
            RegExp(r'^[A-Za-z0-9]{2,16}$').hasMatch(code)
        ? code
        : null,
    zipPassword: password('zip'),
    pdfPassword: password('pdf'),
    needsConfirmation: confirmation,
  );
}

final class PublicationEdition {
  const PublicationEdition({
    required this.id,
    required this.title,
    this.author = '',
    this.isbn = '',
    this.alternateIsbns = const [],
    this.language = '',
    this.translator = '',
    this.edition = '',
    this.license = '',
    this.description = '',
    this.publisher = '',
    this.rating = '',
    this.cover,
    this.tags = const [],
    this.page,
    this.candidates = const [],
    this.resources = const [],
  });

  final String id, title, author, isbn, language, translator, edition, license;
  final String description, publisher, rating;
  final List<String> tags, alternateIsbns;
  final Uri? page, cover;
  final List<AcquisitionCandidate> candidates;
  final List<PublicationResource> resources;

  bool get hasDownload => candidates.isNotEmpty || resources.isNotEmpty;

  String get workKey => '${title.toLowerCase()}\n${author.toLowerCase()}';
  String get searchable =>
      '$title $author $isbn ${tags.join(' ')}'.toLowerCase();

  bool matches(String query, {PublicationFieldSearch? filter}) {
    if (filter != null) return filter.matches(this);
    final isbnQuery = normalizedIsbn(query);
    if (isbnQuery.isNotEmpty) return isbnQuery == isbn;
    return query.toLowerCase().split(RegExp(r'\s+')).every(searchable.contains);
  }

  bool confirmsSameEdition(PublicationEdition other) =>
      id == other.id ||
      (isbn.isNotEmpty &&
          isbn == other.isbn &&
          workKey == other.workKey &&
          language.isNotEmpty &&
          language == other.language &&
          edition.isNotEmpty &&
          edition == other.edition &&
          translator == other.translator);

  PublicationEdition withCandidates(
    List<AcquisitionCandidate> items, {
    String? license,
  }) => PublicationEdition(
    id: id,
    title: title,
    author: author,
    isbn: isbn,
    alternateIsbns: alternateIsbns,
    language: language,
    translator: translator,
    edition: edition,
    license: license ?? this.license,
    description: description,
    publisher: publisher,
    rating: rating,
    cover: cover,
    tags: tags,
    page: page,
    candidates: items,
    resources: resources,
  );

  Map<String, Object?> toJson({bool includePublishedAccess = false}) => {
    'id': id,
    'title': title,
    'author': author,
    'isbn': isbn,
    if (alternateIsbns.isNotEmpty) 'alternateIsbns': alternateIsbns,
    'language': language,
    'translator': translator,
    'edition': edition,
    'license': license,
    if (description.isNotEmpty) 'description': description,
    if (publisher.isNotEmpty) 'publisher': publisher,
    if (rating.isNotEmpty) 'rating': rating,
    if (cover != null) 'cover': cover.toString(),
    'tags': tags,
    if (page != null) 'page': page.toString(),
    'candidates': [
      for (final item in candidates)
        item.toJson(includePublishedAccess: includePublishedAccess),
    ],
  };

  factory PublicationEdition.fromJson(
    Map json, {
    bool includePublishedAccess = false,
  }) => PublicationEdition(
    id: json['id'] as String,
    title: json['title'] as String,
    author: json['author'] as String? ?? '',
    isbn: json['isbn'] as String? ?? '',
    alternateIsbns: (json['alternateIsbns'] as List? ?? const [])
        .cast<String>(),
    language: json['language'] as String? ?? '',
    translator: json['translator'] as String? ?? '',
    edition: json['edition'] as String? ?? '',
    license: json['license'] as String? ?? '',
    description: json['description'] as String? ?? '',
    publisher: json['publisher'] as String? ?? '',
    rating: json['rating'] as String? ?? '',
    cover: switch (json['cover']) {
      final String value => Uri.tryParse(value),
      _ => null,
    },
    page: json['page'] == null ? null : Uri.parse(json['page'] as String),
    tags: (json['tags'] as List? ?? const []).cast<String>(),
    candidates: [
      for (final item in json['candidates'] as List? ?? const [])
        AcquisitionCandidate.fromJson(
          item as Map,
          includePublishedAccess: includePublishedAccess,
        ),
    ],
  );
}
