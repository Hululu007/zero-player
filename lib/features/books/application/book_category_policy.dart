import '../../supervision/application/content_policy.dart';
import '../domain/book_source_risk.dart';
import '../domain/legado_source.dart';

/// A category can be restricted without classifying its entire source.
bool bookCategoryTextAllowed(
  ContentPolicy policy,
  String title, [
  String group = '',
]) =>
    policy.textAllowed(title, category: group) &&
    policy.textAllowed('', category: title) &&
    !(policy.filterAdult && adultBookLabels(title, group));

bool bookCategoryAllowed(ContentPolicy policy, LegadoCategory category) =>
    bookCategoryTextAllowed(policy, category.title, category.group);
