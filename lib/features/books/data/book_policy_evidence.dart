import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/persistence/app_database.dart';
import '../../supervision/application/content_policy.dart';
import '../../supervision/domain/content_classification.dart';
import '../../supervision/domain/supervision_rules.dart';
import '../application/book_category_policy.dart';
import '../domain/book.dart';

/// A review is bound to the saved book and the exact observed revision.
final class BookPolicyReviewEntry {
  const BookPolicyReviewEntry({
    required this.book,
    required this.revision,
    required this.digest,
    required this.sourceRevision,
    required this.policyRevision,
    required this.observationSequence,
  });
  final Book book;
  final int revision, sourceRevision, policyRevision, observationSequence;
  final String digest;
}

/// Bounded policy observations for one source/request identity. Observations
/// merge monotonically; only an authorized manual review clears the adult bit.
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
    this.revision = 0,
  }) : keywordHashes = Set.unmodifiable(keywordHashes),
       normalizedTexts = Set.unmodifiable(normalizedTexts);

  final bool adult, textCoverageIncomplete, uncertain;
  final int revision;
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
    final latestRevision = revision > other.revision
        ? revision
        : other.revision;
    final hashes = {...keywordHashes, ...other.keywordHashes};
    if (uncertain || other.uncertain || hashes.length > maxKeywordHashes) {
      return BookPolicyEvidence(uncertain: true, revision: latestRevision);
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
      revision: latestRevision,
    );
  }

  /// Do not reapply an observation loaded before an explicit review.
  /// Equal or newer snapshots are still merged conservatively with any
  /// in-memory evidence retained after an unsuccessful write. Damage has no
  /// trusted revision and must always remain fail-closed.
  BookPolicyEvidence mergeLoadedSnapshot(BookPolicyEvidence snapshot) =>
      !snapshot.uncertain && snapshot.revision < revision
      ? this
      : merge(snapshot);

  BookPolicyEvidence withRevision(int value, {bool? adult}) =>
      BookPolicyEvidence(
        adult: adult ?? this.adult,
        keywordHashes: keywordHashes,
        normalizedTexts: normalizedTexts,
        latestText: latestText,
        textCoverageIncomplete: textCoverageIncomplete,
        uncertain: uncertain,
        revision: value,
      );

  String get snapshotDigest =>
      sha256.convert(utf8.encode(jsonEncode(toJson()))).toString();

  Map<String, Object> toJson() => uncertain
      ? {'version': 2, 'revision': revision, 'uncertain': true}
      : {
          'version': 2,
          'revision': revision,
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
      if (value is! Map || !const {1, 2}.contains(value['version'])) {
        return BookPolicyEvidence(uncertain: true);
      }
      final version = value['version'];
      final revision = version == 1 ? 0 : value['revision'];
      if (revision is! int || revision < 0) {
        return BookPolicyEvidence(uncertain: true);
      }
      if (value.containsKey('uncertain')) {
        return BookPolicyEvidence(uncertain: true, revision: revision);
      }
      if (value.length != (version == 1 ? 6 : 7) ||
          !value.keys.toSet().containsAll({
            'version',
            if (version == 2) 'revision',
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
        revision: revision,
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
      final combined = existing.merge(evidence).withRevision(existing.revision);
      final changedEvidence =
          rows.isEmpty ||
          evidence.adult ||
          combined.snapshotDigest != existing.snapshotDigest;
      final next = changedEvidence
          ? combined.withRevision(_nextRevision(existing.revision))
          : existing;
      if (changedEvidence) {
        authorize();
        await db.customStatement(
          'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
          [key(id), jsonEncode(next.toJson())],
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

  Future<BookPolicyEvidence> clearAdult({
    required String id,
    required int revision,
    required String digest,
    required void Function() authorize,
    required Future<void> Function() validate,
    Future<void> Function()? afterWrite,
  }) async {
    final cleared = await db.transaction(() async {
      authorize();
      await validate();
      authorize();
      final rows = await db.rows('SELECT value FROM app_meta WHERE key=?', [
        key(id),
      ]);
      if (rows.length != 1) throw const FormatException('作品记录已变化，请重新复核');
      final current = BookPolicyEvidence.decode(rows.single['value']);
      if (current.uncertain ||
          !current.adult ||
          current.revision != revision ||
          current.snapshotDigest != digest) {
        throw const FormatException('作品记录已变化或损坏，请重新复核');
      }
      final next = current.withRevision(
        _nextRevision(current.revision),
        adult: false,
      );
      authorize();
      await db.customStatement('UPDATE app_meta SET value=? WHERE key=?', [
        jsonEncode(next.toJson()),
        key(id),
      ]);
      if (afterWrite != null) await afterWrite();
      authorize();
      await validate();
      authorize();
      return next;
    });
    db.changed(tables: {'app_meta'});
    return cleared;
  }

  static int _nextRevision(int value) {
    if (value >= 0x7ffffffffffffffe) {
      throw const FormatException('作品记录修订号超限，无法继续修改');
    }
    return value + 1;
  }
}
