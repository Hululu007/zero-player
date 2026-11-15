import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../domain/book.dart';

/// Identity and exact configuration of both ends of an offline download.
/// A fingerprint identifies a revision; it does not certify its content.
String bookDownloadSourceFingerprint(BookSource source) =>
    sha256.convert(utf8.encode(jsonEncode(source.toJson()))).toString();

final class BookDownloadEvidence {
  const BookDownloadEvidence({
    required this.target,
    required this.targetChapter,
    required this.targetFingerprint,
    required this.targetEpoch,
    required this.origin,
    required this.originChapter,
    required this.originFingerprint,
    required this.originEpoch,
  });

  final Book target, origin;
  final BookChapter targetChapter, originChapter;
  final String targetFingerprint, originFingerprint;
  final int targetEpoch, originEpoch;

  bool describes(Book book, BookChapter chapter) =>
      target.id == book.id &&
      target.sourceId == book.sourceId &&
      target.kind == book.kind &&
      targetChapter.id == chapter.id;

  Map<String, Object?> toJson() => {
    'version': 1,
    'target': target.toJson(),
    'targetChapter': targetChapter.toJson(),
    'targetFingerprint': targetFingerprint,
    'targetEpoch': targetEpoch,
    'origin': origin.toJson(),
    'originChapter': originChapter.toJson(),
    'originFingerprint': originFingerprint,
    'originEpoch': originEpoch,
  };

  static BookDownloadEvidence fromJson(Object? raw) {
    if (raw is! Map ||
        raw['version'] != 1 ||
        raw['target'] is! Map ||
        raw['targetChapter'] is! Map ||
        raw['origin'] is! Map ||
        raw['originChapter'] is! Map ||
        !_fingerprint(raw['targetFingerprint']) ||
        !_fingerprint(raw['originFingerprint']) ||
        raw['targetEpoch'] is! int ||
        (raw['targetEpoch'] as int) < 1 ||
        raw['originEpoch'] is! int ||
        (raw['originEpoch'] as int) < 1) {
      throw const FormatException('离线内容来源记录损坏');
    }
    try {
      final target = Book.fromJson(raw['target'] as Map);
      final origin = Book.fromJson(raw['origin'] as Map);
      final targetChapter = BookChapter.fromJson(raw['targetChapter'] as Map);
      final originChapter = BookChapter.fromJson(raw['originChapter'] as Map);
      if (target.sourceId.isEmpty ||
          origin.sourceId.isEmpty ||
          target.kind != origin.kind ||
          target.uri.host.isEmpty ||
          origin.uri.host.isEmpty ||
          targetChapter.uri.host.isEmpty ||
          originChapter.uri.host.isEmpty) {
        throw const FormatException('离线内容来源记录无效');
      }
      return BookDownloadEvidence(
        target: target,
        targetChapter: targetChapter,
        targetFingerprint: raw['targetFingerprint'] as String,
        targetEpoch: raw['targetEpoch'] as int,
        origin: origin,
        originChapter: originChapter,
        originFingerprint: raw['originFingerprint'] as String,
        originEpoch: raw['originEpoch'] as int,
      );
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('离线内容来源记录损坏');
    }
  }

  static bool _fingerprint(Object? value) =>
      value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
}
