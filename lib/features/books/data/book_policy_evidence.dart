import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/persistence/app_database.dart';
import '../../supervision/application/content_policy.dart';
import '../../supervision/domain/content_classification.dart';
import '../../supervision/domain/supervision_rules.dart';
import '../application/book_category_policy.dart';

/// Bounded, monotonic policy observations for one source/request identity.
/// Stored normalized metadata permits later keyword changes to be applied; no
/// request address, query parameters or chapter text is intentionally stored.
final class BookPolicyEvidence {
  BookPolicyEvidence({
    this.adult = false,
    Set<String> keywordHashes = const {},
    Set<String> normalizedTexts = const {},
    this.latestText = '',
    this.textCoverageIncomplete = false,
    this.uncertain = false,
  }) : keywordHashes = Set.unmodifiable(keywordHashes),
       normalizedTexts = Set.unmodifiable(normalizedTexts);

  final bool adult, textCoverageIncomplete, uncertain;
  final Set<String> keywordHashes, normalizedTexts;
  final String latestText;
  SupervisionRules? _cachedRules;
  bool _cachedRulesBlocked = false;
  static const maxKeywordHashes = 4096;
  static const maxTexts = 32, maxTextLength = 8192, maxTotalTextLength = 65536;

  bool get isEmpty =>
      !adult &&
      !uncertain &&
      !textCoverageIncomplete &&
      keywordHashes.isEmpty &&
      latestText.isEmpty &&
      normalizedTexts.isEmpty;

  static String _keywordHash(String word) =>
      sha256.convert(utf8.encode(normalizeContent(word))).toString();

  factory BookPolicyEvidence.observe(
    ContentPolicy policy, {
    required String category,
    required String text,
    required String stableText,
  }) {
    final normalizedText = normalizeContent(text);
    final normalizedStableText = normalizeContent(stableText);
    final normalizedCategory = normalizeContent(category);
    final hashes = <String>{};
    for (final word in policy.supervision.rules.keywords) {
      final normalized = normalizeContent(word);
      if (normalized.isNotEmpty &&
          (normalizedText.contains(normalized) ||
              normalizedCategory.contains(normalized))) {
        hashes.add(_keywordHash(word));
      }
    }
    return BookPolicyEvidence(
      adult: adultContent(text) || adultBookCategoryEvidence(category),
      keywordHashes: hashes,
      normalizedTexts:
          normalizedStableText.isNotEmpty &&
              normalizedStableText.length <= maxTextLength
          ? {normalizedStableText}
          : {},
      latestText: normalizedText.length <= maxTextLength ? normalizedText : '',
      textCoverageIncomplete:
          normalizedText.length > maxTextLength ||
          normalizedStableText.length > maxTextLength,
    );
  }

  bool blocks(ContentPolicy policy) {
    if (uncertain && policy.active) return true;
    if (adult && policy.filterAdult) return true;
    if (!policy.supervision.enabled ||
        policy.supervision.rules.keywords.isEmpty) {
      return false;
    }
    if (textCoverageIncomplete) return true;
    final rules = policy.supervision.rules;
    if (identical(rules, _cachedRules)) return _cachedRulesBlocked;
    _cachedRulesBlocked = rules.keywords.any((word) {
      final normalized = normalizeContent(word);
      return keywordHashes.contains(_keywordHash(word)) ||
          latestText.contains(normalized) ||
          normalizedTexts.any((text) => text.contains(normalized));
    });
    _cachedRules = rules;
    return _cachedRulesBlocked;
  }

  BookPolicyEvidence merge(BookPolicyEvidence other) {
    final hashes = {...keywordHashes, ...other.keywordHashes};
    if (uncertain || other.uncertain || hashes.length > maxKeywordHashes) {
      return BookPolicyEvidence(uncertain: true);
    }
    final texts = {...normalizedTexts, ...other.normalizedTexts};
    final incomplete =
        textCoverageIncomplete ||
        other.textCoverageIncomplete ||
        texts.length > maxTexts ||
        texts.fold<int>(0, (sum, text) => sum + text.length) >
            maxTotalTextLength;
    return BookPolicyEvidence(
      adult: adult || other.adult,
      keywordHashes: hashes,
      normalizedTexts: incomplete ? normalizedTexts : texts,
      latestText: other.latestText.isEmpty ? latestText : other.latestText,
      textCoverageIncomplete: incomplete,
    );
  }

  Map<String, Object> toJson() => uncertain
      ? {'version': 1, 'uncertain': true}
      : {
          'version': 1,
          'adult': adult,
          'keywords': keywordHashes.toList()..sort(),
          'texts': normalizedTexts.toList()..sort(),
          'latest': latestText,
          'incomplete': textCoverageIncomplete,
        };

  static BookPolicyEvidence decode(Object? raw) {
    try {
      if (raw is! String) return BookPolicyEvidence(uncertain: true);
      final value = jsonDecode(raw);
      if (value is! Map || value['version'] != 1) {
        return BookPolicyEvidence(uncertain: true);
      }
      if (value.containsKey('uncertain')) {
        return BookPolicyEvidence(uncertain: true);
      }
      if (value.length != 6 ||
          !value.keys.toSet().containsAll({
            'version',
            'adult',
            'keywords',
            'texts',
            'latest',
            'incomplete',
          })) {
        return BookPolicyEvidence(uncertain: true);
      }
      final adult = value['adult'];
      final words = value['keywords'];
      final texts = value['texts'];
      final latest = value['latest'];
      final incomplete = value['incomplete'];
      if (adult is! bool ||
          words is! List ||
          words.length > maxKeywordHashes ||
          texts is! List ||
          texts.length > maxTexts ||
          incomplete is! bool ||
          latest is! String ||
          latest.length > maxTextLength ||
          normalizeContent(latest) != latest) {
        return BookPolicyEvidence(uncertain: true);
      }
      final hashes = <String>{};
      for (final word in words) {
        if (word is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(word)) {
          return BookPolicyEvidence(uncertain: true);
        }
        hashes.add(word);
      }
      final normalizedTexts = <String>{};
      var total = 0;
      for (final text in texts) {
        if (text is! String ||
            text.isEmpty ||
            text.length > maxTextLength ||
            normalizeContent(text) != text) {
          return BookPolicyEvidence(uncertain: true);
        }
        normalizedTexts.add(text);
        total += text.length;
      }
      if (total > maxTotalTextLength) {
        return BookPolicyEvidence(uncertain: true);
      }
      return BookPolicyEvidence(
        adult: adult,
        keywordHashes: hashes,
        normalizedTexts: normalizedTexts,
        latestText: latest,
        textCoverageIncomplete: incomplete,
      );
    } on FormatException {
      return BookPolicyEvidence(uncertain: true);
    }
  }
}

/// Writes a union in one transaction so simultaneous observations cannot erase
/// earlier evidence. A damaged record stays fail-closed under active policy.
final class BookPolicyEvidenceStore {
  const BookPolicyEvidenceStore(this.db);
  final AppDatabase db;
  static const prefix = 'books_book_policy:';

  static String key(String id) => '$prefix$id';

  Future<Map<String, BookPolicyEvidence>> load() async {
    final rows = await db.rows(
      "SELECT key,value FROM app_meta WHERE key GLOB 'books_book_policy:*'",
    );
    final result = <String, BookPolicyEvidence>{};
    for (final row in rows) {
      final keyValue = row['key'];
      if (keyValue is! String || !keyValue.startsWith(prefix)) continue;
      final id = keyValue.substring(prefix.length);
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(id)) continue;
      result[id] = BookPolicyEvidence.decode(row['value']);
    }
    return result;
  }

  Future<BookPolicyEvidence> merge(
    String id,
    BookPolicyEvidence evidence,
    void Function() authorize, {
    Future<void> Function()? afterCommit,
  }) async {
    if (evidence.isEmpty) return evidence;
    var changed = false;
    final merged = await db.transaction(() async {
      authorize();
      final rows = await db.rows('SELECT value FROM app_meta WHERE key=?', [
        key(id),
      ]);
      final existing = rows.isEmpty
          ? BookPolicyEvidence()
          : BookPolicyEvidence.decode(rows.single['value']);
      final next = existing.merge(evidence);
      final encoded = jsonEncode(next.toJson());
      if (rows.isEmpty || encoded != rows.single['value']) {
        authorize();
        await db.customStatement(
          'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
          [key(id), encoded],
        );
        authorize();
        changed = true;
      }
      authorize();
      return next;
    });
    if (changed) db.changed(tables: {'app_meta'});
    if (afterCommit != null) await afterCommit();
    return merged;
  }
}
