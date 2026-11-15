import '../../supervision/application/content_policy.dart';
import '../../supervision/domain/content_classification.dart';
import '../domain/book_source_risk.dart';
import '../domain/legado_source.dart';

// Narrow category labels seen in mixed book sources; ordinary H-containing
// words, romance labels, names and the rest of the source remain unaffected.
final _explicitAdultBookCategory = RegExp(
  r'^(?:(?:激情)?h(?:文|小说)|高h(?:文|小说)?|情欲(?:小说)?|强奸)'
  r'(?:(?:日|周|月|总)(?:排行|推荐|收藏)|(?:字数|更新)排行)?$',
);

bool _adultBookCategoryLabel(String text) =>
    text.split(RegExp(r'[,，/|、;；\n\r]+')).any((part) {
      final label = normalizeContent(part)
          .replaceAll('小說', '小说')
          .replaceAll('週', '周')
          .replaceAll('總', '总')
          .replaceAll('推薦', '推荐')
          .replaceAll('數', '数')
          .replaceAll('強姦', '强奸');
      return _explicitAdultBookCategory.hasMatch(label);
    });

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
