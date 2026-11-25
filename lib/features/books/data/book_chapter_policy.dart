import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../supervision/application/content_policy.dart';
import '../../supervision/domain/content_classification.dart';
import '../../supervision/domain/supervision_rules.dart';
import '../domain/book.dart';
import 'book_detected_replacement.dart';
import 'book_store.dart';

final class ChapterContentBlocked extends ContentBlocked {
  const ChapterContentBlocked({
    required this.bookId,
    required this.chapterId,
    required this.digest,
    required this.matches,
    required this.supervised,
  }) : super('章节正文触发${supervised ? '监管关键词' : '成人内容'}过滤。可替换命中内容后继续阅读。');
  final String bookId, chapterId, digest;
  final List<String> matches;
  final bool supervised;
}

final class BookTextReplacement {
  const BookTextReplacement(
    this.keyword,
    this.replacement, {
    this.paragraph = false,
  });
  final String keyword, replacement;
  final bool paragraph;
  Map<String, Object> toJson() => {
    'keyword': keyword,
    'replacement': replacement,
    'paragraph': paragraph,
  };
  factory BookTextReplacement.fromJson(Map raw) {
    final keyword = raw['keyword'], replacement = raw['replacement'];
    if (keyword is! String ||
        keyword.trim().isEmpty ||
        keyword.length > 80 ||
        replacement is! String ||
        replacement.length > 1000 ||
        (raw['paragraph'] != null && raw['paragraph'] is! bool)) {
      throw const FormatException('替换规则无效：关键词 1–80 字符，替换文本最多 1000 字符');
    }
    return BookTextReplacement(
      keyword,
      replacement,
      paragraph: raw['paragraph'] == true,
    );
  }

  String apply(String body) {
    final match = RegExp(RegExp.escape(keyword), caseSensitive: false);
    if (!paragraph) return body.replaceAllMapped(match, (_) => replacement);
    return body
        .split('\n')
        .map((line) => match.hasMatch(line) ? replacement : line)
        .join('\n');
  }
}

/// Rules transform presentation text, never source metadata or original bytes.
/// An adult false-positive approval is tied to one exact chapter body digest.
final class BookChapterPolicy {
  BookChapterPolicy(this.store, this.policy);
  final BookStore store;
  final ContentPolicy policy;
  List<BookTextReplacement> _rules = [];
  Set<String> _exceptions = {};
  BookDetectedReplacement? _detected;
  Future<void>? _loading;
  static const _key = 'books_chapter_policy:v1';
  bool get hasRules => _rules.isNotEmpty || _detected != null;
  bool get hasOverrides => hasRules || _exceptions.isNotEmpty;

  Future<void> load() => _loading ??= _load().catchError((Object error) {
    _loading = null;
    throw error;
  });
  Future<void> _load() async {
    final raw = await store.read(_key);
    if (raw == null) return;
    if (raw is! Map ||
        raw['rules'] is! List ||
        raw['exceptions'] is! List ||
        (raw['rules'] as List).length > 100 ||
        (raw['exceptions'] as List).length > 1000) {
      throw const FormatException('章节复核配置损坏，请在设置中重新保存规则');
    }
    final rules = <BookTextReplacement>[];
    for (final rule in raw['rules'] as List) {
      if (rule is! Map) throw const FormatException('章节复核配置损坏，请重新保存规则');
      rules.add(BookTextReplacement.fromJson(rule));
    }
    if ((raw['exceptions'] as List).any((value) => value is! String)) {
      throw const FormatException('章节复核记录损坏，请重新保存规则');
    }
    final detected = raw['detected'];
    if (detected != null && detected is! Map) {
      throw const FormatException('自动替换配置损坏');
    }
    _detected = detected is Map
        ? BookDetectedReplacement.fromJson(detected)
        : null;
    _rules = rules;
    _exceptions = (raw['exceptions'] as List).cast<String>().toSet();
  }

  void requireReview() {
    if (!policy.supervision.configured) {
      throw const FormatException('请先在监管模式中设置密码');
    }
    policy.supervision.require(SensitiveOperation.supervision);
  }

  List<BookTextReplacement> rulesForReview() {
    requireReview();
    return List.unmodifiable(_rules);
  }

  String prepare(Book book, BookChapter chapter, String original) {
    if (policy.supervision.corrupted) {
      throw const ContentBlocked('监管配置损坏，章节保持锁定');
    }
    var body = original;
    for (final rule in _rules) {
      body = rule.apply(body);
      if (body.length > 8 * 1024 * 1024) {
        throw const FormatException('替换后正文超过大小限制');
      }
    }
    if (_detected case final replacement?) {
      body = replacement.apply(
        body,
        sensitiveContentSpans(
          body,
          keywords: policy.supervision.enabled
              ? policy.supervision.rules.keywords
              : const [],
          filterAdult: policy.filterAdult,
        ),
      );
      if (body.length > 8 * 1024 * 1024) {
        throw const FormatException('替换后正文超过大小限制');
      }
    }
    return _check(book, chapter, original, body);
  }

  /// Validate a reader's transformed result without applying sensitive
  /// replacements a second time. The caller must already validate the original.
  String checkPrepared(Book book, BookChapter chapter, String body) =>
      _check(book, chapter, body, body);

  String _check(Book book, BookChapter chapter, String original, String body) {
    if (policy.supervision.corrupted) {
      throw const ContentBlocked('监管配置损坏，章节保持锁定');
    }
    final normalized = policy.supervision.enabled ? normalizeContent(body) : '';
    final supervised = policy.supervision.enabled
        ? policy.supervision.rules.keywords
              .where((word) => normalized.contains(normalizeContent(word)))
              .toList()
        : <String>[];
    final matches = policy.filterAdult ? adultContentMatches(body) : <String>[];
    if (policy.filterAdult && matches.isEmpty && adultContent(body)) {
      matches.add('内置成人文字规则（规范化命中）');
    }
    // Digests bind exceptional approvals to exact bytes; ordinary text needs
    // no digest. Avoid hashing a long chapter repeatedly at cache/lease checks.
    if (supervised.isEmpty && matches.isEmpty) return body;
    final digest = sha256
        .convert(utf8.encode('$original\u0000$body'))
        .toString();
    if (supervised.isNotEmpty ||
        (matches.isNotEmpty &&
            !_exceptions.contains('${book.id}:${chapter.id}:$digest'))) {
      throw ChapterContentBlocked(
        bookId: book.id,
        chapterId: chapter.id,
        digest: digest,
        matches: List.unmodifiable({...matches, ...supervised}),
        supervised: supervised.isNotEmpty,
      );
    }
    return body;
  }

  Future<void> saveRules(List<BookTextReplacement> rules) async {
    requireReview();
    try {
      await load();
    } on FormatException {
      // Explicit, password-authorized replacement repairs corrupt records.
      // Never skip a broken filtering rule during ordinary reads.
      _exceptions = {};
      _detected = null;
    }
    if (rules.length > 100) throw const FormatException('最多 100 条替换规则');
    final checked = [
      for (final rule in rules) BookTextReplacement.fromJson(rule.toJson()),
    ];
    await _save(checked, _exceptions, _detected);
  }

  BookDetectedReplacement? detectedForReview() {
    policy.supervision.require(SensitiveOperation.supervision);
    return _detected;
  }

  Future<void> saveDetected(BookDetectedReplacement? replacement) async {
    await load();
    void requireAccess() =>
        policy.supervision.require(SensitiveOperation.supervision);
    requireAccess();
    final checked = replacement == null
        ? null
        : BookDetectedReplacement.fromJson(replacement.toJson());
    if (checked != null && !policy.textAllowed(checked.text)) {
      throw const FormatException('替换文字触发当前内容策略');
    }
    await _save(_rules, _exceptions, checked, authorization: requireAccess);
  }

  Future<void> approve(ChapterContentBlocked block) async {
    await load();
    requireReview();
    if (block.supervised) {
      throw const FormatException('监管关键词不能在章节复核中排除，请在监管规则中管理');
    }
    final next = {
      ..._exceptions,
      '${block.bookId}:${block.chapterId}:${block.digest}',
    };
    if (next.length > 1000) throw const FormatException('章节复核记录已达上限');
    await _save(_rules, next, _detected);
  }

  Future<void> _save(
    List<BookTextReplacement> rules,
    Set<String> exceptions,
    BookDetectedReplacement? detected, {
    void Function()? authorization,
  }) async {
    final requireAccess = authorization ?? requireReview;
    await store.db.atomic(() async {
      requireAccess();
      await store.write(_key, {
        'rules': rules.map((rule) => rule.toJson()).toList(),
        'exceptions': exceptions.toList(),
        if (detected != null) 'detected': detected.toJson(),
      });
      requireAccess();
    }, tables: {'app_meta'});
    _rules = List.of(rules);
    _exceptions = Set.of(exceptions);
    _detected = detected;
    _loading = Future<void>.value();
    policy.refresh();
  }
}
