import 'package:flutter/foundation.dart';

import '../domain/book.dart';
import 'book_store.dart';

/// Reader-only literal replacements. The repository validates the original
/// before these rules run; they cannot act as chapter filtering exceptions.
final class ReadingCleanupRule {
  const ReadingCleanupRule({
    required this.text,
    this.replacement = '',
    this.bookId,
    this.enabled = true,
  });
  final String text, replacement;
  final String? bookId;
  final bool enabled;

  factory ReadingCleanupRule.fromJson(Map raw) {
    final text = raw['text'], replacement = raw['replacement'];
    final bookId = raw['bookId'];
    if (text is! String ||
        text.trim().isEmpty ||
        text.length > 2000 ||
        replacement is! String ||
        replacement.length > 2000 ||
        (bookId != null && (bookId is! String || bookId.length > 256))) {
      throw const FormatException('净化规则无效：选文与替换文字最多 2000 字符');
    }
    return ReadingCleanupRule(
      text: text,
      replacement: replacement,
      bookId: bookId as String?,
      enabled: raw['enabled'] != false,
    );
  }

  Map<String, Object?> toJson() => {
    'text': text,
    'replacement': replacement,
    'bookId': bookId,
    'enabled': enabled,
  };
  ReadingCleanupRule withEnabled(bool value) => ReadingCleanupRule(
    text: text,
    replacement: replacement,
    bookId: bookId,
    enabled: value,
  );
}

final class BookReadingCleanup extends ChangeNotifier {
  BookReadingCleanup(this.store);
  final BookStore store;
  static const key = 'books_reading_cleanup:v1';
  List<ReadingCleanupRule> _rules = const [];
  Future<void>? _loading;
  List<ReadingCleanupRule> get rules => List.unmodifiable(_rules);
  Future<void> load() => _loading ??= _load().catchError((Object error) {
    _loading = null;
    throw error;
  });

  Future<void> _load() async {
    final raw = await store.read(key);
    if (raw == null) return;
    if (raw is! List || raw.length > 100) {
      throw const FormatException('阅读净化配置损坏，请重新保存规则');
    }
    _rules = [for (final item in raw) ReadingCleanupRule.fromJson(item as Map)];
  }

  String apply(Book book, String text) {
    var result = text;
    for (final rule in _rules) {
      if (!rule.enabled || (rule.bookId != null && rule.bookId != book.id)) {
        continue;
      }
      if (rule.replacement.length > rule.text.length) {
        var count = 0, cursor = 0;
        while ((cursor = result.indexOf(rule.text, cursor)) >= 0) {
          count++;
          cursor += rule.text.length;
          if (result.length +
                  count * (rule.replacement.length - rule.text.length) >
              8 * 1024 * 1024) {
            throw const FormatException('净化后正文超过大小限制');
          }
        }
      }
      result = result.replaceAll(rule.text, rule.replacement);
      if (result.length > 8 * 1024 * 1024) {
        throw const FormatException('净化后正文超过大小限制');
      }
    }
    return result;
  }

  Future<void> save(List<ReadingCleanupRule> rules) async {
    if (rules.length > 100) throw const FormatException('最多保存 100 条净化规则');
    final checked = [
      for (final rule in rules) ReadingCleanupRule.fromJson(rule.toJson()),
    ];
    await store.write(key, checked.map((r) => r.toJson()).toList());
    _rules = checked;
    _loading = Future.value();
    notifyListeners();
  }
}
