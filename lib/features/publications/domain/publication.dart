import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'share_text.dart';

enum PublicationFormat {
  epub('EPUB', 128 << 20),
  pdf('PDF', 512 << 20),
  zip('ZIP', 512 << 20);

  const PublicationFormat(this.label, this.maxBytes);
  final String label;
  final int maxBytes;

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
  unsupported('暂不支持此领取方式或文件格式'),
  shareFile('需要选择网盘文件'),
  shareCode('需要确认分享提取码'),
  zipPassword('需要正确的 ZIP 密码'),
  pdfPassword('需要正确的 PDF 密码'),
  challenge('来源要求网页验证'),
  login('来源要求登录'),
  guestLimit('文件超过来源的游客下载限制'),
  rateLimit('来源限流，请稍后重试'),
  network('暂时无法访问来源'),
  invalid('文件不完整或与所选格式/版本不符'),
  space('托管空间或设备可用空间不足'),
  systemWait('等待系统允许后台下载'),
  inUse('其他书目或阅读会话正在使用文件'),
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
    this.language = '',
    this.translator = '',
    this.edition = '',
    this.license = '',
    this.tags = const [],
    this.page,
    this.candidates = const [],
  });

  final String id, title, author, isbn, language, translator, edition, license;
  final List<String> tags;
  final Uri? page;
  final List<AcquisitionCandidate> candidates;

  String get workKey => '${title.toLowerCase()}\n${author.toLowerCase()}';
  String get searchable =>
      '$title $author $isbn ${tags.join(' ')}'.toLowerCase();

  bool matches(String query) {
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

  PublicationEdition withCandidates(List<AcquisitionCandidate> items) =>
      PublicationEdition(
        id: id,
        title: title,
        author: author,
        isbn: isbn,
        language: language,
        translator: translator,
        edition: edition,
        license: license,
        tags: tags,
        page: page,
        candidates: items,
      );

  Map<String, Object?> toJson({bool includePublishedAccess = false}) => {
    'id': id,
    'title': title,
    'author': author,
    'isbn': isbn,
    'language': language,
    'translator': translator,
    'edition': edition,
    'license': license,
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
    language: json['language'] as String? ?? '',
    translator: json['translator'] as String? ?? '',
    edition: json['edition'] as String? ?? '',
    license: json['license'] as String? ?? '',
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
