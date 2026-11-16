import '../../supervision/application/content_policy.dart';
import '../../supervision/domain/content_classification.dart';
import '../domain/book_source_risk.dart';
import '../domain/legado_source.dart';

// Narrow category labels seen in mixed book sources; ordinary H-containing
// words, romance labels, names and the rest of the source remain unaffected.
const _adultHCategory = r'(?:(?:激情)?h(?:文|小说)|高h(?:文|小说)?)';
const _categoryRanking = r'(?:(?:日|周|月|总)(?:排行|推荐|收藏)|(?:字数|更新)排行)?';
final _explicitAdultBookCategory = RegExp(
  '^(?:$_adultHCategory|情欲(?:小说)?|强奸)$_categoryRanking\$',
);
final _spacedAdultHCategory = RegExp(
  r'(?:高\s*h(?:\s*(?:文|小说|小說))?|(?:激情\s*)?h\s*(?:文|小说|小說))',
  caseSensitive: false,
);
const _categoryWarningPrefixes = {
  '反对',
  '反對',
  '禁止',
  '严禁',
  '嚴禁',
  '抵制',
  '拒绝',
  '拒絕',
  '杜绝',
  '杜絕',
  '警惕',
  '远离',
  '遠離',
  '打击',
  '打擊',
};

String _normalizedCategoryLabel(String text) => normalizeContent(text)
    .replaceAll('小說', '小说')
    .replaceAll('週', '周')
    .replaceAll('總', '总')
    .replaceAll('推薦', '推荐')
    .replaceAll('數', '数')
    .replaceAll('強姦', '强奸');

bool _containsAdultCategory(List<String> parts) {
  for (var i = 0; i < parts.length; i++) {
    final label = _normalizedCategoryLabel(parts[i]);
    if (!_explicitAdultBookCategory.hasMatch(label)) continue;
    if (i > 0 &&
        _categoryWarningPrefixes.contains(
          _normalizedCategoryLabel(parts[i - 1]),
        )) {
      continue;
    }
    return true;
  }
  return false;
}

bool _adultBookCategoryLabel(String text) {
  if (text
      .split(RegExp(r'[,，/|、;；\n\r]+'))
      .any(
        (part) =>
            _explicitAdultBookCategory.hasMatch(_normalizedCategoryLabel(part)),
      )) {
    return true;
  }
  // Preserve spaces inside an explicit H label before splitting a composite
  // category; a standalone H and ordinary words containing H remain allowed.
  final folded = String.fromCharCodes(
    text.runes.map((r) => r >= 0xff01 && r <= 0xff5e ? r - 0xfee0 : r),
  ).replaceAll(RegExp(r'[\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFEFF]'), '');
  final joined = folded.replaceAllMapped(
    _spacedAdultHCategory,
    (match) => match[0]!.replaceAll(RegExp(r'\s+'), ''),
  );
  return _containsAdultCategory(joined.split(RegExp(r'[,，/|、;；\s·•・.:：]+')));
}

/// The adult portion of the same category policy, independent of settings.
/// This permits a detail observed while filtering is off to remain identifiable
/// if filtering is enabled later.
bool adultBookCategoryEvidence(String title) =>
    adultContent(title) ||
    adultContent(title, category: true) ||
    adultBookLabels(title, '') ||
    _adultBookCategoryLabel(title);

/// A category can be restricted without classifying its entire source.
bool bookCategoryTextAllowed(
  ContentPolicy policy,
  String title, [
  String group = '',
]) =>
    policy.textAllowed(title, category: group) &&
    policy.textAllowed('', category: title) &&
    !(policy.filterAdult &&
        (adultBookLabels(title, group) ||
            _adultBookCategoryLabel(title) ||
            _adultBookCategoryLabel(group)));

bool bookCategoryAllowed(ContentPolicy policy, LegadoCategory category) =>
    bookCategoryTextAllowed(policy, category.title, category.group);
