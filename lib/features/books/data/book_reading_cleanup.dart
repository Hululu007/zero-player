import 'dart:async';
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
  BookReadingCleanup(this.store) {
    store.vault.addListener(_vaultChanged);
  }
  final BookStore store;
  static const key = 'books_reading_cleanup:v1';
  static const privateKey = 'books_reading_cleanup:private:v1';
  int _generation = 0;
  List<ReadingCleanupRule> _rules = const [];
  Set<ReadingCleanupRule> _encryptedRules = {};
  Future<void>? _loading;
  List<ReadingCleanupRule> get rules => List.unmodifiable(
    _rules.where(
      (rule) =>
          rule.bookId == null ||
          (!store.vault.isPrivate(rule.bookId!) &&
              !_encryptedRules.contains(rule)) ||
          store.vault.unlocked,
    ),
  );

  void _vaultChanged() {
    _generation++;
    _rules = _rules
        .where(
          (rule) =>
              !_encryptedRules.contains(rule) &&
              (rule.bookId == null || !store.vault.isPrivate(rule.bookId!)),
        )
        .toList();
    _encryptedRules = {};
    _loading = null;
    notifyListeners();
    if (store.vault.unlocked) unawaited(load().catchError((Object _) {}));
  }

  @override
  void dispose() {
    _generation++;
    store.vault.removeListener(_vaultChanged);
    super.dispose();
  }

  Future<void> load() => _loading ??= _load().catchError((Object error) {
    _loading = null;
    throw error;
  });

  Future<void> _load() async {
    final generation = _generation;
    await store.vault.ensureLoaded();
    final raw = await store.read(key);
    final encrypted = store.vault.unlocked
        ? await store.vault.readStrict(privateKey)
        : null;
    if (raw != null && (raw is! List || raw.length > 100) ||
        encrypted != null && (encrypted is! List || encrypted.length > 100)) {
      throw const FormatException('阅读净化配置损坏，请保留数据并从备份恢复');
    }
    final privateRules = [
      for (final item in (encrypted as List? ?? const []))
        ReadingCleanupRule.fromJson(item as Map),
    ];
    final loaded = [
      for (final item in (raw as List? ?? const []))
        ReadingCleanupRule.fromJson(item as Map),
      ...privateRules,
    ];
    if (generation != _generation) return;
    _rules = loaded;
    _encryptedRules = privateRules.toSet();
  }

  String apply(Book book, String text) {
    var result = text;
    for (final rule in rules) {
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
    await store.vault.ensureLoaded();
    bool private(ReadingCleanupRule rule) =>
        rule.bookId != null && store.vault.isPrivate(rule.bookId!);
    await store.db.atomic(() async {
      await store.write(
        key,
        checked.where((rule) => !private(rule)).map((r) => r.toJson()).toList(),
      );
      if (store.vault.unlocked) {
        await store.vault.write(
          privateKey,
          checked.where(private).map((r) => r.toJson()).toList(),
        );
      }
    }, tables: {'app_meta'});
    _rules = checked;
    _encryptedRules = checked.where(private).toSet();
    _loading = Future.value();
    notifyListeners();
  }
}
